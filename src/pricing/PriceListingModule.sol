// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ValueInterpreter} from '../core/ValueInterpreter.sol';
import {TwapListingRegistryV2} from './TwapListingRegistryV2.sol';

/// @title PriceListingModule
/// @notice Owns the ValueInterpreter so TWAP listings go live without a governance round.
///         - `list` / `repoint` / `pokeFloor` are keeper-only: a keeper lists a pool only after its
///           quote-side depth held over repeated samples, because a same-transaction snapshot can
///           be inflated with flash liquidity. The registry's checks still run on every call
///           (canonical pool, allowed quote, prices now, ≥ $50k quote-side depth), and `list` /
///           `repoint` write the TWAP primitive in the same transaction.
///         - They can never touch an asset the VI already prices another way: Chainlink,
///           derivative, zero-priced, or another registry's adapter.
///         - Every other VI admin call goes through `execute`, which only this module's owner
///           (governance) can make.
contract PriceListingModule is Ownable2Step, ReentrancyGuard {
	/// @notice VI staleness bound for TWAP primitives; the adapter stamps each read with its own timestamp.
	uint32 public constant TWAP_HEARTBEAT = 3600;

	ValueInterpreter public immutable valueInterpreter;
	TwapListingRegistryV2 public immutable registry;

	/// @notice Addresses allowed to list, repoint and poke (the auto-lister), set by the owner.
	mapping(address => bool) public keepers;

	event TwapListed(address indexed asset, address indexed adapter, address indexed caller);
	event TwapRepointed(address indexed asset, address indexed adapter, address indexed caller);
	event Executed(bytes data);
	event KeeperSet(address indexed keeper, bool allowed);

	error ZeroAddress();
	error ValueInterpreterMismatch();
	error NotKeeper();
	error AlreadyPriced(address asset);
	error NotTwapPriced(address asset);

	modifier onlyKeeper() {
		if (!keepers[msg.sender]) revert NotKeeper();
		_;
	}

	constructor(ValueInterpreter valueInterpreter_, TwapListingRegistryV2 registry_) Ownable(msg.sender) {
		if (address(valueInterpreter_) == address(0) || address(registry_) == address(0)) revert ZeroAddress();
		// primitives written here must land in the VI the registry's isTwapPriced reads
		if (address(registry_.valueInterpreter()) != address(valueInterpreter_)) revert ValueInterpreterMismatch();
		valueInterpreter = valueInterpreter_;
		registry = registry_;
	}

	/// @notice Allow or revoke a keeper (owner only).
	function setKeeper(address keeper, bool allowed) external onlyOwner {
		if (keeper == address(0)) revert ZeroAddress();
		keepers[keeper] = allowed;
		emit KeeperSet(keeper, allowed);
	}

	/// @notice List `asset` on the TWAP tier and price it in the VI (keeper only).
	function list(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		external
		onlyKeeper
		nonReentrant
		returns (address adapter)
	{
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		adapter = address(registry.list(asset, quote, venue, feeOrTickSpacing));
		valueInterpreter.addPrimitive(asset, adapter, TWAP_HEARTBEAT);
		emit TwapListed(asset, adapter, msg.sender);
	}

	/// @notice Move a TWAP listing to a deeper pool and repoint the VI (keeper only; the registry
	///         enforces the depth margin).
	function repoint(address asset, address quote, TwapListingRegistryV2.Venue venue, int24 feeOrTickSpacing)
		external
		onlyKeeper
		nonReentrant
		returns (address adapter)
	{
		if (!registry.isTwapPriced(asset)) revert NotTwapPriced(asset);
		adapter = address(registry.repoint(asset, quote, venue, feeOrTickSpacing));
		valueInterpreter.addPrimitive(asset, adapter, TWAP_HEARTBEAT);
		emit TwapRepointed(asset, adapter, msg.sender);
	}

	/// @notice Poke `asset`'s delist clock as the registry's lister (keeper only): the path that can
	///         clear the clock and record depth. The registry emits the events.
	/// @return below whether the pool is under the floor now
	function pokeFloor(address asset) external onlyKeeper nonReentrant returns (bool below) {
		below = registry.pokeFloor(asset);
	}

	/// @notice Governance passthrough: any VI admin call (addPrimitive for Chainlink assets,
	///         derivatives, bounds, sequencer feed, ownership…). Reverts bubble up unchanged.
	function execute(bytes calldata data) external onlyOwner returns (bytes memory result) {
		bool ok;
		(ok, result) = address(valueInterpreter).call(data);
		if (!ok) {
			assembly ('memory-safe') {
				revert(add(result, 32), mload(result))
			}
		}
		emit Executed(data);
	}
}

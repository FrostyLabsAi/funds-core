// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {ValueInterpreter} from '../core/ValueInterpreter.sol';
import {TwapListingRegistryV2} from './TwapListingRegistryV2.sol';
import {CompounderFactory} from '../yield/CompounderFactory.sol';
import {FeeCompounderBase} from '../yield/FeeCompounderBase.sol';
import {CompounderPriceFeed} from './CompounderPriceFeed.sol';

/// @title PriceListingModule
/// @notice Owns the ValueInterpreter so TWAP listings and fee-compounder listings go live without a
///         governance round.
///         - `list` / `repoint` / `pokeFloor` are keeper-only: a keeper lists a pool only after its
///           quote-side depth held over repeated samples, because a same-transaction snapshot can
///           be inflated with flash liquidity. The registry's checks still run on every call
///           (canonical pool, allowed quote, prices now, ≥ $50k quote-side depth), and `list` /
///           `repoint` write the TWAP primitive in the same transaction.
///         - `listCompounder` is keeper-only: it registers a CompounderFactory vault as a VI
///           derivative priced by the CompounderPriceFeed, once the owner has wired both
///           (`setCompounderListing`, settable once). Only the wired factory's vaults qualify, and
///           only when both pool tokens are VI primitives and neither is TWAP-priced by the
///           registry: the exposure policy caps TWAP assets but doesn't look through derivatives,
///           so a compounder over a TWAP token would bypass the cap.
///         - `setCompounderBlocked` is owner-only (ruling C6): a governance delist is
///           `execute(removeDerivative(vault))` plus the block, and `listCompounder` refuses a blocked
///           vault, so the keeper can't put it back. Unblocking lets the keeper list it again.
///         - None of them can touch an asset the VI already prices another way: Chainlink,
///           derivative, zero-priced, or another registry's adapter.
///         - Every other VI admin call goes through `execute`, which only this module's owner
///           (governance) can make.
contract PriceListingModule is Ownable2Step, ReentrancyGuard {
	/// @notice VI staleness bound for TWAP primitives; the adapter stamps each read with its own timestamp.
	uint32 public constant TWAP_HEARTBEAT = 3600;

	ValueInterpreter public immutable valueInterpreter;
	TwapListingRegistryV2 public immutable registry;

	/// @notice Addresses allowed to list, repoint, poke and list compounders (the auto-lister), set by the owner.
	mapping(address => bool) public keepers;
	/// @notice The factory whose vaults `listCompounder` may list; zero until wired (once).
	CompounderFactory public compounderFactory;
	/// @notice The derivative feed (CompounderPriceFeed on this VI) every compounder is listed with.
	address public compounderFeed;
	/// @notice Vaults governance keeps out of the VI: `listCompounder` refuses them (owner-set).
	mapping(address => bool) public compounderBlocked;

	event TwapListed(address indexed asset, address indexed adapter, address indexed caller);
	event TwapRepointed(address indexed asset, address indexed adapter, address indexed caller);
	event Executed(bytes data);
	event KeeperSet(address indexed keeper, bool allowed);
	event CompounderListingSet(address indexed factory, address indexed feed);
	event CompounderListed(address indexed vault, address indexed feed, address indexed caller);
	event CompounderBlockedSet(address indexed vault, bool blocked);

	error ZeroAddress();
	error ValueInterpreterMismatch();
	error NotKeeper();
	error AlreadyPriced(address asset);
	error NotTwapPriced(address asset);
	error CompounderListingAlreadySet();
	error CompounderListingNotSet();
	error NotFactoryCompounder(address vault);
	error UnpricedUnderlying(address token);
	error TwapUnderlying(address token);
	error CompounderBlocked(address vault);

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

	/// @notice Wire the compounder factory and its derivative feed (owner only, once). The feed must
	///         read this module's VI, which is where it prices the underlyings.
	function setCompounderListing(CompounderFactory factory, address feed) external onlyOwner {
		if (address(factory) == address(0) || feed == address(0)) revert ZeroAddress();
		if (address(compounderFactory) != address(0)) revert CompounderListingAlreadySet();
		if (address(CompounderPriceFeed(feed).valueInterpreter()) != address(valueInterpreter)) {
			revert ValueInterpreterMismatch();
		}
		compounderFactory = factory;
		compounderFeed = feed;
		emit CompounderListingSet(address(factory), feed);
	}

	/// @notice Price a CompounderFactory vault in the VI as a derivative (keeper only). Refused unless
	///         the wired factory made it, governance hasn't blocked it, the VI doesn't price it yet,
	///         both its tokens are VI primitives (the VI resolves a derivative only into primitives: an
	///         unpriced, zero-priced or derivative token would leave the share unpriceable), and
	///         neither token is TWAP-priced by the registry (the cap-bypass guard).
	function listCompounder(address vault) external onlyKeeper nonReentrant {
		CompounderFactory factory = compounderFactory;
		if (address(factory) == address(0)) revert CompounderListingNotSet();
		if (!factory.isCompounder(vault)) revert NotFactoryCompounder(vault);
		if (compounderBlocked[vault]) revert CompounderBlocked(vault);
		if (valueInterpreter.isSupportedAsset(vault)) revert AlreadyPriced(vault);
		address token0 = address(FeeCompounderBase(vault).token0());
		address token1 = address(FeeCompounderBase(vault).token1());
		_requirePrimitive(token0);
		_requirePrimitive(token1);
		if (registry.isTwapPriced(token0)) revert TwapUnderlying(token0);
		if (registry.isTwapPriced(token1)) revert TwapUnderlying(token1);
		valueInterpreter.addDerivative(vault, compounderFeed);
		emit CompounderListed(vault, compounderFeed, msg.sender);
	}

	/// @notice Block or unblock a vault from `listCompounder` (owner only). Blocking doesn't delist:
	///         governance removes the derivative through `execute` (ideally in the same batch).
	function setCompounderBlocked(address vault, bool blocked) external onlyOwner {
		if (vault == address(0)) revert ZeroAddress();
		compounderBlocked[vault] = blocked;
		emit CompounderBlockedSet(vault, blocked);
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

	/// @dev Revert unless the VI prices `token` through a feed of its own (a primitive).
	function _requirePrimitive(address token) internal view {
		(address aggregator,,,) = valueInterpreter.getAssetInfo(token);
		if (aggregator == address(0)) revert UnpricedUnderlying(token);
	}
}

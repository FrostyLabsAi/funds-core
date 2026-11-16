// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {IFundAccount} from '../interfaces/IFundAccount.sol';
import {IComptroller} from '../interfaces/IComptroller.sol';

/// @title ProtectRegistry
/// @notice Opt-in registry for Protect Mode on Veranta, one setting per account AND pair: one setting per account
///         would let arming SPCX silently stop the trailing stop on BTC (founder 2026-11-03: one market must not
///         affect another). The keeper acts only through the Veranta
///         delegation the user grants (and can revoke) separately.
///         HEDGE: when a spot asset retraces `trailingBps` from its high, the keeper opens a short
///         on the user's own Veranta account sized to the holding, released on recovery.
///         STOP: trailing stop on the user's Veranta trades on the pair.
///         NEUTRAL: the delta-neutral autopilot's opt-in for the pair.
/// @dev Holds no funds and no permissions, and has no owner. One entry per pair keeps products from
///      overlapping: the autopilot and Protect can never manage the same pair on one account.
contract ProtectRegistry {
	using EnumerableSet for EnumerableSet.UintSet;

	enum Mode {
		HEDGE,
		STOP,
		NEUTRAL
	}

	/// @dev Fits one storage slot, so changing a setting costs one write.
	struct Config {
		Mode mode;
		address spotAsset; // HEDGE/NEUTRAL: the ERC20 whose balance sizes the hedge (0 for STOP)
		uint16 trailingBps; // retrace from the trailing extreme that triggers action
		uint16 leverageX; // HEDGE/NEUTRAL: short leverage (whole multiples, e.g. 2)
		uint40 updatedAt;
		bool enabled;
	}

	mapping(address trader => mapping(uint256 pairIndex => Config)) public configs;
	mapping(address trader => EnumerableSet.UintSet) private _pairs;

	event ProtectConfigured(
		address indexed user,
		uint256 indexed pairIndex,
		Mode mode,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX,
		bool enabled
	);

	error BadTrailing();
	error BadLeverage();
	error SpotAssetRequired();
	error NotFundOwner();
	error NotConfigured();

	/// @notice Publish or update your protection on one pair; the keeper acts only while your Veranta
	///         delegation is also live.
	function configure(Mode mode, uint256 pairIndex, address spotAsset, uint16 trailingBps, uint16 leverageX)
		external
	{
		_configure(msg.sender, mode, pairIndex, spotAsset, trailingBps, leverageX);
	}

	/// @notice Fund flavor: the fund's manager publishes protection for the fund's Veranta position
	///         (the position's comptroller must name msg.sender as fundOwner).
	function configureFor(
		address trader,
		Mode mode,
		uint256 pairIndex,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX
	) external {
		_requireFundOwner(trader);
		_configure(trader, mode, pairIndex, spotAsset, trailingBps, leverageX);
	}

	/// @notice Turn protection off on one pair (config kept). Revoking the Veranta delegation stops
	///         the keeper on every pair regardless.
	function disable(uint256 pairIndex) external {
		_disable(msg.sender, pairIndex);
	}

	/// @notice Fund flavor of {disable}, manager-gated like {configureFor}.
	function disableFor(address trader, uint256 pairIndex) external {
		_requireFundOwner(trader);
		_disable(trader, pairIndex);
	}

	/// @notice Every pair this account ever configured, enabled or not (read `configs` for each).
	function pairsOf(address trader) external view returns (uint256[] memory) {
		return _pairs[trader].values();
	}

	function _configure(
		address trader,
		Mode mode,
		uint256 pairIndex,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX
	) internal {
		if (trailingBps == 0 || trailingBps >= 10_000) revert BadTrailing();
		if (mode == Mode.HEDGE || mode == Mode.NEUTRAL) {
			if (spotAsset == address(0)) revert SpotAssetRequired();
			if (leverageX < 1 || leverageX > 10) revert BadLeverage();
		}
		_pairs[trader].add(pairIndex);
		configs[trader][pairIndex] = Config({
			mode: mode,
			spotAsset: spotAsset,
			trailingBps: trailingBps,
			leverageX: leverageX,
			updatedAt: uint40(block.timestamp),
			enabled: true
		});
		emit ProtectConfigured(trader, pairIndex, mode, spotAsset, trailingBps, leverageX, true);
	}

	function _disable(address trader, uint256 pairIndex) internal {
		// a pair never configured would otherwise put an empty entry on the keeper's list
		if (!_pairs[trader].contains(pairIndex)) revert NotConfigured();
		Config storage config = configs[trader][pairIndex];
		config.enabled = false;
		config.updatedAt = uint40(block.timestamp);
		emit ProtectConfigured(
			trader, pairIndex, config.mode, config.spotAsset, config.trailingBps, config.leverageX, false
		);
	}

	function _requireFundOwner(address trader) internal view {
		(bool ok, bytes memory ret) = trader.staticcall(abi.encodeCall(IFundAccount.comptroller, ()));
		if (!ok || ret.length != 32) revert NotFundOwner();
		address comptroller = abi.decode(ret, (address));
		if (IComptroller(comptroller).fundOwner() != msg.sender) revert NotFundOwner();
	}
}

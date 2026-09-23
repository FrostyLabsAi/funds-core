// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title ProtectRegistry
/// @notice Self-service opt-in registry for Protect Mode — the retail auto-hedge /
///         trailing-stop product on Veranta rails. Users publish their own protection
///         config here; the protect keeper discovers users from events and acts ONLY
///         through Veranta's delegation (which the user grants separately on the router
///         and can revoke at any time — this registry holds no funds and no permissions).
///
///         Modes:
///           HEDGE — user holds a spot asset; when its price retraces `trailingBps` from
///                   the high-water observed since enabling, the keeper opens a short on
///                   the user's OWN Veranta account (their USDC collateral, self-custodied)
///                   sized to the spot holding — value locked without selling the spot.
///                   The short is released when price recovers to the arm level.
///           STOP  — trailing stop for the user's open Veranta position on `pairIndex`:
///                   the keeper market-closes it via delegatedAction when price retraces
///                   `trailingBps` from the best price since enabling. (Veranta TP/SL is
///                   intent-only — contract-side trailing stops don't otherwise exist.)
interface IProtectableTrader {
	function comptroller() external view returns (address);
}

interface IProtectComptroller {
	function fundOwner() external view returns (address);
}

contract ProtectRegistry {
	/// @dev NEUTRAL is reserved for the continuous delta-neutral retail mode (keeper
	///      support pending founder go) — reserving the slot now keeps this registry's
	///      single deployment forward-compatible.
	enum Mode {
		HEDGE,
		STOP,
		NEUTRAL
	}

	struct Config {
		Mode mode;
		uint256 pairIndex; // Veranta pair being protected
		address spotAsset; // HEDGE: the ERC20 whose balance sizes the hedge (0 for STOP)
		uint16 trailingBps; // retrace from the trailing extreme that triggers action
		uint16 leverageX; // HEDGE: short leverage (whole multiples, e.g. 2)
		uint64 updatedAt;
		bool enabled;
	}

	mapping(address => Config) public configs;

	event ProtectConfigured(
		address indexed user,
		Mode mode,
		uint256 pairIndex,
		address spotAsset,
		uint16 trailingBps,
		uint16 leverageX,
		bool enabled
	);

	error BadTrailing();
	error BadLeverage();
	error SpotAssetRequired();
	error NotFundOwner();

	/// @notice Publish or update your protection. Enabling is only half the switch —
	///         the keeper can act only while your Veranta delegation is live too.
	function configure(Mode mode, uint256 pairIndex, address spotAsset, uint16 trailingBps, uint16 leverageX)
		external
	{
		_configure(msg.sender, mode, pairIndex, spotAsset, trailingBps, leverageX);
	}

	/// @notice FUND flavor: the fund MANAGER publishes protection for the fund's own
	///         Veranta position (the on-venue trader). Auth = the position's comptroller
	///         names msg.sender as fundOwner. The keeper acts through the delegation the
	///         fund granted via SetAutopilot — same trustless gate as everything else.
	///         NOTE (managers): don't run HEDGE/NEUTRAL protection and the delta-neutral
	///         autopilot on the SAME pair — two brains, one short; pick one per pair.
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

	/// @notice Turn protection off (config retained for easy re-enable). Removing the
	///         Veranta delegation on the router kills the keeper's power regardless.
	function disable() external {
		_disable(msg.sender);
	}

	/// @notice Fund flavor of {disable} — manager-gated like {configureFor}.
	function disableFor(address trader) external {
		_requireFundOwner(trader);
		_disable(trader);
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
		configs[trader] = Config({
			mode: mode,
			pairIndex: pairIndex,
			spotAsset: spotAsset,
			trailingBps: trailingBps,
			leverageX: leverageX,
			updatedAt: uint64(block.timestamp),
			enabled: true
		});
		emit ProtectConfigured(trader, mode, pairIndex, spotAsset, trailingBps, leverageX, true);
	}

	function _disable(address trader) internal {
		Config storage config = configs[trader];
		config.enabled = false;
		config.updatedAt = uint64(block.timestamp);
		emit ProtectConfigured(
			trader, config.mode, config.pairIndex, config.spotAsset, config.trailingBps, config.leverageX, false
		);
	}

	function _requireFundOwner(address trader) internal view {
		(bool ok, bytes memory ret) = trader.staticcall(abi.encodeCall(IProtectableTrader.comptroller, ()));
		if (!ok || ret.length != 32) revert NotFundOwner();
		address comptroller = abi.decode(ret, (address));
		if (IProtectComptroller(comptroller).fundOwner() != msg.sender) revert NotFundOwner();
	}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

interface IProtectableTrader {
	function comptroller() external view returns (address);
}

interface IProtectComptroller {
	function fundOwner() external view returns (address);
}

/// @title ProtectRegistry
/// @notice Opt-in registry for Protect Mode on Veranta. Users publish a config; the keeper acts only
///         through the Veranta delegation the user grants (and can revoke) separately.
///         HEDGE: when a spot asset retraces `trailingBps` from its high, the keeper opens a short
///         on the user's own Veranta account sized to the holding, released on recovery.
///         STOP: trailing stop that market-closes the user's Veranta position on `pairIndex`.
/// @dev Holds no funds and no permissions.
contract ProtectRegistry {
	/// @dev NEUTRAL is reserved for a delta-neutral retail mode (keeper support pending).
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

	/// @notice Publish or update your protection; the keeper acts only while your Veranta
	///         delegation is also live.
	function configure(Mode mode, uint256 pairIndex, address spotAsset, uint16 trailingBps, uint16 leverageX)
		external
	{
		_configure(msg.sender, mode, pairIndex, spotAsset, trailingBps, leverageX);
	}

	/// @notice Fund flavor: the fund's manager publishes protection for the fund's Veranta position
	///         (the position's comptroller must name msg.sender as fundOwner).
	/// @dev Don't run HEDGE/NEUTRAL protection and the delta-neutral autopilot on the same pair.
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

	/// @notice Turn protection off (config kept). Revoking the Veranta delegation stops the keeper
	///         regardless.
	function disable() external {
		_disable(msg.sender);
	}

	/// @notice Fund flavor of {disable}, manager-gated like {configureFor}.
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

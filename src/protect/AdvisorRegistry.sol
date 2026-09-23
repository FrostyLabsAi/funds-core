// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title AdvisorRegistry
/// @notice Per-trader advisory preferences for Protect Mode — the trailing-stop
///         advisor telemetry the keeper sends alongside protection. The advisor
///         endpoint and payment wallet stay keeper-side (ops config); traders control
///         whether advice runs for them, how often, and the per-call fee they accept:
///           unset (updatedAt == 0) → keeper default policy applies;
///           enabled == false       → no advisory for this trader;
///           maxFeeMicroUsdc        → cap for PAID x402 advice (USDC 6dp);
///                                    0 = free transports only, never pay.
///         Holds no funds and no permissions — same trust model as ProtectRegistry:
///         the keeper reads it, and the worst a wrong config can do is send or stop
///         sending advice.
interface IAdvisableTrader {
	function comptroller() external view returns (address);
}

interface IAdvisorComptroller {
	function fundOwner() external view returns (address);
}

contract AdvisorRegistry {
	struct Config {
		bool enabled;
		uint32 intervalSeconds; // min seconds between advisories; 0 = keeper default
		uint32 maxFeeMicroUsdc; // per-call cap for paid advice; 0 = free transports only
		uint64 updatedAt; // 0 = never configured — keeper default policy applies
	}

	mapping(address => Config) public configs;

	event AdvisorConfigured(address indexed trader, bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc);

	error BadInterval();
	error NotFundOwner();

	/// @dev Advice can cost money per call — no per-second spam cadences.
	uint32 internal constant MIN_INTERVAL = 300;

	/// @notice Publish or update your advisory preferences (self-serve).
	function configure(bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc) external {
		_configure(msg.sender, enabled, intervalSeconds, maxFeeMicroUsdc);
	}

	/// @notice FUND flavor: the fund MANAGER sets advisory preferences for the fund's
	///         own Veranta position (the registered trader). Auth = the position's
	///         comptroller names msg.sender as fundOwner — same gate as ProtectRegistry.
	function configureFor(address trader, bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc) external {
		_requireFundOwner(trader);
		_configure(trader, enabled, intervalSeconds, maxFeeMicroUsdc);
	}

	/// @notice Turn advisory off (cadence and fee cap retained for easy re-enable).
	function disable() external {
		_disable(msg.sender);
	}

	/// @notice Fund flavor of {disable} — manager-gated like {configureFor}.
	function disableFor(address trader) external {
		_requireFundOwner(trader);
		_disable(trader);
	}

	function _configure(address trader, bool enabled, uint32 intervalSeconds, uint32 maxFeeMicroUsdc) internal {
		if (intervalSeconds != 0 && intervalSeconds < MIN_INTERVAL) revert BadInterval();
		configs[trader] = Config({
			enabled: enabled,
			intervalSeconds: intervalSeconds,
			maxFeeMicroUsdc: maxFeeMicroUsdc,
			updatedAt: uint64(block.timestamp)
		});
		emit AdvisorConfigured(trader, enabled, intervalSeconds, maxFeeMicroUsdc);
	}

	function _disable(address trader) internal {
		Config storage config = configs[trader];
		config.enabled = false;
		config.updatedAt = uint64(block.timestamp);
		emit AdvisorConfigured(trader, false, config.intervalSeconds, config.maxFeeMicroUsdc);
	}

	function _requireFundOwner(address trader) internal view {
		(bool ok, bytes memory ret) = trader.staticcall(abi.encodeCall(IAdvisableTrader.comptroller, ()));
		if (!ok || ret.length != 32) revert NotFundOwner();
		address comptroller = abi.decode(ret, (address));
		if (IAdvisorComptroller(comptroller).fundOwner() != msg.sender) revert NotFundOwner();
	}
}

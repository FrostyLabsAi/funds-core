// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';

/// @title CumulativeSlippageTolerancePolicy
/// @notice Rate-limits value loss through adapter trades: each trade's slippage (spend value
///         minus received value, as a fraction of fund GAV) accrues to a cumulative total
///         that must stay under `toleranceBps`; the total replenishes linearly over 7 days.
/// @dev Port of Enzyme v4's CumulativeSlippageTolerancePolicy (spec/topics/policies.md):
///      "slow the rate at which a malicious manager can drain a fund enough to allow
///      alerting and exiting" — the core defense for anonymous marketplace managers.
///      One instance is shareable by many funds (state is keyed by calling Comptroller).
contract CumulativeSlippageTolerancePolicy is IPolicy {
	uint256 public constant BPS = 10_000;
	uint256 public constant TOLERANCE_PERIOD = 7 days;

	uint256 public immutable toleranceBps;

	struct SlippageState {
		uint128 cumulativeLossBps;
		uint64 lastUpdated;
	}

	mapping(address comptroller => SlippageState) public slippageStates;

	event SlippageAccrued(address indexed comptroller, uint256 lossBps, uint256 cumulativeLossBps);

	error InvalidTolerance();
	error CumulativeSlippageExceeded(uint256 cumulativeLossBps, uint256 toleranceBps);

	constructor(uint256 toleranceBps_) {
		if (toleranceBps_ == 0 || toleranceBps_ > BPS) revert InvalidTolerance();
		toleranceBps = toleranceBps_;
	}

	/// @inheritdoc IPolicy
	/// @dev Two loss sources feed ONE budget: adapter trades (value computed here from
	///      the hook's stated spend/incoming, which the Comptroller measures as vault
	///      deltas) and external-position calls (the Comptroller passes the MEASURED
	///      value lost inside the call — security review 2026-09-22, H-1).
	function validate(PolicyHook hook, bytes calldata validationData) external {
		uint256 loss;
		if (hook == PolicyHook.PostCallOnExternalPosition) {
			(, uint256 lossValue) = abi.decode(validationData, (address, uint256));
			loss = lossValue;
		} else {
			(, address[] memory spendAssets, uint256[] memory spendAmounts, address[] memory incomingAssets, uint256[] memory incomingAmounts)
			= abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));

			Comptroller trader = Comptroller(msg.sender);
			IValueInterpreter interpreter = trader.valueInterpreter();
			address denominationAsset = address(trader.denominationAsset());

			uint256 spendValue;
			for (uint256 i; i < spendAssets.length; ++i) {
				spendValue += interpreter.calcCanonicalAssetValue(spendAssets[i], spendAmounts[i], denominationAsset);
			}
			uint256 incomingValue;
			for (uint256 i; i < incomingAssets.length; ++i) {
				incomingValue += interpreter.calcCanonicalAssetValue(incomingAssets[i], incomingAmounts[i], denominationAsset);
			}
			if (spendValue > incomingValue) loss = spendValue - incomingValue;
		}

		SlippageState memory state = slippageStates[msg.sender];

		// Linear replenishment since the last accrual
		if (state.cumulativeLossBps > 0 && state.lastUpdated > 0) {
			uint256 replenished = (toleranceBps * (block.timestamp - state.lastUpdated)) / TOLERANCE_PERIOD;
			state.cumulativeLossBps =
				replenished >= state.cumulativeLossBps ? 0 : uint128(state.cumulativeLossBps - replenished);
		}

		if (loss > 0) {
			// Loss relative to pre-action fund value (post-action GAV + the loss itself)
			uint256 gav = Comptroller(msg.sender).calcGav();
			uint256 lossBps = Math.mulDiv(loss, BPS, gav + loss);

			state.cumulativeLossBps += uint128(lossBps);
			if (state.cumulativeLossBps > toleranceBps) {
				revert CumulativeSlippageExceeded(state.cumulativeLossBps, toleranceBps);
			}
			emit SlippageAccrued(msg.sender, lossBps, state.cumulativeLossBps);
		}

		state.lastUpdated = uint64(block.timestamp);
		slippageStates[msg.sender] = state;
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](2);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.PostCallOnExternalPosition;
	}
}

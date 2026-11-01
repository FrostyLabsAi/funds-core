// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IPolicy} from '../interfaces/IPolicy.sol';
import {Comptroller} from '../core/Comptroller.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';

/// @title CumulativeSlippageTolerancePolicy
/// @notice Rate-limits value loss: each trade's loss (as a fraction of GAV) accrues to a total
///         that must stay under `toleranceBps`, replenishing linearly over 7 days.
/// @dev Slows a malicious manager enough for investors to exit. Shared across funds (state keyed by Comptroller).
contract CumulativeSlippageTolerancePolicy is IPolicy {
	uint256 public constant BPS = 10_000;
	uint256 public constant TOLERANCE_PERIOD = 7 days;

	/// @dev Losses accrue in bps × PRECISION: whole bps let every loss under 1 bp round to 0, so a loop of small
	///      losing trades drained a fund past the tolerance (red-team ADAPTERS-01, 2026-10-27).
	uint256 public constant PRECISION = 1e18;

	uint256 public immutable toleranceBps;

	struct SlippageState {
		uint128 cumulativeLoss; // bps × PRECISION
		uint64 lastUpdated;
	}

	mapping(address comptroller => SlippageState) internal _states;

	event SlippageAccrued(address indexed comptroller, uint256 lossBps, uint256 cumulativeLossBps);

	error InvalidTolerance();
	error CumulativeSlippageExceeded(uint256 cumulativeLossBps, uint256 toleranceBps);

	constructor(uint256 toleranceBps_) {
		if (toleranceBps_ == 0 || toleranceBps_ > BPS) revert InvalidTolerance();
		toleranceBps = toleranceBps_;
	}

	/// @inheritdoc IPolicy
	/// @dev One budget for adapter trades (valued from measured vault deltas) and external-position
	///      calls (the Comptroller passes the measured loss).
	function validate(PolicyHook hook, bytes calldata validationData) external {
		uint256 loss;
		uint256 spendValue;
		if (hook == PolicyHook.PostCallOnExternalPosition) {
			(, uint256 lossValue) = abi.decode(validationData, (address, uint256));
			loss = lossValue;
		} else {
			(, address[] memory spendAssets, uint256[] memory spendAmounts, address[] memory incomingAssets, uint256[] memory incomingAmounts)
			= abi.decode(validationData, (address, address[], uint256[], address[], uint256[]));

			Comptroller trader = Comptroller(msg.sender);
			IValueInterpreter interpreter = trader.valueInterpreter();
			address denominationAsset = address(trader.denominationAsset());

			for (uint256 i; i < spendAssets.length; ++i) {
				spendValue += interpreter.calcCanonicalAssetValue(spendAssets[i], spendAmounts[i], denominationAsset);
			}
			uint256 incomingValue;
			for (uint256 i; i < incomingAssets.length; ++i) {
				incomingValue += interpreter.calcCanonicalAssetValue(incomingAssets[i], incomingAmounts[i], denominationAsset);
			}
			if (spendValue > incomingValue) loss = spendValue - incomingValue;
		}

		SlippageState memory state = _states[msg.sender];

		// Linear replenishment since the last accrual
		if (state.cumulativeLoss > 0 && state.lastUpdated > 0) {
			uint256 replenished = (toleranceBps * PRECISION * (block.timestamp - state.lastUpdated)) / TOLERANCE_PERIOD;
			state.cumulativeLoss = replenished >= state.cumulativeLoss ? 0 : uint128(state.cumulativeLoss - replenished);
		}

		if (loss > 0) {
			// Rounded up so any loss accrues something (ADAPTERS-01)
			uint256 lossScaled = Math.mulDiv(loss, BPS * PRECISION, _preActionValue(loss, spendValue), Math.Rounding.Ceil);

			state.cumulativeLoss += uint128(lossScaled);
			if (state.cumulativeLoss > toleranceBps * PRECISION) {
				revert CumulativeSlippageExceeded(_bps(state.cumulativeLoss), toleranceBps);
			}
			emit SlippageAccrued(msg.sender, _bps(lossScaled), _bps(state.cumulativeLoss));
		}

		state.lastUpdated = uint64(block.timestamp);
		_states[msg.sender] = state;
	}

	/// @dev Pre-action fund value: post-action GAV + the loss itself. A price elsewhere in the fund going stale (a Veranta stock's
	///      2-minute store, an open perp) must not stop a plain swap (review 2026-11-01, Medium 5): without GAV the loss is charged
	///      against the trade's own value, which can only overstate it.
	function _preActionValue(uint256 loss, uint256 spendValue) private returns (uint256) {
		try Comptroller(msg.sender).calcGav() returns (uint256 gav) {
			return gav + loss;
		} catch {
			return spendValue > loss ? spendValue : loss;
		}
	}

	/// @notice The fund's accrued loss in whole bps, rounded up, as of its last accrual. Same shape as the
	///         original public mapping getter, which the terminal's risk-limits panel reads.
	function slippageStates(address comptroller) external view returns (uint128 cumulativeLossBps, uint64 lastUpdated) {
		SlippageState memory state = _states[comptroller];
		return (uint128(_bps(state.cumulativeLoss)), state.lastUpdated);
	}

	function _bps(uint256 scaled) private pure returns (uint256) {
		return Math.ceilDiv(scaled, PRECISION);
	}

	/// @inheritdoc IPolicy
	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](2);
		hooks[0] = PolicyHook.PostCallOnIntegration;
		hooks[1] = PolicyHook.PostCallOnExternalPosition;
	}
}

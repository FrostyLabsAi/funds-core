// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title MathHelpers
library MathHelpers {
	/// @notice Fixed-point exponentiation by squaring: (x/base)^n scaled by base.
	/// @dev Used for the management fee's continuous compounding
	///      (spec/fee-formulas/managementfee.md: sharesDue = (rpow(rate, dt, 1e27) - 1e27) * TS / 1e27).
	///      Rounds down at each step — the bias slightly under-charges the fee, never over.
	function rpow(uint256 x, uint256 n, uint256 base) internal pure returns (uint256 z) {
		z = base;
		while (n > 0) {
			if (n & 1 == 1) {
				z = Math.mulDiv(z, x, base);
			}
			x = Math.mulDiv(x, x, base);
			n >>= 1;
		}
	}
}

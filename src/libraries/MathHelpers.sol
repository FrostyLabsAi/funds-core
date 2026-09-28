// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title MathHelpers
library MathHelpers {
	/// @notice Fixed-point exponentiation by squaring: (x/base)^n scaled by base.
	/// @dev Management fee compounding. Rounds down at each step, so the fee is never over-charged.
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

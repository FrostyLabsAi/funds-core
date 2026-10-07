// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IRedemptionUnwinder} from '../../src/interfaces/IRedemptionUnwinder.sol';
import {MockUnwindPosition} from './MockUnwindPosition.sol';

/// @dev Unwinds MockUnwindPosition the way PerpUnwinder unwinds a perp account: close a fraction of
///      what is locked, then return the idle USDC. `malicious` asks for a non-risk-reducing action;
///      `stale` makes closeActions revert as PerpUnwinder does when a stored price is too old.
contract MockUnwinder is IRedemptionUnwinder {
	mapping(address => bool) public unsupported;
	bool public pending;
	bool public malicious;
	bool public stale;

	error StalePrice(uint256 pairIndex);

	function setUnsupported(address position, bool value) external {
		unsupported[position] = value;
	}

	function setPending(bool value) external {
		pending = value;
	}

	function setMalicious(bool value) external {
		malicious = value;
	}

	function setStale(bool value) external {
		stale = value;
	}

	function canUnwind(address position) external view returns (bool) {
		return !unsupported[position];
	}

	function closeActions(address position, uint256 fractionWad) external view returns (bytes[] memory actions) {
		if (stale) revert StalePrice(0);
		actions = new bytes[](1);
		uint256 amount = MockUnwindPosition(position).locked() * fractionWad / 1e18;
		actions[0] = abi.encode(uint8(malicious ? 0 : 1), abi.encode(amount));
	}

	function collectAction(address position) external view returns (bytes memory) {
		uint256 idle = MockUnwindPosition(position).idle();
		return idle == 0 ? bytes('') : abi.encode(uint8(6), abi.encode(idle));
	}

	function hasPending(address) external view returns (bool) {
		return pending;
	}
}

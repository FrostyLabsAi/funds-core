// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Vm} from 'forge-std/Vm.sol';

/// @notice Script-only: answers a Coinbase B20 stock token's `decimals()` and `multiplier()` with the real token's
///         values, put at the token's address in forge's LOCAL execution only (vm.etch). Foundry can't run the B20
///         precompile, and listing or pricing a stock reads both. The transactions forge records are the plain listing
///         calls, which run against the real tokens on Base; nothing here is ever deployed.
contract B20LocalStandIn {
	uint8 public decimals;
	uint256 public multiplier;

	function set(uint8 decimals_, uint256 multiplier_) external {
		decimals = decimals_;
		multiplier = multiplier_;
	}

	function balanceOf(address) external pure returns (uint256) {
		return 0;
	}
}

/// @notice Puts a B20LocalStandIn at every B20 token in a list, holding the token's values on Base at the current block.
library B20LocalStandIns {
	Vm private constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

	function standIn(address[] memory tokens) internal returns (uint256 stoodIn) {
		for (uint256 i; i < tokens.length; ++i) {
			if (!isB20(tokens[i])) continue;
			uint8 decimals = abi.decode(_chainCall(tokens[i], 'decimals()'), (uint8));
			uint256 multiplier = abi.decode(_chainCall(tokens[i], 'multiplier()'), (uint256));
			vm.etch(tokens[i], type(B20LocalStandIn).runtimeCode);
			B20LocalStandIn(tokens[i]).set(decimals, multiplier);
			++stoodIn;
		}
	}

	/// @dev A B20 token's code on Base is the single byte 0xef (the precompile marker).
	function isB20(address token) internal view returns (bool) {
		return keccak256(token.code) == keccak256(hex'ef');
	}

	function _chainCall(address token, string memory signature) private returns (bytes memory) {
		string memory params = string.concat(
			'[{"to":"',
			vm.toString(token),
			'","data":"',
			vm.toString(abi.encodeWithSignature(signature)),
			'"},"',
			_hexQuantity(block.number),
			'"]'
		);
		return vm.rpc('eth_call', params);
	}

	function _hexQuantity(uint256 n) private pure returns (string memory) {
		if (n == 0) return '0x0';
		bytes16 digits = '0123456789abcdef';
		uint256 len;
		for (uint256 t = n; t != 0; t >>= 4) {
			++len;
		}
		bytes memory out = new bytes(len + 2);
		out[0] = '0';
		out[1] = 'x';
		for (uint256 i = len + 1; i > 1; --i) {
			out[i] = digits[n & 0xf];
			n >>= 4;
		}
		return string(out);
	}
}

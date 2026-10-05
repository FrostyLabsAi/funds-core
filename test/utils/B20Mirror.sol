// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';

/// @notice Foundry's EVM has no B20 precompile: on Base a B20 token's account code is the one byte
///         0xef, which reverts here. This stand-in answers ONLY what the test loaded from the real
///         chain (eth_call through `vm.rpc` at the fork block) and reverts for any other holder, so
///         no value is invented. Used for ALPHA's tokenized-stock holdings at live head.
/// @dev Moved here from CompoundersMainnetFork (retired 2026-10-04) for V2SwapAdaptersFork, whose
///      live fund ALPHA holds METAc / MSTRc.
contract B20ChainSnapshot {
	uint8 public decimals;
	mapping(address => uint256) internal balances;
	mapping(address => bool) internal loaded;

	error HolderNotLoaded(address holder);

	function setDecimals(uint8 decimals_) external {
		decimals = decimals_;
	}

	function load(address holder, uint256 amount) external {
		balances[holder] = amount;
		loaded[holder] = true;
	}

	function balanceOf(address holder) external view returns (uint256) {
		if (!loaded[holder]) revert HolderNotLoaded(holder);
		return balances[holder];
	}
}

/// @notice Mirrors every B20 token a live fund holds (or its external positions pair) from the real
///         chain, so the fund's GAV can be read on a fork.
abstract contract B20Mirror is Test {
	/// @dev Every B20 token `fund` holds or its positions pair, answered from the chain for the
	///      fund's vault and each of its external positions. Returns how many were mirrored.
	function _mirrorB20s(Comptroller fund) internal returns (uint256 mirrored) {
		address[] memory positions = fund.getExternalPositions();
		address[] memory holders = new address[](positions.length + 1);
		holders[0] = address(fund.vault());
		for (uint256 i; i < positions.length; ++i) {
			holders[i + 1] = positions[i];
		}
		address[] memory tracked = fund.getTrackedAssets();
		for (uint256 i; i < tracked.length; ++i) {
			if (_isB20(tracked[i])) mirrored += _mirror(tracked[i], holders);
		}
		for (uint256 i; i < positions.length; ++i) {
			address[2] memory pair = [_addressView(positions[i], 'token0()'), _addressView(positions[i], 'token1()')];
			for (uint256 j; j < 2; ++j) {
				if (pair[j] != address(0) && _isB20(pair[j])) mirrored += _mirror(pair[j], holders);
			}
		}
	}

	function _mirror(address token, address[] memory holders) internal returns (uint256) {
		uint8 decimals = abi.decode(_chainCall(token, abi.encodeWithSignature('decimals()')), (uint8));
		vm.etch(token, type(B20ChainSnapshot).runtimeCode);
		B20ChainSnapshot(token).setDecimals(decimals);
		for (uint256 i; i < holders.length; ++i) {
			uint256 balance = abi.decode(_chainCall(token, abi.encodeCall(IERC20.balanceOf, (holders[i]))), (uint256));
			B20ChainSnapshot(token).load(holders[i], balance);
		}
		return 1;
	}

	/// @dev eth_call against the real chain at the fork block (the node runs the precompile).
	function _chainCall(address to, bytes memory data) internal returns (bytes memory) {
		string memory params = string.concat(
			'[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', _hexQuantity(block.number), '"]'
		);
		return vm.rpc('eth_call', params);
	}

	function _isB20(address token) internal view returns (bool) {
		return keccak256(token.code) == keccak256(hex'ef');
	}

	function _addressView(address target, string memory signature) internal view returns (address) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
		return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
	}

	function _hexQuantity(uint256 n) internal pure returns (string memory) {
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

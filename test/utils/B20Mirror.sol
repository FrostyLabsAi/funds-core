// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';

/// @notice Foundry's EVM has no B20 precompile: on Base a B20 token's account code is the one byte
///         0xef, which reverts here. This stand-in answers ONLY what the test loaded from the real
///         chain (eth_call through `vm.rpc` at the fork block) and reverts for any other holder, so
///         no value is invented. Used for ALPHA's tokenized-stock holdings at live head.
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

/// @notice A plain ERC-20 put at a B20 token's address, for a fork test that moves the token (FrostyFi 2026-10-25: the
///         stock trades and the stock CLM vault on Aero). B20ChainSnapshot only answers balances; this one transfers. It
///         starts with the real decimals and the real balances of the holders a test names (B20Mirror._standIn), so a
///         pool keeps its real reserves and everything around the token runs as live code. The token's own transfer
///         rules (Base's Policy Registry) it can't stand in for: B20Mirror._b20Allows reads them from Base.
///         `multiplier` is the real token's too, for a stock priced through B20VerantaPriceAdapter (funds-keeper
///         test/fork/release-rehearsal.test.ts, 2026-11-16); declared last, so the earlier fields keep their slots.
contract B20StandIn {
	uint8 public decimals;
	uint256 public totalSupply;
	mapping(address => uint256) public balanceOf;
	mapping(address => mapping(address => uint256)) public allowance;
	uint256 public multiplier;

	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);

	function setDecimals(uint8 decimals_) external {
		decimals = decimals_;
	}

	function setMultiplier(uint256 multiplier_) external {
		multiplier = multiplier_;
	}

	function mint(address to, uint256 amount) external {
		balanceOf[to] += amount;
		totalSupply += amount;
		emit Transfer(address(0), to, amount);
	}

	function approve(address spender, uint256 amount) external returns (bool) {
		allowance[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function transfer(address to, uint256 amount) external returns (bool) {
		_move(msg.sender, to, amount);
		return true;
	}

	function transferFrom(address from, address to, uint256 amount) external returns (bool) {
		uint256 allowed = allowance[from][msg.sender];
		if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
		_move(from, to, amount);
		return true;
	}

	function _move(address from, address to, uint256 amount) private {
		balanceOf[from] -= amount;
		balanceOf[to] += amount;
		emit Transfer(from, to, amount);
	}
}

/// @notice Mirrors every B20 token a live fund holds (or its external positions pair) from the real
///         chain, so the fund's GAV can be read on a fork.
abstract contract B20Mirror is Test {
	/// @dev Base's Policy Registry precompile; each B20 asks it `isAuthorized(policyId, account)` for three scopes
	///      (funds-keeper src/b20/policy-watch.ts: SENDER checks `from`, RECEIVER `to`, EXECUTOR `msg.sender`).
	address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;

	/// @dev Set by _standIn: the fork block every later chain read is made at, whatever the test has rolled to since.
	uint256 internal b20Block;

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

	/// @dev Puts a transferable stand-in at `token` with its real decimals and each holder's real balance at the fork
	///      block (B20StandIn).
	function _standIn(address token, address[] memory holders) internal {
		require(_isB20(token), 'not a B20 on this fork');
		if (b20Block == 0) b20Block = block.number;
		uint8 decimals = abi.decode(_chainCall(token, abi.encodeWithSignature('decimals()')), (uint8));
		uint256[] memory balances = new uint256[](holders.length);
		for (uint256 i; i < holders.length; ++i) {
			balances[i] = abi.decode(_chainCall(token, abi.encodeCall(IERC20.balanceOf, (holders[i]))), (uint256));
		}
		vm.etch(token, type(B20StandIn).runtimeCode);
		B20StandIn(token).setDecimals(decimals);
		for (uint256 i; i < holders.length; ++i) {
			B20StandIn(token).mint(holders[i], balances[i]);
		}
	}

	/// @dev Whether the live token, at the fork block, lets `account` send, receive and move it (all three scopes), with
	///      no feature paused.
	function _b20Allows(address token, address account) internal returns (bool) {
		if (abi.decode(_chainCall(token, abi.encodeWithSignature('pausedFeatures()')), (uint8[])).length != 0) return false;
		string[3] memory scopes = ['TRANSFER_SENDER_POLICY', 'TRANSFER_RECEIVER_POLICY', 'TRANSFER_EXECUTOR_POLICY'];
		for (uint256 i; i < 3; ++i) {
			bytes memory id = _chainCall(token, abi.encodeWithSignature('policyId(bytes32)', keccak256(bytes(scopes[i]))));
			bytes memory ok = _chainCall(
				POLICY_REGISTRY, abi.encodeWithSignature('isAuthorized(uint64,address)', abi.decode(id, (uint64)), account)
			);
			if (!abi.decode(ok, (bool))) return false;
		}
		return true;
	}

	/// @dev eth_call against the real chain at the fork block (the node runs the precompile).
	function _chainCall(address to, bytes memory data) internal returns (bytes memory) {
		uint256 at = b20Block == 0 ? block.number : b20Block;
		string memory params =
			string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', _hexQuantity(at), '"]');
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

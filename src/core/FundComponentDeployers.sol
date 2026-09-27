// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Bytes} from '@openzeppelin/contracts/utils/Bytes.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Comptroller} from './Comptroller.sol';
import {Shares} from '../fund/Shares.sol';
import {Vault} from '../fund/Vault.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IComptrollerDeployer} from '../interfaces/IComptrollerDeployer.sol';

/// @title Fund component deployers
/// @notice Creation bytecode lives here instead of inside FundFactory, keeping every
///         contract under the EIP-170 runtime limit — the same split melon-v1's
///         FundFactory and frosty-core's BondMarketDeployers use for the same reason.
/// @dev Both deployers pass THEIR CALLER through as the components' `factory` authority:
///      when the real FundFactory calls them, components trust the real FundFactory.
///      Anyone else calling a deployer mints components wired to themselves — harmless,
///      since only factory-registered funds exist in the registry or reserve names.

contract ComptrollerDeployer is IComptrollerDeployer {
	function deploy(
		address fundOwner,
		IERC20 denominationAsset,
		IValueInterpreter valueInterpreter,
		Comptroller.FeeConfig calldata feeConfig,
		uint256 sharesActionTimelock,
		uint256 minRequestDuration,
		uint256 executionWindow,
		bool allowRiskyAssets
	) external returns (Comptroller comptroller) {
		comptroller = new Comptroller(
			msg.sender,
			fundOwner,
			denominationAsset,
			valueInterpreter,
			feeConfig,
			sharesActionTimelock,
			minRequestDuration,
			executionWindow,
			allowRiskyAssets
		);
	}
}

/// @title ComptrollerBlueprintDeployer
/// @notice The Comptroller fix path (FundFactory.setComptrollerDeployer): deploys a Comptroller
///         build from creation code kept in data contracts rather than embedded in this one, so a
///         fixed build is not bound by the embedding ComptrollerDeployer's EIP-170 headroom
///         (5 bytes on 2026-09-27 — any real fix outgrows it).
/// @dev The build must keep Comptroller's constructor signature (`deploy` appends exactly those
///      arguments, caller first as `factory`) and every function FundFactory calls on a
///      Comptroller, including `initializeForMigration`. Data contracts are SSTORE2-style:
///      runtime = STOP ‖ chunk, so none of them is callable. `initcodeHash` lets a fund owner
///      check, inside the reconfiguration window, exactly which build will take over.
contract ComptrollerBlueprintDeployer is IComptrollerDeployer {
	uint256 private constant CHUNK_SIZE = 24_000; // + the STOP prefix stays under EIP-170 (24,576)

	address[] private chunks;
	uint256 public immutable initcodeLength;
	bytes32 public immutable initcodeHash;

	error EmptyInitcode();
	error ChunkWriteFailed();
	error DeploymentFailed();

	/// @param build the fixed Comptroller's creation code (type(X).creationCode), no constructor args
	constructor(bytes memory build) {
		if (build.length == 0) revert EmptyInitcode();
		initcodeLength = build.length;
		initcodeHash = keccak256(build);
		for (uint256 start; start < build.length; start += CHUNK_SIZE) {
			chunks.push(_writeChunk(Bytes.slice(build, start, Math.min(start + CHUNK_SIZE, build.length))));
		}
	}

	function chunkCount() external view returns (uint256) {
		return chunks.length;
	}

	/// @inheritdoc IComptrollerDeployer
	function deploy(
		address fundOwner,
		IERC20 denominationAsset,
		IValueInterpreter valueInterpreter,
		Comptroller.FeeConfig calldata feeConfig,
		uint256 sharesActionTimelock,
		uint256 minRequestDuration,
		uint256 executionWindow,
		bool allowRiskyAssets
	) external returns (Comptroller comptroller) {
		// all-static arguments: two encodes concatenate to the constructor's ABI encoding
		bytes memory creation = abi.encodePacked(
			initcode(),
			abi.encode(msg.sender, fundOwner, denominationAsset, valueInterpreter, feeConfig),
			abi.encode(sharesActionTimelock, minRequestDuration, executionWindow, allowRiskyAssets)
		);
		assembly ('memory-safe') {
			comptroller := create(0, add(creation, 0x20), mload(creation))
		}
		if (address(comptroller) == address(0)) revert DeploymentFailed();
	}

	/// @notice The stored creation code, reassembled (keccak256 of it == initcodeHash).
	function initcode() public view returns (bytes memory code) {
		code = new bytes(initcodeLength);
		uint256 written;
		for (uint256 i; i < chunks.length; ++i) {
			address pointer = chunks[i];
			uint256 size = pointer.code.length - 1;
			assembly ('memory-safe') {
				extcodecopy(pointer, add(add(code, 0x20), written), 1, size)
			}
			written += size;
		}
	}

	/// @dev Creation code `PUSH2 n DUP1 PUSH1 0x0a RETURNDATASIZE CODECOPY RETURNDATASIZE RETURN`
	///      returns the n bytes after its 10-byte header: STOP ‖ chunk.
	function _writeChunk(bytes memory chunk) private returns (address pointer) {
		bytes memory creation = abi.encodePacked(hex'61', uint16(chunk.length + 1), hex'80600a3d393df300', chunk);
		assembly ('memory-safe') {
			pointer := create(0, add(creation, 0x20), mload(creation))
		}
		if (pointer == address(0)) revert ChunkWriteFailed();
	}
}

contract SharesVaultDeployer {
	function deploy(string calldata name, string calldata symbol, address comptroller)
		external
		returns (Shares shares, Vault vault)
	{
		shares = new Shares(name, symbol, comptroller, msg.sender);
		vault = new Vault(comptroller, msg.sender);
	}
}

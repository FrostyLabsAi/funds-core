// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';

/// @notice funds-yield ClmPoolDeployer.deployPool, as deployed on Base 2026-10-14 (owner: the genesis deployer).
interface IClmPoolDeployerLike {
	struct PoolConfig {
		address compoundToken;
		address gauge;
		int56 maxTickDeviation;
		address pool;
		int24 positionWidth;
		string symbol;
		uint32 twapInterval;
	}

	function deployPool(PoolConfig calldata cfg) external returns (address strategy, address vault);
}

/// @notice Vaults deployed after DeployClmFunds (2026-10-14: 15 more pools) are listed on the live ClmVaultPriceFeed by
///         ClmFundsDeploy.listUnpriced, through registrar V2: already-priced vaults are skipped, so a rerun lists
///         nothing. Opt-in: BASE_MAINNET_RPC (an archive RPC).
contract ListClmVaultsFork is Test {
	uint256 internal constant FORK_BLOCK = 52_602_200; // after DeployClmFunds (blocks 52,602,118–52,602,130)
	address internal constant DEPLOYER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a;
	address internal constant POOL_DEPLOYER = 0x6083a62eaD5BD586A6F8dB4fb949cB7841331F8b;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;

	bool internal forked;
	ValueInterpreter internal vi = ValueInterpreter(ClmFundsDeploy.VALUE_INTERPRETER);
	ClmVaultPriceFeed internal feed;
	address[] internal listed;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		feed = ClmVaultPriceFeed(vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-clm-funds.json'), '.feed'));
		string memory clm = vm.readFile('deployments/base-mainnet-clm.json');
		string[] memory symbols = vm.parseJsonKeys(clm, '.vaults');
		for (uint256 i; i < symbols.length; ++i) {
			address vault = vm.parseJsonAddress(clm, string.concat('.vaults.', symbols[i], '.vault'));
			// the book grew after this block (15 more pools, deployed after DeployClmFunds): only the vaults that exist here
			if (vault.code.length > 0) listed.push(vault);
		}
	}

	/// @dev WETH-ZRO from funds-yield's config, deployed by the live ClmPoolDeployer as its owner would.
	function _deployWethZro() internal returns (address vault) {
		vm.prank(DEPLOYER);
		(, vault) = IClmPoolDeployerLike(POOL_DEPLOYER).deployPool(
			IClmPoolDeployerLike.PoolConfig({
				compoundToken: WETH,
				gauge: 0x27461E3bD492F7d8c08F21aAb9C817ee00154Eef,
				maxTickDeviation: 5,
				pool: 0x717e174d5dAe280802D1a2c15C1C0976561A3f61,
				positionWidth: 15,
				symbol: 'WETH-ZRO',
				twapInterval: 120
			})
		);
	}

	function test_fork_listsOnlyTheUnpricedVaults() public {
		vm.skip(!forked);
		assertEq(listed.length, 10, 'the first 10 exist at this block');
		for (uint256 i; i < listed.length; ++i) assertTrue(vi.isSupportedAsset(listed[i]), 'the first 10 are priced');
		address fresh = _deployWethZro();
		assertFalse(vi.isSupportedAsset(fresh), 'a new vault starts unpriced');

		address[] memory all = new address[](listed.length + 1);
		for (uint256 i; i < listed.length; ++i) all[i] = listed[i];
		all[listed.length] = fresh;

		vm.startPrank(DEPLOYER);
		assertEq(ClmFundsDeploy.listUnpriced(feed, all), 1, 'only the new vault');
		assertEq(ClmFundsDeploy.listUnpriced(feed, all), 0, 'a rerun lists nothing');
		vm.stopPrank();
		assertTrue(vi.isSupportedAsset(fresh), 'priced on the live feed');
	}
}

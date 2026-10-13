// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {ClmFixture, MockClmVi} from './utils/ClmFixture.sol';

/// @notice Rehearses DeployClmFunds on a Base fork: the feed and adapter deploy, the adapter registers on the real
///         FundFactory, and a vault is listed in the real VI through registrar V2 → today's registrar, all as the
///         real deployer (ClmFundsDeploy is a library, so its calls run as the pranked deployer).
contract DeployClmFundsForkTest is ClmFixture {
	bool internal ready;
	address internal deployer;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0 || !_clmReady()) return;
		vm.createSelectFork(rpc, 52_385_115);
		ready = true;
		deployer = vm.parseJsonAddress(vm.readFile('deployments/base-mainnet.json'), '.deployer');
	}

	function test_deployAndList() public {
		vm.skip(!ready);
		(address strategyFactory, address poolDeployer) = _deployClm(makeAddr('keeper'), address(new MockClmVi()));
		(address vault,) = _deployCbBtcVault(poolDeployer);
		(address s1Vault,) = _deployWethCbLtcVault(poolDeployer);

		vm.startPrank(deployer);
		(ClmVaultPriceFeed feed, ClmVaultAdapter adapter) = ClmFundsDeploy.deploy(strategyFactory);
		address[] memory vaults = new address[](2);
		vaults[0] = vault;
		vaults[1] = s1Vault;
		ClmFundsDeploy.list(feed, vaults);
		vm.stopPrank();

		assertEq(feed.strategyFactory(), strategyFactory);
		assertEq(address(feed.valueInterpreter()), ClmFundsDeploy.VALUE_INTERPRETER);
		assertEq(adapter.router1(), ClmFundsDeploy.SLIPSTREAM1_ROUTER);
		assertEq(adapter.router2(), ClmFundsDeploy.SLIPSTREAM2_ROUTER);
		assertEq(adapter.router3(), ClmFundsDeploy.SLIPSTREAM3_ROUTER);
		assertTrue(FundFactory(ClmFundsDeploy.FUND_FACTORY).isAdapterRegistered(address(adapter)));
		assertTrue(IValueInterpreter(ClmFundsDeploy.VALUE_INTERPRETER).isSupportedAsset(vault), 'the USDC/cbBTC share is priced');
		assertTrue(IValueInterpreter(ClmFundsDeploy.VALUE_INTERPRETER).isSupportedAsset(s1Vault), 'the WETH/cbLTC share is priced');
	}
}

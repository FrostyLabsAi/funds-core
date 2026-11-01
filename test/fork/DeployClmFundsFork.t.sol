// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {ClmVaultAdapter} from '../../src/adapters/ClmVaultAdapter.sol';
import {ClmVaultPriceFeed} from '../../src/pricing/ClmVaultPriceFeed.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
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

	/// @dev ClmFundsDeploy.list as the deployer, as one external call (so expectRevert sees the listing's revert).
	function listAsDeployer(ClmVaultPriceFeed feed, address[] calldata vaults) external {
		vm.startPrank(deployer);
		ClmFundsDeploy.list(feed, vaults);
		vm.stopPrank();
	}

	function test_deployAndList() public {
		vm.skip(!ready);
		(address strategyFactory, address poolDeployer) = _deployClm(makeAddr('keeper'), address(new MockClmVi()));
		(address vault,) = _deployCbBtcVault(poolDeployer);
		(address s1Vault,) = _deployWethCbLtcVault(poolDeployer);

		vm.startPrank(deployer);
		(ClmVaultPriceFeed feed, ClmVaultAdapter adapter) = ClmFundsDeploy.deploy(strategyFactory);
		address[] memory vaults = new address[](1);
		vaults[0] = vault;
		ClmFundsDeploy.list(feed, vaults);
		vm.stopPrank();
		// Final review I1: WETH/cbLTC holds a pool-priced token (cbLTC), so the VI refuses to list it. One external
		// call: list() reads registrar V2's owner first, which a bare expectRevert would take as its call (2026-11-01).
		address[] memory longTail = new address[](1);
		longTail[0] = s1Vault;
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.FeedDoesNotSupportAsset.selector, s1Vault));
		this.listAsDeployer(feed, longTail);

		assertEq(feed.strategyFactory(), strategyFactory);
		assertEq(address(feed.valueInterpreter()), ClmFundsDeploy.VALUE_INTERPRETER);
		assertEq(adapter.router1(), ClmFundsDeploy.SLIPSTREAM1_ROUTER);
		assertEq(adapter.router2(), ClmFundsDeploy.SLIPSTREAM2_ROUTER);
		assertEq(adapter.router3(), ClmFundsDeploy.SLIPSTREAM3_ROUTER);
		assertTrue(FundFactory(ClmFundsDeploy.FUND_FACTORY).isAdapterRegistered(address(adapter)));
		assertTrue(IValueInterpreter(ClmFundsDeploy.VALUE_INTERPRETER).isSupportedAsset(vault), 'the USDC/cbBTC share is priced');
		assertFalse(IValueInterpreter(ClmFundsDeploy.VALUE_INTERPRETER).isSupportedAsset(s1Vault), 'the WETH/cbLTC share is not');
	}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundHost} from './utils/FundHost.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Shares} from '../src/fund/Shares.sol';
import {Vault} from '../src/fund/Vault.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {MaxConcentrationPolicy} from '../src/policies/MaxConcentrationPolicy.sol';
import {MinMaxDepositPolicy} from '../src/policies/MinMaxDepositPolicy.sol';
import {IShares} from '../src/interfaces/IShares.sol';
import {IVault} from '../src/interfaces/IVault.sol';

contract FundFactoryTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 1 days);

		factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer());
		usdc.mint(alice, 10_000e6);
	}

	function _defaultConfig() internal view returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: 'Frosty Alpha',
			symbol: 'frALPHA',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 1500,
			sharesActionTimelock: 1 days,
			minRequestDuration: 30 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
	}

	function _createFund() internal returns (Comptroller comptroller) {
		comptroller = Comptroller(factory.createFund(_defaultConfig()));
	}

	function test_registryAndCount() public {
		address comptrollerAddress = address(_createFund());
		assertEq(factory.fundsCount(), 1);
		(address storedComptroller, address storedVault, address storedShares, address storedOwner,) =
			factory.funds(comptrollerAddress);
		assertEq(storedComptroller, comptrollerAddress);
		assertEq(storedOwner, manager);
		assertEq(Shares(storedShares).comptroller(), comptrollerAddress);
		assertEq(Vault(storedVault).comptroller(), comptrollerAddress);
	}

	function test_fundNames_reservedForever() public {
		_createFund();
		vm.expectRevert(abi.encodeWithSelector(FundFactory.FundNameTaken.selector, 'Frosty Alpha'));
		factory.createFund(_defaultConfig());

		FundFactory.FundConfig memory config = _defaultConfig();
		config.name = 'Frosty Alpha II';
		factory.createFund(config);
		assertEq(factory.fundsCount(), 2);
	}

	function test_createFund_revertsOnZeroAddresses() public {
		FundFactory.FundConfig memory config = _defaultConfig();
		config.denominationAsset = IERC20(address(0));
		vm.expectRevert(FundFactory.ZeroAddress.selector);
		factory.createFund(config);

		config = _defaultConfig();
		config.fundOwner = address(0);
		vm.expectRevert(FundFactory.ZeroAddress.selector);
		factory.createFund(config);
	}

	function test_initialize_onlyFactory_once() public {
		Comptroller comptroller = _createFund();
		IShares shares = comptroller.shares();
		IVault vault = comptroller.vault();

		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.initialize(shares, vault);

		vm.prank(address(factory));
		vm.expectRevert(Comptroller.AlreadyInitialized.selector);
		comptroller.initialize(shares, vault);
	}

	function test_sharesMintBurn_onlyComptroller() public {
		Comptroller comptroller = _createFund();
		IShares shares = comptroller.shares();

		vm.expectRevert(Shares.OnlyComptroller.selector);
		shares.mint(alice, 1e18);

		vm.prank(address(comptroller));
		shares.mint(alice, 1e18);
		assertEq(shares.balanceOf(alice), 1e18);

		vm.expectRevert(Shares.OnlyComptroller.selector);
		shares.burn(alice, 1e18);
	}

	function test_vaultWithdraw_onlyComptroller() public {
		Comptroller comptroller = _createFund();
		IVault vault = comptroller.vault();
		usdc.mint(address(vault), 100e6);

		vm.expectRevert(Vault.OnlyComptroller.selector);
		vault.withdraw(address(usdc), alice, 100e6);

		vm.prank(address(comptroller));
		vault.withdraw(address(usdc), alice, 100e6);
		assertEq(usdc.balanceOf(alice), 10_000e6 + 100e6);
	}

	function test_trackedAssets_ownerGatedAndCapped() public {
		Comptroller comptroller = _createFund();

		MockERC20 weth = new MockERC20('WETH', 'WETH', 18);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.AssetNotSupported.selector, address(weth)));
		comptroller.addTrackedAsset(address(weth));

		MockAggregator wethFeed = new MockAggregator(8, 2500e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(weth), address(wethFeed), 1 days);

		vm.expectRevert(Comptroller.OnlyFundOwner.selector);
		comptroller.addTrackedAsset(address(weth));

		vm.prank(manager);
		comptroller.addTrackedAsset(address(weth));
		assertEq(comptroller.getTrackedAssets().length, 2);

		// No silent residue: cannot untrack an asset the vault still holds
		weth.mint(address(comptroller.vault()), 1e18);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Comptroller.NonZeroBalanceRemoval.selector, address(weth)));
		comptroller.removeTrackedAsset(address(weth));

		// Denomination asset can never be removed
		vm.prank(manager);
		vm.expectRevert(Comptroller.CannotRemoveDenominationAsset.selector);
		comptroller.removeTrackedAsset(address(usdc));
	}

	// ─── createFund with ruleset (born-with-mandate path) ────────────────────────

	function test_createFundWithRuleset_registersPoliciesAtomically() public {
		MaxConcentrationPolicy maxConc = new MaxConcentrationPolicy(5_000);
		MinMaxDepositPolicy minMax = new MinMaxDepositPolicy(100e6, 1_000_000e6);

		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](2);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(maxConc)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(minMax)});

		Comptroller comptroller = Comptroller(factory.createFund(_defaultConfig(), regs));

		assertEq(comptroller.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration)[0], address(maxConc));
		assertEq(comptroller.getPolicies(IPolicy.PolicyHook.PostDepositRequest)[0], address(minMax));

		// The mandate is live before ANY deposit: min-deposit policy rejects a small request
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 10_000e6);
		vm.expectRevert();
		comptroller.requestDeposit(50e6, type(uint256).max); // below the 100 USDC policy minimum
		comptroller.requestDeposit(1_000e6, type(uint256).max); // within mandate — accepted
		vm.stopPrank();
	}

	function test_createFundWithRuleset_rejectsZeroPolicy() public {
		FundFactory.PolicyReg[] memory regs = new FundFactory.PolicyReg[](1);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(0)});
		vm.expectRevert(FundFactory.ZeroAddress.selector);
		factory.createFund(_defaultConfig(), regs);
	}

	function test_addPolicy_setOnce_everyoneRejected() public {
		Comptroller comptroller = Comptroller(factory.createFund(_defaultConfig()));
		MaxConcentrationPolicy policy = new MaxConcentrationPolicy(5_000);
		vm.prank(alice);
		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, address(policy));
		vm.prank(manager);
		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.addPolicy(IPolicy.PolicyHook.PostCallOnIntegration, address(policy));
	}

	function test_fundNameTaken_liveCheck() public {
		assertFalse(factory.fundNameTaken('Frosty Alpha'));
		factory.createFund(_defaultConfig());
		assertTrue(factory.fundNameTaken('Frosty Alpha'));
	}
}

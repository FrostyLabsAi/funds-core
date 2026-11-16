// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ComptrollerLib} from '../../src/core/ComptrollerLib.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/ComptrollerBlueprintDeployer.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {RedemptionQueueShortDeadline} from '../utils/RedemptionQueueShortDeadline.sol';
import {Release} from '../../script/release/Release.sol';
import {Vm, VmSafe} from 'forge-std/Vm.sol';
import {IComptrollerDeployer} from '../../src/interfaces/IComptrollerDeployer.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';

/// @notice The clean release on live Base: every contract wired as Release.deploy wires it, then a fund on real venues:
///         the instant exit in USDC, a real perp account's close of 0 refused, and a keeper's liquidation selling WETH on
///         Uniswap within the 3% cap.
contract ReleaseForkTest is ReleaseFork {
	function test_fork_release_wiresEverything() public {
		vm.skip(!forked);
		assertEq(r.valueInterpreter.owner(), address(r.registrar), 'the registrar owns the VI');
		assertEq(address(r.registrar.valueInterpreter()), address(r.valueInterpreter));
		assertTrue(r.registrar.isQuote(USDC) && r.registrar.isQuote(WETH) && r.registrar.isQuote(BaseMainnet.CBBTC));
		assertTrue(r.registrar.isPoolApprover(BaseMainnet.ADMIN_SAFE));
		assertTrue(r.sampler.isKeeper(keeper));
		assertGt(r.valueInterpreter.calcUsdRate(WETH), 0, 'Chainlink ETH reads');

		assertEq(r.factory.guardian(), BaseMainnet.ADMIN_SAFE);
		assertEq(address(r.factory.comptrollerDeployer()), address(r.comptrollerDeployer));
		assertEq(r.comptrollerDeployer.extraConstructorArgs(), abi.encode(r.registrar, r.queue, r.perpConfig));
		assertEq(r.factory.positionTypeFactories(BaseMainnet.VERANTA_PERP_TYPE), address(r.perpFactory));
		Release.Adapters memory a = r.adapters;
		address[12] memory adapters = [
			address(a.uniswapV3), address(a.uniswapV4), address(a.slipstream1), address(a.slipstream2), address(a.slipstream3),
			address(a.aero), address(a.aerodromeBasic), address(a.viaWeth), address(a.clm), address(a.clmExit),
			address(a.erc4626), address(a.erc4626Exit)
		];
		for (uint256 i; i < adapters.length; ++i) {
			assertTrue(r.factory.isAdapterRegistered(adapters[i]));
		}
		FundFactory.PolicyReg[] memory mandatory = r.factory.getMandatoryPolicies();
		assertEq(mandatory.length, 3);
		assertEq(mandatory[0].policy, address(r.minPoolLiquidity));
		assertEq(uint8(mandatory[2].hook), uint8(IPolicy.PolicyHook.PostCallOnExternalPosition));

		assertEq(address(r.queue.factory()), address(r.factory));
		assertTrue(r.queue.isKeeper(keeper));
		assertEq(r.perpConfig.autopilotKeeper(), keeper);
		assertEq(address(r.perpConfig.referral()), BaseMainnet.VERANTA_REFERRAL);
		assertEq(r.perpConfig.referralCode(), BaseMainnet.VERANTA_REFERRAL_CODE);
		assertEq(address(r.perpFactory.config()), address(r.perpConfig));
	}

	/// createFund is open to anyone and a fund keeps the policies it was created with, so the factory must create
	/// nothing until its guardian, mandatory policies, adapters and perp type are set (review 2026-11-16: one created
	/// between the factory's deployment and setMandatoryPolicies stayed in the registry without the liquidity floor and
	/// the slippage budget). Release.deploy starts it with the VI as its comptroller deployer and sets the real one last.
	function test_fork_release_theFactoryCreatesNoFundUntilItIsWired() public {
		vm.skip(!forked);
		vm.startStateDiffRecording();
		Release.Deployed memory fresh = Release.deploy(
			Release.Config({owner: address(this), treasury: BaseMainnet.TREASURY, guardian: BaseMainnet.ADMIN_SAFE, keeper: keeper})
		);
		Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
		address builtWith;
		bytes memory lastCall;
		for (uint256 i; i < accesses.length; ++i) {
			if (accesses[i].account != address(fresh.factory)) continue;
			if (accesses[i].kind == VmSafe.AccountAccessKind.Create) {
				// the constructor's arguments end the creation code: (valueInterpreter, comptrollerDeployer, sharesVaultDeployer)
				bytes memory code = accesses[i].data;
				uint256 at = code.length - 32;
				assembly ('memory-safe') {
					builtWith := mload(add(code, at))
				}
			} else if (accesses[i].kind == VmSafe.AccountAccessKind.Call && accesses[i].accessor == address(this)) {
				lastCall = accesses[i].data;
			}
		}
		assertEq(builtWith, address(fresh.valueInterpreter), 'created with the VI in the comptroller deployer\'s place');
		assertEq(
			lastCall,
			abi.encodeCall(FundFactory.setComptrollerDeployer, (fresh.comptrollerDeployer)),
			"the real deployer is the owner's last call on the factory"
		);

		// and what stands in for it until then creates nothing
		FundFactory unwired = new FundFactory(
			fresh.valueInterpreter, IComptrollerDeployer(address(fresh.valueInterpreter)), fresh.sharesVaultDeployer
		);
		vm.expectRevert(bytes(''));
		unwired.createFund(
			FundFactory.FundConfig({
				name: 'Unwired',
				symbol: 'frNONE',
				denominationAsset: IERC20(USDC),
				fundOwner: manager,
				mgmtScaledPerSecondRate: 0,
				perfFeeBps: 0,
				sharesActionTimelock: 0,
				minRequestDuration: 1 minutes,
				executionWindow: 1 days,
				allowRiskyAssets: false
			})
		);
	}

	function test_fork_aNewFundIsWiredToTheRelease() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithDeposit(1_000e6);
		assertEq(address(fund.redemptionQueue()), address(r.queue));
		assertEq(address(fund.registrar()), address(r.registrar));
		assertEq(fund.perpConfig(), address(r.perpConfig));
		assertEq(address(fund.valueInterpreter()), address(r.valueInterpreter));
		assertLt(address(fund).code.length, 24_577, 'EIP-170');
		assertEq(fund.calcGav(), 1_000e6);
	}

	function test_fork_theInstantExitPaysUsdc() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithDeposit(1_000e6);
		uint256 half = fund.shares().balanceOf(investor) / 2;
		uint256 supply = fund.shares().totalSupply();
		vm.prank(investor);
		fund.redeemShares(half);
		assertEq(IERC20(USDC).balanceOf(investor), 1_000e6 * half / supply);
	}

	/// The perp config is what a real perp account names: its close of 0 is refused.
	function test_fork_aRealPerpAccountsCloseOfNothingIsRefused() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithDeposit(1_000e6);
		vm.prank(manager);
		address account = fund.createExternalPosition(BaseMainnet.VERANTA_PERP_TYPE, '');
		bytes memory nothing = abi.encode(uint8(1), abi.encode(uint256(129), uint256(0), uint256(0), uint256(730_600_000_000)));
		assertTrue(ComptrollerLib.closesNothing(address(r.perpConfig), account, nothing));
		vm.prank(manager);
		vm.expectRevert(ComptrollerLib.CloseOfNothing.selector);
		fund.callOnExternalPosition(account, new address[](0), new uint256[](0), new address[](0), nothing);
	}

	/// The manager ghosts: the keeper sells the fund's WETH on Uniswap's 0.05% pool within the 3% cap against Chainlink,
	/// then settles; the investor is paid in USDC. (A 1-second deadline queue keeps the ETH round fresh.)
	function test_fork_aKeeperLiquidatesWethOnUniswap_andSettlesInUsdc() public {
		vm.skip(!forked);
		RedemptionQueue queue = new RedemptionQueueShortDeadline(address(this));
		queue.setFactory(address(r.factory));
		queue.setKeeper(keeper, true);
		r.factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(Comptroller).creationCode, abi.encode(r.registrar, queue, r.perpConfig))
		);
		Comptroller fund = _fundWithDeposit(10_000e6);
		address uni = address(r.adapters.uniswapV3);
		vm.prank(manager);
		fund.callOnIntegration(uni, abi.encode(USDC, WETH, uint24(500), uint256(8_000e6), uint256(0)));
		uint256 weth = IERC20(WETH).balanceOf(address(fund.vault()));
		assertGt(weth, 0);

		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2);
		vm.roll(block.number + 10);
		assertTrue(queue.isOverdue(address(fund)));

		uint256 gavBefore = fund.calcGav();
		vm.prank(keeper);
		queue.liquidate(address(fund), uni, abi.encode(WETH, USDC, uint24(500), weth, uint256(0)));
		assertEq(IERC20(WETH).balanceOf(address(fund.vault())), 0, 'all sold');
		uint256 gavAfter = fund.calcGav();
		// the pool can pay more than Chainlink's price at the fork block, so the change is signed
		emit log_named_int('liquidation result vs Chainlink (USDC, 6 decimals)', int256(gavAfter) - int256(gavBefore));
		assertGt(gavAfter, gavBefore * 9_970 / 10_000, 'within the 3% cap, and far under it');

		uint256 supply = fund.shares().totalSupply();
		vm.prank(keeper);
		assertEq(queue.settle(address(fund), 1), 1);
		assertApproxEqAbs(IERC20(USDC).balanceOf(investor), gavAfter * shares / supply, 2);
		assertEq(IERC20(WETH).balanceOf(investor), 0, 'never a token');
	}
}

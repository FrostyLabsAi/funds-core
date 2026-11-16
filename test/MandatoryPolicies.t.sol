// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundHost} from './utils/FundHost.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {SharesVaultDeployer} from '../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {MaxConcentrationPolicy} from '../src/policies/MaxConcentrationPolicy.sol';
import {MinMaxDepositPolicy} from '../src/policies/MinMaxDepositPolicy.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @notice Protocol-mandatory policies: attached to every new fund on top of its own
///         ruleset, never twice, and picked up by funds that predate them when they reconfigure.
contract MandatoryPoliciesTest is Test {
	FundFactory internal factory;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	MaxConcentrationPolicy internal integrationPolicy;
	MinMaxDepositPolicy internal depositPolicy;
	address internal manager = makeAddr('manager');
	uint256 internal nonce;

	function setUp() public {
		vm.warp(30 days);
		ValueInterpreter vi = new ValueInterpreter(address(this));
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		vi.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		factory = new FundFactory(vi, FundHost.deployer(), new SharesVaultDeployer());
		integrationPolicy = new MaxConcentrationPolicy(5_000);
		depositPolicy = new MinMaxDepositPolicy(1e6, 1_000_000e6);
	}

	function _config() internal returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: string.concat('Fund #', vm.toString(++nonce)),
			symbol: 'F',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: 0,
			minRequestDuration: 30 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
	}

	function _mandatory() internal view returns (FundFactory.PolicyReg[] memory regs) {
		regs = new FundFactory.PolicyReg[](2);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(integrationPolicy)});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(depositPolicy)});
	}

	function _count(Comptroller c, IPolicy.PolicyHook hook, address policy) internal view returns (uint256 n) {
		address[] memory list = c.getPolicies(hook);
		for (uint256 i; i < list.length; ++i) if (list[i] == policy) ++n;
	}

	function test_setMandatoryPolicies_onlyOwner_noZero() public {
		FundFactory.PolicyReg[] memory regs = _mandatory();
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		factory.setMandatoryPolicies(regs);

		regs[1].policy = address(0);
		vm.expectRevert(FundFactory.ZeroAddress.selector);
		factory.setMandatoryPolicies(regs);
	}

	function test_everyNewFundCarriesThem_withOrWithoutARuleset() public {
		factory.setMandatoryPolicies(_mandatory());
		assertEq(factory.getMandatoryPolicies().length, 2);

		Comptroller bare = Comptroller(factory.createFund(_config()));
		assertEq(_count(bare, IPolicy.PolicyHook.PostCallOnIntegration, address(integrationPolicy)), 1);
		assertEq(_count(bare, IPolicy.PolicyHook.PostDepositRequest, address(depositPolicy)), 1);
		// the fund still carries its own declaration next to the protocol's rules
		assertEq(_count(bare, IPolicy.PolicyHook.PostCallOnIntegration, factory.unrestrictedMandate()), 1);

		FundFactory.PolicyReg[] memory none = new FundFactory.PolicyReg[](0);
		Comptroller ruled = Comptroller(factory.createFund(_config(), none));
		assertEq(_count(ruled, IPolicy.PolicyHook.PostCallOnIntegration, address(integrationPolicy)), 1);
		assertEq(_count(ruled, IPolicy.PolicyHook.PostDepositRequest, address(depositPolicy)), 1);
	}

	function test_aManagerIncludingOneAlready_isNotAttachedTwice() public {
		factory.setMandatoryPolicies(_mandatory());
		FundFactory.PolicyReg[] memory own = new FundFactory.PolicyReg[](1);
		own[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(integrationPolicy)});
		Comptroller c = Comptroller(factory.createFund(_config(), own));
		assertEq(_count(c, IPolicy.PolicyHook.PostCallOnIntegration, address(integrationPolicy)), 1);
	}

	function test_existingFundsUntouched_untilTheyReconfigure() public {
		Comptroller old = Comptroller(factory.createFund(_config()));
		factory.setMandatoryPolicies(_mandatory());
		assertEq(_count(old, IPolicy.PolicyHook.PostDepositRequest, address(depositPolicy)), 0, 'set-once ruleset untouched');

		FundFactory.FundConfig memory cfg = _config();
		(,,, address fundOwner,) = factory.funds(address(old));
		cfg.fundOwner = fundOwner;
		cfg.name = 'Reconfigured';
		vm.prank(manager);
		address next = factory.createReconfigurationRequest(address(old), cfg);
		skip(2 days);
		usdcFeed.setAnswer(1e8);
		vm.prank(manager);
		factory.executeReconfiguration(address(old));

		Comptroller c = Comptroller(next);
		assertEq(_count(c, IPolicy.PolicyHook.PostCallOnIntegration, address(integrationPolicy)), 1);
		assertEq(_count(c, IPolicy.PolicyHook.PostDepositRequest, address(depositPolicy)), 1);
		assertEq(_count(c, IPolicy.PolicyHook.PostCallOnIntegration, factory.unrestrictedMandate()), 1, 'own ruleset carried over');
	}

	function test_emptyListByDefault_nothingAttached() public {
		Comptroller c = Comptroller(factory.createFund(_config()));
		assertEq(c.getPolicies(IPolicy.PolicyHook.PostDepositRequest).length, 0);
		assertEq(c.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration).length, 1); // the declaration only
	}
}

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

/// @dev A redemption rule with a fail-closed bug: `broken` refuses EVERY cash redemption. The
///      fixed build is the same contract with the bug gone — a real one-for-one replacement.
contract RedemptionGatePolicy is IPolicy {
	bool public immutable broken;

	constructor(bool broken_) {
		broken = broken_;
	}

	function validate(PolicyHook, bytes calldata) external view {
		if (broken) revert('redemption gate bug');
	}

	function implementedHooks() external pure returns (PolicyHook[] memory hooks) {
		hooks = new PolicyHook[](1);
		hooks[0] = PolicyHook.RedeemSharesForSpecificAssets;
	}
}

/// @notice The policy fix path: governance approves "buggy policy → fixed policy", a fund OWNER
///         opts in through reconfiguration, every other rule carries over verbatim, and nothing
///         lets a manager drop or pick a rule.
contract PolicySwapTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	MockAggregator internal usdcFeed;
	RedemptionGatePolicy internal buggy;
	RedemptionGatePolicy internal fixedGate;
	MaxConcentrationPolicy internal concentration;
	MinMaxDepositPolicy internal depositLimits;
	Comptroller internal fund;

	address internal manager = makeAddr('manager');
	address internal guardian = makeAddr('guardian');
	address internal alice = makeAddr('alice');
	uint256 internal nonce;

	event PolicyReplacementSet(address indexed policy, address indexed replacement);
	event PolicySwapRequested(address indexed oldComptroller, address indexed from, address indexed to);

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(address(this));
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);
		factory = new FundFactory(interpreter, FundHost.deployer(), new SharesVaultDeployer());
		factory.setGuardian(guardian);

		buggy = new RedemptionGatePolicy(true);
		fixedGate = new RedemptionGatePolicy(false);
		concentration = new MaxConcentrationPolicy(5_000);
		depositLimits = new MinMaxDepositPolicy(1e6, 1_000_000e6);
		fund = _fundWith(_ruleset(address(buggy)));
		_deposit(fund, alice, 10_000e6);
	}

	function _ruleset(address gate) internal view returns (FundFactory.PolicyReg[] memory regs) {
		regs = new FundFactory.PolicyReg[](3);
		regs[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.RedeemSharesForSpecificAssets, policy: gate});
		regs[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(concentration)});
		regs[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostDepositRequest, policy: address(depositLimits)});
	}

	function _config() internal returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: string.concat('Frosty Fund ', vm.toString(++nonce)),
			symbol: 'frPOL',
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

	function _fundWith(FundFactory.PolicyReg[] memory regs) internal returns (Comptroller) {
		return Comptroller(factory.createFund(_config(), regs));
	}

	function _deposit(Comptroller c, address who, uint256 amount) internal {
		usdc.mint(who, amount);
		vm.startPrank(who);
		usdc.approve(address(c), amount);
		c.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		skip(30 minutes);
		c.executeDepositRequest(who);
	}

	function _only(address policy) internal pure returns (address[] memory list) {
		list = new address[](1);
		list[0] = policy;
	}

	function _request(Comptroller c, address[] memory swaps) internal returns (Comptroller fresh) {
		FundFactory.FundConfig memory config = _config();
		vm.prank(manager);
		fresh = Comptroller(factory.createReconfigurationRequest(address(c), config, swaps));
	}

	function _expectRequestReverts(Comptroller c, address[] memory swaps, bytes memory reason) internal {
		FundFactory.FundConfig memory config = _config();
		vm.prank(manager);
		vm.expectRevert(reason);
		factory.createReconfigurationRequest(address(c), config, swaps);
	}

	function _execute(Comptroller c) internal {
		skip(2 days);
		usdcFeed.setAnswer(1e8);
		vm.prank(manager);
		factory.executeReconfiguration(address(c));
	}

	function _gatesOn(Comptroller c) internal view returns (address[] memory) {
		return c.getPolicies(IPolicy.PolicyHook.RedeemSharesForSpecificAssets);
	}

	function test_theBugBlocksCashRedemptions_theSwapFixesIt_everythingElseCarries() public {
		vm.prank(alice);
		vm.expectRevert(bytes('redemption gate bug'));
		fund.redeemShares(1000e18);

		factory.setPolicyReplacement(address(buggy), address(fixedGate));
		vm.expectEmit(true, true, true, false, address(factory));
		emit PolicySwapRequested(address(fund), address(buggy), address(fixedGate));
		Comptroller fresh = _request(fund, _only(address(buggy)));
		FundFactory.PolicySwap[] memory pending = factory.getRequestedPolicySwaps(address(fund));
		assertEq(pending.length, 1);
		assertEq(pending[0].from, address(buggy));
		assertEq(pending[0].to, address(fixedGate)); // visible to investors for the whole window
		_execute(fund);

		address[] memory gates = _gatesOn(fresh);
		assertEq(gates.length, 1);
		assertEq(gates[0], address(fixedGate));
		assertEq(fresh.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration)[0], address(concentration));
		assertEq(fresh.getPolicies(IPolicy.PolicyHook.PostDepositRequest)[0], address(depositLimits));
		assertEq(factory.getRequestedPolicySwaps(address(fund)).length, 0);

		vm.prank(alice);
		fresh.redeemShares(1000e18);
		assertEq(usdc.balanceOf(alice), 1000e6);
	}

	function test_onlyGovernanceApproves_andAReplacementMustCoverEveryHook() public {
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, manager));
		factory.setPolicyReplacement(address(buggy), address(fixedGate));

		vm.expectRevert(FundFactory.InvalidPolicyReplacement.selector);
		factory.setPolicyReplacement(address(buggy), address(0));
		vm.expectRevert(FundFactory.InvalidPolicyReplacement.selector);
		factory.setPolicyReplacement(address(buggy), address(buggy));

		// a deposit rule can't stand in for a redemption rule — the fund would lose the check
		vm.expectRevert(abi.encodeWithSelector(FundFactory.ReplacementHookMismatch.selector, address(buggy), address(depositLimits)));
		factory.setPolicyReplacement(address(buggy), address(depositLimits));

		vm.expectEmit(true, true, false, false, address(factory));
		emit PolicyReplacementSet(address(buggy), address(fixedGate));
		factory.setPolicyReplacement(address(buggy), address(fixedGate));
		assertEq(factory.policyReplacements(address(buggy)), address(fixedGate));
	}

	function test_aManagerCannotSwapAnythingUnapproved() public {
		_expectRequestReverts(fund, _only(address(buggy)), abi.encodeWithSelector(FundFactory.PolicyReplacementNotApproved.selector, address(buggy)));

		// approved elsewhere, but not a rule this fund carries
		RedemptionGatePolicy stranger = new RedemptionGatePolicy(true);
		factory.setPolicyReplacement(address(stranger), address(fixedGate));
		_expectRequestReverts(fund, _only(address(stranger)), abi.encodeWithSelector(FundFactory.PolicyNotAttached.selector, address(stranger)));

		factory.setPolicyReplacement(address(buggy), address(fixedGate));
		address[] memory twice = new address[](2);
		(twice[0], twice[1]) = (address(buggy), address(buggy));
		_expectRequestReverts(fund, twice, abi.encodeWithSelector(FundFactory.DuplicatePolicySwap.selector, address(buggy)));
	}

	function test_aRevocationMidWindowBlocksExecution_andCancelClearsTheSwaps() public {
		factory.setPolicyReplacement(address(buggy), address(fixedGate));
		_request(fund, _only(address(buggy)));

		vm.prank(guardian); // a tightening: the guardian may revoke instantly
		factory.revokePolicyReplacement(address(buggy));

		skip(2 days);
		usdcFeed.setAnswer(1e8);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(FundFactory.PolicyReplacementChanged.selector, address(buggy)));
		factory.executeReconfiguration(address(fund));

		vm.prank(manager);
		factory.cancelReconfigurationRequest(address(fund));
		assertEq(factory.getRequestedPolicySwaps(address(fund)).length, 0);

		vm.prank(alice);
		vm.expectRevert(FundFactory.OnlyGuardian.selector);
		factory.revokePolicyReplacement(address(buggy));
	}

	function test_aDifferentReplacementApprovedMidWindowBlocksExecution() public {
		factory.setPolicyReplacement(address(buggy), address(fixedGate));
		_request(fund, _only(address(buggy)));

		RedemptionGatePolicy other = new RedemptionGatePolicy(false);
		factory.setPolicyReplacement(address(buggy), address(other)); // not what investors reviewed

		skip(2 days);
		usdcFeed.setAnswer(1e8);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(FundFactory.PolicyReplacementChanged.selector, address(buggy)));
		factory.executeReconfiguration(address(fund));
	}

	function test_withoutTheOwnersOptIn_theRuleCarriesVerbatim() public {
		factory.setPolicyReplacement(address(buggy), address(fixedGate));
		Comptroller fresh = _request(fund, new address[](0));
		_execute(fund);

		address[] memory gates = _gatesOn(fresh);
		assertEq(gates.length, 1);
		assertEq(gates[0], address(buggy));
	}

	function test_mandatoryPolicy_fixReachesNewFunds_andTheBugIsNeverReattached() public {
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](1);
		mandatory[0] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.RedeemSharesForSpecificAssets, policy: address(buggy)});
		factory.setMandatoryPolicies(mandatory);
		Comptroller early = Comptroller(factory.createFund(_config()));
		assertEq(_gatesOn(early)[0], address(buggy));

		factory.setPolicyReplacement(address(buggy), address(fixedGate));

		// a fund created now gets the fix, never the bug
		Comptroller later = Comptroller(factory.createFund(_config()));
		address[] memory laterGates = _gatesOn(later);
		assertEq(laterGates.length, 1);
		assertEq(laterGates[0], address(fixedGate));

		// the early fund opts in: the fix replaces the bug, and the mandatory pass doesn't add it back
		Comptroller fresh = _request(early, _only(address(buggy)));
		_execute(early);
		address[] memory freshGates = _gatesOn(fresh);
		assertEq(freshGates.length, 1);
		assertEq(freshGates[0], address(fixedGate));
	}
}

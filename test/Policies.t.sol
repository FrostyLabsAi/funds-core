// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../src/core/FundFactory.sol';
import {ComptrollerDeployer, SharesVaultDeployer} from '../src/core/FundComponentDeployers.sol';
import {Comptroller} from '../src/core/Comptroller.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {Shares} from '../src/fund/Shares.sol';
import {IPolicy} from '../src/interfaces/IPolicy.sol';
import {AllowedDepositorsPolicy} from '../src/policies/AllowedDepositorsPolicy.sol';
import {AllowedSharesTransferRecipientsPolicy} from '../src/policies/AllowedSharesTransferRecipientsPolicy.sol';
import {MinMaxDepositPolicy} from '../src/policies/MinMaxDepositPolicy.sol';
import {MaxPositionsPolicy} from '../src/policies/MaxPositionsPolicy.sol';
import {UnrestrictedMandatePolicy} from '../src/policies/UnrestrictedMandatePolicy.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';

/// @notice Policies are set once: every test registers its ruleset at creation via
///         createFund(config, policies) — there is no post-launch path.
contract PoliciesTest is Test {
	FundFactory internal factory;
	ValueInterpreter internal interpreter;
	MockERC20 internal usdc;
	uint256 internal fundNonce;

	address internal admin = makeAddr('admin');
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal carol = makeAddr('carol');

	function setUp() public {
		vm.warp(30 days);
		interpreter = new ValueInterpreter(admin);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		MockAggregator usdcFeed = new MockAggregator(8, 1e8);
		vm.prank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcFeed), 7 days);

		factory = new FundFactory(interpreter, new ComptrollerDeployer(), new SharesVaultDeployer());
		usdc.mint(alice, 100_000e6);
		usdc.mint(carol, 100_000e6);
	}

	/// @dev A fund born with the given ruleset (unique name per call).
	function _fundWith(FundFactory.PolicyReg[] memory policies) internal returns (Comptroller) {
		return Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('Regulated Fund #', vm.toString(++fundNonce)),
					symbol: 'REG',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 30 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				}),
				policies
			)
		);
	}

	function _one(IPolicy.PolicyHook hook, address policy) internal pure returns (FundFactory.PolicyReg[] memory regs) {
		regs = new FundFactory.PolicyReg[](1);
		regs[0] = FundFactory.PolicyReg({hook: hook, policy: policy});
	}

	function test_allowedDepositorsPolicy_gatesRequests() public {
		address[] memory allowed = new address[](1);
		allowed[0] = alice;
		AllowedDepositorsPolicy policy = new AllowedDepositorsPolicy(manager, allowed);
		Comptroller comptroller = _fundWith(_one(IPolicy.PolicyHook.PostDepositRequest, address(policy)));

		// Alice (whitelisted) can request
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1000e6);
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();

		// Carol (not whitelisted) cannot
		vm.startPrank(carol);
		usdc.approve(address(comptroller), 1000e6);
		vm.expectRevert(abi.encodeWithSelector(AllowedDepositorsPolicy.DepositorNotAllowed.selector, carol));
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();

		// Membership maintenance stays with the manager (the POLICY SET is frozen,
		// the whitelist's own roster is not)
		address[] memory newDepositors = new address[](1);
		newDepositors[0] = carol;
		vm.prank(manager);
		policy.addDepositors(newDepositors);

		vm.prank(carol);
		comptroller.requestDeposit(1000e6);
	}

	function test_minMaxDepositPolicy_boundsSize() public {
		MinMaxDepositPolicy policy = new MinMaxDepositPolicy(100e6, 10_000e6);
		Comptroller comptroller = _fundWith(_one(IPolicy.PolicyHook.PostDepositRequest, address(policy)));

		vm.startPrank(alice);
		usdc.approve(address(comptroller), 100_000e6);

		vm.expectRevert(abi.encodeWithSelector(MinMaxDepositPolicy.DepositOutOfBounds.selector, 50e6));
		comptroller.requestDeposit(50e6);

		vm.expectRevert(abi.encodeWithSelector(MinMaxDepositPolicy.DepositOutOfBounds.selector, 20_000e6));
		comptroller.requestDeposit(20_000e6);

		comptroller.requestDeposit(5000e6);
		vm.stopPrank();
	}

	function test_setOnce_nobodyAddsPoliciesAfterCreation() public {
		Comptroller comptroller = _fundWith(new FundFactory.PolicyReg[](0));
		MinMaxDepositPolicy policy = new MinMaxDepositPolicy(0, 1);

		// Not the manager…
		vm.prank(manager);
		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.addPolicy(IPolicy.PolicyHook.PostDepositRequest, address(policy));

		// …and certainly not anyone else. The ruleset is a permanent commitment.
		vm.prank(alice);
		vm.expectRevert(Comptroller.OnlyFactory.selector);
		comptroller.addPolicy(IPolicy.PolicyHook.PostDepositRequest, address(policy));
	}

	function test_mandateRequired_unrestrictedAttachedWhenNoneSupplied() public {
		// No policies at all → the protocol-wide declaration is attached
		Comptroller bare = _fundWith(new FundFactory.PolicyReg[](0));
		address[] memory mandate = bare.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration);
		assertEq(mandate.length, 1);
		assertEq(mandate[0], factory.unrestrictedMandate());

		// Policies on other hooks but no mandate → still attached
		Comptroller other = _fundWith(
			_one(IPolicy.PolicyHook.PostDepositRequest, address(new MinMaxDepositPolicy(1, 100e6)))
		);
		assertEq(other.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration)[0], factory.unrestrictedMandate());

		// An explicit mandate supplied → no unrestricted auto-attach
		MaxPositionsPolicy maxPos = new MaxPositionsPolicy(3);
		Comptroller mandated = _fundWith(_one(IPolicy.PolicyHook.PostCallOnIntegration, address(maxPos)));
		address[] memory policies = mandated.getPolicies(IPolicy.PolicyHook.PostCallOnIntegration);
		assertEq(policies.length, 1);
		assertEq(policies[0], address(maxPos));
	}

	function test_maxPositionsPolicy_countsExternalPositions() public {
		MaxPositionsPolicy policy = new MaxPositionsPolicy(1);
		// validate() reads live comptroller state; called via the comptroller in
		// integration — here we exercise the counting rule directly
		Comptroller comptroller = _fundWith(_one(IPolicy.PolicyHook.PostCallOnIntegration, address(policy)));
		vm.prank(address(comptroller));
		policy.validate(IPolicy.PolicyHook.PostCallOnIntegration, ''); // 0 positions ≤ 1 — passes
	}

	function test_transferRecipientsPolicy_gatesSecondaryTransfers() public {
		address bob = makeAddr('bob');
		address[] memory allowed = new address[](1);
		allowed[0] = bob;
		AllowedSharesTransferRecipientsPolicy policy = new AllowedSharesTransferRecipientsPolicy(manager, allowed);
		Comptroller comptroller = _fundWith(_one(IPolicy.PolicyHook.PreTransferShares, address(policy)));

		// Alice deposits (mint is untouched by the transfer gate)
		vm.startPrank(alice);
		usdc.approve(address(comptroller), 1000e6);
		comptroller.requestDeposit(1000e6);
		vm.stopPrank();
		skip(30 minutes);
		comptroller.executeDepositRequest(alice);

		Shares shares = comptroller.shares();

		// Secondary transfer to listed bob: allowed
		vm.prank(alice);
		shares.transfer(bob, 100e18);

		// To an unlisted wallet: blocked — the regulated gate holds on secondary sales
		vm.prank(alice);
		vm.expectRevert(abi.encodeWithSelector(AllowedSharesTransferRecipientsPolicy.TransferRecipientNotAllowed.selector, carol));
		shares.transfer(carol, 100e18);

		// Manager onboards carol (roster maintenance survives set-once)
		address[] memory add = new address[](1);
		add[0] = carol;
		vm.prank(manager);
		policy.addRecipients(add);
		vm.prank(alice);
		shares.transfer(carol, 100e18);

		// Redemption (burn) is never gated
		vm.prank(alice);
		comptroller.redeemSharesForDenominationAsset(100e18);
	}

	function test_unrestrictedMandate_isNoOp() public {
		UnrestrictedMandatePolicy mandate = UnrestrictedMandatePolicy(factory.unrestrictedMandate());
		mandate.validate(IPolicy.PolicyHook.PostCallOnIntegration, ''); // never reverts
		IPolicy.PolicyHook[] memory hooks = mandate.implementedHooks();
		assertEq(uint8(hooks[0]), uint8(IPolicy.PolicyHook.PostCallOnIntegration));
	}
}

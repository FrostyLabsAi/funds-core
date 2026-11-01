// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV3} from '../../src/core/ComptrollerV3.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV4, VerantaPerpPositionV4Factory} from '../../src/positions/VerantaPerpPositionV4.sol';
import {PerpUnwinder} from '../../src/redemption/PerpUnwinder.sol';
import {DeployPerpAccountV4} from '../../script/mainnet/DeployPerpAccountV4.s.sol';

interface IReferralReads {
	function getTraderReferralInfo(address account) external view returns (bytes32 code, address referrer);
}

/// @notice Rehearsal of the V4 rollout on live Base at the latest block (spec
///         docs/superpowers/specs/2026-10-08-perp-account-v4-design.md §7): the script's deployment, then the
///         founder's re-point of type 6 from the deployer. A new perp account in a fresh fund (the live
///         factory deploys ComptrollerV3 since 2026-10-08) is a V4 in list mode, linked to the protocol's
///         referral code, and the deployed PerpUnwinder recognizes it; TestFund4's existing V3 account is
///         unchanged by the re-point.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/PerpAccountV4RolloutFork.t.sol -vv
contract PerpAccountV4RolloutForkTest is Test {
	uint256 internal constant PERP_TYPE = 6;
	/// @dev Deployed 2026-10-07 (deployments/base-mainnet-redemption.json, committed on feat/redemption-queue)
	PerpUnwinder internal constant LIVE_UNWINDER = PerpUnwinder(0x34A20edead0f602532E1A042A7E4371743aA7675);
	/// @dev TestFund4 (founder's smoke-test fund, V3) and its V3 perp account, read 2026-10-08
	address internal constant TESTFUND4 = 0xd989D464E8bD518AF14151cb0F95a4f970F365DA;
	address internal constant TESTFUND4_PERP = 0xEb856Ea244683832FBE9332C3966ABA26C8Ec2d4;
	address internal constant REFERRAL = 0x1A110bBA13A1f16cCa4b79758BD39290f29De82D;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;

	bool internal forked;
	address internal deployer;
	address internal usdc;
	FundFactory internal factory;
	VerantaPerpPositionV2Factory internal config;
	VerantaPerpPositionV4Factory internal v4Factory;
	address internal previousType6;
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, 53_390_931); // pinned: live state moves under a fork at the latest block (2026-11-01)
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		config = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));
		usdc = address(config.usdc());
		previousType6 = factory.positionTypeFactories(PERP_TYPE);

		// rollout step 1: the script's deployment
		v4Factory = new DeployPerpAccountV4().deploy(config);
		// rollout step 2: the deployer (FundFactory owner until the governance handoff) re-points type 6
		assertEq(Ownable(address(factory)).owner(), deployer, 'the deployer still owns the factory');
		vm.prank(deployer);
		factory.registerPositionType(PERP_TYPE, address(v4Factory));
	}

	function test_fork_newAccountsAreV4_existingOnesUnchanged() public {
		vm.skip(!forked);
		assertTrue(previousType6 != address(0) && previousType6 != address(v4Factory), 'type 6 was the V3 factory');
		assertEq(factory.positionTypeFactories(PERP_TYPE), address(v4Factory));

		ComptrollerV3 fund = _fund();
		vm.prank(manager);
		address account = fund.createExternalPosition(PERP_TYPE, '');
		VerantaPerpPositionV4 v4 = VerantaPerpPositionV4(payable(account));
		assertEq(address(v4.positionFactory()), address(config), 'bound to the live config');
		assertEq(v4.heldPairs().length, 0, 'a V4 account, list mode, nothing held');
		assertEq(v4.activeDelegate(), address(0));
		assertTrue(LIVE_UNWINDER.canUnwind(account), 'the deployed redemption fallback recognizes it');
		(bytes32 code, address referrer) = IReferralReads(REFERRAL).getTraderReferralInfo(account);
		assertEq(code, config.referralCode(), 'linked to the protocol code at creation');
		assertEq(referrer, TREASURY, 'the rebate goes to the Treasury Safe');

		uint256 before = gasleft();
		(address[] memory assets,) = IExternalPosition(account).getManagedAssets();
		emit log_named_uint('getManagedAssets gas, empty V4 account', before - gasleft());
		assertEq(assets.length, 0);
		assertEq(fund.calcGav(), 10_000e6, 'an empty account adds nothing');
	}

	/// TestFund4's V3 account (the founder's live long/short/long book) reads the same legs before and
	/// after the re-point: only createExternalPosition reads the type table.
	function test_fork_testFund4V3AccountUnaffected() public {
		vm.skip(!forked);
		address[] memory positions = ComptrollerV3(TESTFUND4).getExternalPositions();
		assertEq(positions.length, 1);
		assertEq(positions[0], TESTFUND4_PERP);
		vm.prank(deployer);
		factory.registerPositionType(PERP_TYPE, previousType6);
		(address[] memory m0, uint256[] memory ma0) = IExternalPosition(TESTFUND4_PERP).getManagedAssets();
		vm.prank(deployer);
		factory.registerPositionType(PERP_TYPE, address(v4Factory));
		(address[] memory m1, uint256[] memory ma1) = IExternalPosition(TESTFUND4_PERP).getManagedAssets();
		assertEq(m0.length, m1.length);
		for (uint256 i; i < m0.length; ++i) {
			assertEq(m0[i], m1[i]);
			assertEq(ma0[i], ma1[i]);
		}
		(bool ok,) = TESTFUND4_PERP.staticcall(abi.encodeWithSignature('heldPairs()'));
		assertFalse(ok, 'still a V3 account (no heldPairs)');
	}

	function _fund() internal returns (ComptrollerV3 fund) {
		fund = ComptrollerV3(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'V4 rollout',
					symbol: 'frV4R',
					denominationAsset: IERC20(usdc),
					fundOwner: manager,
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: 0,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		deal(usdc, investor, 10_000e6);
		vm.startPrank(investor);
		IERC20(usdc).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}
}

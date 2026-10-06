// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {IExternalPosition} from '../../src/interfaces/IExternalPosition.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {
	IVerantaTradingRouter,
	IVerantaMulticall,
	IVerantaTradingStorage,
	IVerantaReferral
} from '../../src/interfaces/external/IVeranta.sol';
import {VerantaPerpPositionV2, VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV3, VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';

/// @notice The live Veranta Referral (proxy 0x1A11…E82D, impl 0xE0c6…053F, Referral.sol verified on
///         Blockscout, solc 0.8.13). Only what this test calls.
interface IReferralLive {
	function gov() external view returns (address);
	function paused() external view returns (bool);
	function pause() external;
	function unpause() external;
	function trading() external view returns (address);
	function registerCode(bytes32 code) external;
	function updateReferral(bytes32 code, bool isPrivate) external;
	function codes(address account) external view returns (bytes32);
	function codeOwners(bytes32 code) external view returns (address);
	function isPrivate(bytes32 code) external view returns (bool);
	function referrerTiers(address referrer) external view returns (uint256);
	function referralTiers(uint256 tierId) external view returns (uint256 feeDiscountPct, uint256 refRebatePct);
	function traderDiscounts(address trader) external view returns (uint256 fixedBps, uint256 pnlBps);
	function traderReferralCodes(address trader) external view returns (bytes32);
	function getTraderReferralInfo(address account) external view returns (bytes32 code, address referrer);
	/// @dev No access modifier in the verified source: computes discount + referrer + rebate, writes nothing (emits).
	function traderReferralDiscount(address account, uint256 fee, bool isPnl)
		external
		returns (uint256 traderFeesPostDiscount, address referrer, uint256 rebateShare);
}

/// @notice Live Veranta TradingStorage (impl 0x7175…6c64) rebate ledger + the trading-contract flag.
interface ITradingStorageLive {
	function rebates(address referrer) external view returns (uint256);
	function claimRebate() external;
	function referral() external view returns (address);
	function isTradingContract(address account) external view returns (bool);
}

/// @notice Live Veranta TradingRouter (impl 0x4a0d…fdadc) operator entry. Field order of the spread
///         struct per ITradingStorage.offChainSpreadParams (verified source).
interface IVerantaOperatorRouter {
	struct OffChainSpreadParams {
		int256 spreadP;
		uint256 bookDepth;
		int256 impactParam;
		bool byPass;
		int256 maxSpreadP;
		bool slot1;
		int256 slot3;
	}

	function isOperator(address account) external view returns (bool);
	function executeMarketOrder(
		uint256 orderId,
		bytes[] calldata priceUpdateData,
		uint8 priceSourcing,
		OffChainSpreadParams calldata spreadParams
	) external payable;
}

/// @notice VerantaPerpPositionV3 on a Base fork against the LIVE genesis and the LIVE Veranta contracts.
///         The founder's ops are pranked exactly as they will be sent:
///         1. the DAO Safe calls Referral.registerCode('frostydao');
///         2. the deployer calls V2Factory.setReferral(Referral, 'frostydao') (it still owns it; the
///            timelock is only pendingOwner);
///         3. the FundFactory owner calls registerPositionType(6, v3Factory) (`_repoint`).
///         Facts read with `cast` at block 52014634 (ts 1790818615), asserted again in `test_fork_liveFacts`:
///         - V2 factory 0x6B15…D8a9 (type 6): owner deployer 0xaE51…802a, pendingOwner timelock 0xd50A…83Ba,
///           referral() = the Referral, referralCode() = 'frostyfi' (owner 0xc761…0238, public).
///         - Referral: gov 0x3775…0288, not paused, trading() = the router, tier 1 = 500/500 bps;
///           codes(Safe) = 0; 'frostydao' unregistered.
///         - ALPHA = FundFactory.fundsList(0) 0x833A…dE9 (fundOwner = deployer); its only external
///           position is the V2 perp 0x33C7…844d (positionFactory = the V2 factory; unlinked; holds nothing).
///           The deployed V2 runtime equals this repo's VerantaPerpPositionV2 byte for byte (immutables masked).
///         The real fill: Veranta's operator does not run on a fork, so a market open stays pending. It is
///         filled here the way the operator does: an address with router.isOperator() = true at the pinned
///         block calls executeMarketOrder with a REAL Pyth Lazer packet copied from the calldata of Veranta's
///         own operator tx 0xd18f6433…ba60 (block 52014673): ETH (Lazer feed 2 = pairStorage.getLazerFeedId(0)),
///         $2,685.28631153, published 1790818690, Lazer signature verified on-chain by the aggregator.
///         MARKET_OPEN accepts a packet newer than block.timestamp − 60 s and has no upper bound, so the
///         fill warps to 2 s after publication. Spread params and the 1 wei Lazer fee are those of that tx.
///         Run: BASE_MAINNET_RPC=<url> BASE_FORK_BLOCK=52014634 forge test --match-path test/fork/VerantaPerpPositionV3Fork.t.sol -j 1 -vv
contract VerantaPerpPositionV3ForkTest is Test {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	uint256 internal constant PINNED_BLOCK = 52014634;

	address internal constant USDC = FundsMainnet.USDC;
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant ROUTER = FundsMainnet.VERANTA_ROUTER;
	address internal constant TRADING_STORAGE = FundsMainnet.VERANTA_STORAGE;
	address internal constant MULTICALL = FundsMainnet.VERANTA_MULTICALL;
	address internal constant REFERRAL = FundsMainnet.VERANTA_REFERRAL;
	uint256 internal constant PERP_TYPE = FundsMainnet.VERANTA_PERP_TYPE;
	uint256 internal constant ETH_PAIR = FundsMainnet.VERANTA_ETH_PAIR;
	/// @dev Veranta's own Chainlink backup feed for pair 0 (pairBackupFeed(0)), as test/VerantaPerpFork.t.sol uses
	address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

	/// @dev FrostyDAO Treasury Safe (v1.4.1, 2-of-3)
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant TIMELOCK = 0xd50AF6A924f23AC6944fB8eBc981E006B07D83Ba;
	address internal constant REFERRAL_IMPL = 0xE0c63b398D3AaE03F0b9E0512384FB14a967053F;
	address internal constant REFERRAL_GOV = 0x3775AF82c6C5705140944cD515fE899214Fb0288;
	address internal constant FROSTYFI_OWNER = 0xc7613E34b8635Ab1d6aCccae64B4b065fa690238;
	address internal constant ALPHA = 0x833A506d761A4756AF279ABC24183Db407823dE9;
	address internal constant ALPHA_PERP = 0x33C7EcA96Ec2037B9CB2b9946BF749BE588d844d;
	bytes32 internal constant FROSTYDAO = 'frostydao';
	bytes32 internal constant FROSTYFI = 'frostyfi';
	bytes32 internal constant STRANGER_CODE = 'strangercode';
	bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

	bytes32 internal constant SET_TRADER_REFERRAL_CODE = keccak256('SetTraderReferralCode(address,bytes32)');
	bytes32 internal constant TRADE_REFERRED =
		keccak256('TradeReferred(address,address,uint256,uint256,uint256,uint256,uint256)');
	/// @dev Errors.UsageRestricted() in the verified Referral source
	bytes4 internal constant USAGE_RESTRICTED = bytes4(keccak256('UsageRestricted()'));

	// ─── the real fill (Veranta operator tx 0xd18f64334a01b61ab4d8d7cdc0af75b190e7b2195083a7888db72ad101d6ba60) ───
	address internal constant VERANTA_OPERATOR = 0xe8f6E3281AAa99404003ecA9fb0653d751D4BC92; // that tx's sender
	bytes internal constant ETH_LAZER_PACKET =
		hex'2a22999a8d1af8074fe03346a450526acd9efd7255fdd0011ee5b81b35ee7e141394ff1d3ce318786081e862d3f15b5a6cb91e23d116612faecbcd50c0e406ae77f05fae01003293c7d37500065cbd77e90c4003010000000204000000003e858dbd7104fff805000000000924390f0c0100065cbd77e90c40';
	uint256 internal constant ETH_PACKET_TS = 1790818690;
	/// @dev the packet's price, 268528631153 × 1e-8, at Veranta's 1e10 price scale
	uint256 internal constant ETH_PACKET_PRICE = 26_852_863_115_300;
	uint8 internal constant PYTH_LAZER = 1;

	uint8 internal constant LINK_REFERRAL = 7;
	uint8 internal constant SET_AUTOPILOT = 4;

	struct Referred {
		uint256 count;
		address referrer;
		uint256 postDiscount;
		uint256 startingFees;
		uint256 rebate;
	}

	bool internal forked;
	FundFactory internal factory;
	address internal deployer;
	VerantaPerpPositionV2Factory internal v2Factory;
	VerantaPerpPositionV3Factory internal v3Factory;
	IReferralLive internal referral = IReferralLive(REFERRAL);

	// state before the founder ops, read in setUp
	bytes32 internal preSafeCode;
	address internal preDaoOwner;
	bytes32 internal preConfigCode;
	address internal preConfigReferral;
	address internal preType6;

	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		string memory genesis = vm.readFile(GENESIS_FILE);
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		v2Factory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory'));

		preSafeCode = referral.codes(TREASURY);
		preDaoOwner = referral.codeOwners(FROSTYDAO);
		preConfigCode = v2Factory.referralCode();
		preConfigReferral = address(v2Factory.referral());
		preType6 = factory.positionTypeFactories(PERP_TYPE);

		// Task 4 deploys it (stateless and ownerless: who deploys doesn't matter)
		vm.prank(deployer);
		v3Factory = new VerantaPerpPositionV3Factory(v2Factory);

		// founder op 1: the DAO Safe registers the code
		vm.prank(TREASURY);
		referral.registerCode(FROSTYDAO);
		// founder op 2: the deployer points the shared config at it
		vm.prank(deployer);
		v2Factory.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
	}

	// ─── the live facts ──────────────────────────────────────────────────────────

	function test_fork_liveFacts() public {
		vm.skip(!forked);
		assertEq(address(uint160(uint256(vm.load(REFERRAL, IMPL_SLOT)))), REFERRAL_IMPL, 'Referral impl');
		assertEq(referral.gov(), REFERRAL_GOV);
		assertFalse(referral.paused());
		assertEq(referral.trading(), ROUTER);
		(uint256 discount, uint256 rebate) = referral.referralTiers(1);
		assertEq(discount, 500, 'tier 1 trader discount');
		assertEq(rebate, 500, 'tier 1 referrer rebate');
		assertEq(ITradingStorageLive(TRADING_STORAGE).referral(), REFERRAL, 'TradingStorage uses this Referral');
		assertTrue(ITradingStorageLive(TRADING_STORAGE).isTradingContract(ROUTER));
		assertEq(referral.codeOwners(FROSTYFI), FROSTYFI_OWNER);
		assertFalse(referral.isPrivate(FROSTYFI));

		// before the founder ops
		assertEq(preSafeCode, bytes32(0), 'the Safe had no code');
		assertEq(preDaoOwner, address(0), 'frostydao was unregistered');
		assertEq(preConfigCode, FROSTYFI, 'config code was frostyfi');
		assertEq(preConfigReferral, REFERRAL);
		assertEq(preType6, address(v2Factory), 'type 6 = the V2 factory');
		assertEq(address(v2Factory), 0x6B15EC5B2D19f7D4625eEe0edaFfE357b599D8a9);
		assertEq(v2Factory.owner(), deployer);
		assertEq(v2Factory.pendingOwner(), TIMELOCK);
		assertEq(Ownable(address(factory)).owner(), deployer);

		// after them: the Safe owns frostydao at tier 1 and the config points at it
		assertEq(referral.codes(TREASURY), FROSTYDAO);
		assertEq(referral.codeOwners(FROSTYDAO), TREASURY);
		assertEq(referral.referrerTiers(TREASURY), 1);
		assertFalse(referral.isPrivate(FROSTYDAO));
		assertEq(v2Factory.referralCode(), FROSTYDAO);
		assertEq(address(v2Factory.referral()), REFERRAL);

		// ALPHA: one V2 perp, unlinked, empty
		assertEq(factory.fundsList(0), ALPHA);
		assertEq(Comptroller(ALPHA).fundOwner(), deployer);
		address[] memory positions = Comptroller(ALPHA).getExternalPositions();
		assertEq(positions.length, 1);
		assertEq(positions[0], ALPHA_PERP);
		assertEq(address(VerantaPerpPositionV2(ALPHA_PERP).positionFactory()), address(v2Factory));
		assertEq(referral.traderReferralCodes(ALPHA_PERP), bytes32(0), 'ALPHA perp is not linked');

		// the fill's operator and the packet's feed
		assertTrue(IVerantaOperatorRouter(ROUTER).isOperator(VERANTA_OPERATOR));
	}

	// ─── 1. linked at creation, and the rebate routes to the Safe ────────────────

	function test_fork_newAccountIsLinkedAtCreation() public {
		vm.skip(!forked);
		_repoint();
		Comptroller fund = _fund('V3 linked');

		vm.recordLogs();
		address position = _create(fund);
		Vm.Log[] memory logs = vm.getRecordedLogs();
		assertEq(address(VerantaPerpPositionV3(position).positionFactory()), address(v2Factory), 'a V3 on the config');
		(uint256 linked, uint256 failed, bytes32 code) = _linkEvents(logs, position);
		assertEq(linked, 1, 'ReferralLinked emitted');
		assertEq(failed, 0);
		assertEq(code, FROSTYDAO);
		assertTrue(_referralSetEvent(logs, position, FROSTYDAO), "the Referral's own SetTraderReferralCode");

		assertEq(referral.traderReferralCodes(position), FROSTYDAO);
		(bytes32 infoCode, address referrer) = referral.getTraderReferralInfo(position);
		assertEq(infoCode, FROSTYDAO);
		assertEq(referrer, TREASURY, 'the referrer is the DAO Safe');

		// the live fee computation Veranta's trading contract calls (no access modifier in the source)
		(uint256 fixedBps,) = referral.traderDiscounts(position);
		assertEq(fixedBps, 0, 'no trader-specific discount');
		uint256 fee = 6e6; // 0.06% of a $10,000 position
		(uint256 post, address ref, uint256 rebate) = referral.traderReferralDiscount(position, fee, false);
		assertEq(ref, TREASURY);
		assertEq(post, fee - fee * 500 / 10_000, 'tier 1: 5% off the fee');
		assertEq(rebate, post * 500 / 10_000, 'tier 1: 5% of the discounted fee to the Safe');
		assertEq(rebate, 285_000);

		// the counterfactual: an unlinked trader pays full fee and nobody gets a rebate
		(uint256 post0, address ref0, uint256 rebate0) = referral.traderReferralDiscount(stranger, fee, false);
		assertEq(ref0, address(0));
		assertEq(post0, fee);
		assertEq(rebate0, 0);
		emit log_named_address('V3 account', position);
		emit log_named_decimal_uint('fee                      ', fee, 6);
		emit log_named_decimal_uint('fee after the 5% discount', post, 6);
		emit log_named_decimal_uint('rebate to the Safe       ', rebate, 6);
	}

	/// A real Veranta fill (operator path, real signed Lazer price): the linked V3 account's open fee
	/// credits rebates[Safe], which the Safe claims in USDC; an unlinked V2 account filled at the same
	/// price credits nobody and gets no discount.
	function test_fork_realFillPaysTheRebateToTheSafe() public {
		vm.skip(!forked || block.number != PINNED_BLOCK);
		Comptroller fund = _fund('V3 fill');
		address v2 = _create(fund); // type 6 is still the V2 factory: the unlinked case (today's ALPHA)
		_repoint();
		address v3 = _create(fund);
		assertEq(referral.traderReferralCodes(v2), bytes32(0));
		assertEq(referral.traderReferralCodes(v3), FROSTYDAO);

		_openTrade(fund, v2, true, ETH_PACKET_PRICE, 1e10, 200e6);
		_openTrade(fund, v3, true, ETH_PACKET_PRICE, 1e10, 200e6);
		vm.roll(block.number + (ETH_PACKET_TS + 2 - block.timestamp) / 2);
		vm.warp(ETH_PACKET_TS + 2);

		uint256 safeRebates0 = ITradingStorageLive(TRADING_STORAGE).rebates(TREASURY);
		Referred memory r2 = _fill(v2);
		Referred memory r3 = _fill(v3);

		assertEq(r2.count, 1);
		assertEq(r2.referrer, address(0), 'unlinked: no referrer');
		assertEq(r2.postDiscount, r2.startingFees, 'unlinked: no discount');
		assertEq(r2.rebate, 0);

		assertEq(r3.count, 1);
		assertEq(r3.referrer, TREASURY, 'linked: the Safe');
		assertGt(r3.startingFees, 0);
		assertEq(r3.postDiscount, r3.startingFees - r3.startingFees * 500 / 10_000, 'linked: 5% discount');
		assertEq(r3.rebate, r3.postDiscount * 500 / 10_000, 'linked: 5% rebate');
		assertGt(r3.rebate, 0);
		uint256 safeRebates1 = ITradingStorageLive(TRADING_STORAGE).rebates(TREASURY);
		assertEq(safeRebates1 - safeRebates0, r3.rebate, 'rebates[Safe] grew by exactly the rebate');

		// the live computation agrees with what the fill booked
		(uint256 post, address ref, uint256 rebate) = referral.traderReferralDiscount(v3, r3.startingFees, false);
		assertEq(ref, TREASURY);
		assertEq(post, r3.postDiscount);
		assertEq(rebate, r3.rebate);

		// the Safe claims it in USDC
		uint256 usdc0 = IERC20(USDC).balanceOf(TREASURY);
		vm.prank(TREASURY);
		ITradingStorageLive(TRADING_STORAGE).claimRebate();
		assertEq(IERC20(USDC).balanceOf(TREASURY) - usdc0, safeRebates1, 'claimed in USDC');
		assertEq(ITradingStorageLive(TRADING_STORAGE).rebates(TREASURY), 0);

		// both fills are real stored trades, valued (a long: managed WETH)
		assertTrue(_has(v2, WETH), 'V2 values its filled long');
		assertTrue(_has(v3, WETH), 'V3 values its filled long');
		emit log_named_decimal_uint('V2 unlinked open fee     ', r2.startingFees, 6);
		emit log_named_decimal_uint('V3 linked open fee       ', r3.startingFees, 6);
		emit log_named_decimal_uint('V3 fee after discount    ', r3.postDiscount, 6);
		emit log_named_decimal_uint('rebate booked to the Safe', r3.rebate, 6);
	}

	// ─── 2. a paused or private Referral never blocks creation ───────────────────

	function test_fork_pausedReferralNeverBlocksCreation() public {
		vm.skip(!forked);
		_repoint();
		Comptroller fund = _fund('V3 paused');
		address gov = referral.gov();
		vm.prank(gov);
		referral.pause();

		vm.recordLogs();
		address position = _create(fund);
		(uint256 linked, uint256 failed, bytes32 code) = _linkEvents(vm.getRecordedLogs(), position);
		assertEq(linked, 0);
		assertEq(failed, 1, 'ReferralLinkFailed emitted');
		assertEq(code, FROSTYDAO);
		assertEq(referral.traderReferralCodes(position), bytes32(0), 'opened, unlinked');
		assertTrue(_isActive(fund, position));

		// while paused, the repair waits (the Referral's own guard)
		vm.prank(stranger);
		vm.expectRevert(bytes('Pausable: paused'));
		VerantaPerpPositionV3(position).linkReferral();

		vm.prank(gov);
		referral.unpause();
		vm.expectEmit(position);
		emit VerantaPerpPositionV3.ReferralLinked(FROSTYDAO);
		vm.prank(stranger);
		VerantaPerpPositionV3(position).linkReferral();
		(bytes32 infoCode, address referrer) = referral.getTraderReferralInfo(position);
		assertEq(infoCode, FROSTYDAO, 'repaired by a stranger');
		assertEq(referrer, TREASURY);
	}

	function test_fork_privateCodeNeverBlocksCreation() public {
		vm.skip(!forked);
		_repoint();
		Comptroller fund = _fund('V3 private');
		vm.prank(REFERRAL_GOV);
		referral.updateReferral(FROSTYDAO, true);

		vm.recordLogs();
		address position = _create(fund);
		(uint256 linked, uint256 failed,) = _linkEvents(vm.getRecordedLogs(), position);
		assertEq(linked, 0);
		assertEq(failed, 1);
		assertEq(referral.traderReferralCodes(position), bytes32(0));

		vm.prank(stranger);
		vm.expectRevert(USAGE_RESTRICTED);
		VerantaPerpPositionV3(position).linkReferral();

		vm.prank(REFERRAL_GOV);
		referral.updateReferral(FROSTYDAO, false);
		vm.prank(stranger);
		VerantaPerpPositionV3(position).linkReferral();
		assertEq(referral.traderReferralCodes(position), FROSTYDAO);
	}

	// ─── 3. unset config ─────────────────────────────────────────────────────────

	function test_fork_unsetConfigCreatesUnlinked() public {
		vm.skip(!forked);
		_repoint();
		Comptroller fund = _fund('V3 unset');

		address[3] memory refs = [address(0), REFERRAL, address(0)];
		bytes32[3] memory codes = [bytes32(0), bytes32(0), FROSTYDAO];
		address[3] memory created;
		for (uint256 i; i < 3; ++i) {
			vm.prank(deployer);
			v2Factory.setReferral(IVerantaReferral(refs[i]), codes[i]);
			vm.recordLogs();
			created[i] = _create(fund);
			(uint256 linked, uint256 failed,) = _linkEvents(vm.getRecordedLogs(), created[i]);
			assertEq(linked + failed, 0, 'no link attempted');
			assertEq(referral.traderReferralCodes(created[i]), bytes32(0), 'unlinked');

			vm.prank(stranger);
			vm.expectRevert(VerantaPerpPositionV3.ReferralNotConfigured.selector);
			VerantaPerpPositionV3(created[i]).linkReferral();
			vm.prank(manager);
			vm.expectRevert(VerantaPerpPositionV3.ReferralNotConfigured.selector);
			fund.callOnExternalPosition(created[i], new address[](0), new uint256[](0), new address[](0), _link());
		}

		// configured again: anyone repairs the accounts opened meanwhile
		vm.prank(deployer);
		v2Factory.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
		for (uint256 i; i < 3; ++i) {
			vm.prank(stranger);
			VerantaPerpPositionV3(created[i]).linkReferral();
			assertEq(referral.traderReferralCodes(created[i]), FROSTYDAO);
		}
	}

	// ─── 4. code change; nobody picks the code ───────────────────────────────────

	function test_fork_codeChangeRelinksOnlyToTheConfigCode() public {
		vm.skip(!forked);
		_repoint();
		Comptroller fund = _fund('V3 code change');
		address position = _create(fund);
		assertEq(referral.traderReferralCodes(position), FROSTYDAO);

		// a stranger holds a real code of their own
		vm.prank(stranger);
		referral.registerCode(STRANGER_CODE);
		assertEq(referral.codeOwners(STRANGER_CODE), stranger);

		// governance moves the config to another registered code; a stranger's call follows it
		vm.prank(deployer);
		v2Factory.setReferral(IVerantaReferral(REFERRAL), FROSTYFI);
		vm.expectEmit(position);
		emit VerantaPerpPositionV3.ReferralLinked(FROSTYFI);
		vm.prank(stranger);
		VerantaPerpPositionV3(position).linkReferral();
		(bytes32 infoCode, address referrer) = referral.getTraderReferralInfo(position);
		assertEq(infoCode, FROSTYFI, 'the old link is replaced');
		assertEq(referrer, FROSTYFI_OWNER);

		// no path takes a caller's code
		(bool ok,) = position.call(abi.encodeWithSignature('linkReferral(bytes32)', STRANGER_CODE));
		assertFalse(ok, 'no code parameter');
		vm.prank(stranger);
		vm.expectRevert(VerantaPerpPositionV3.OnlyComptroller.selector);
		VerantaPerpPositionV3(position).receiveCallFromFund(abi.encode(LINK_REFERRAL, abi.encode(STRANGER_CODE)));
		// the manager's action ignores any args: the config's code again
		vm.prank(deployer);
		v2Factory.setReferral(IVerantaReferral(REFERRAL), FROSTYDAO);
		vm.prank(manager);
		fund.callOnExternalPosition(
			position,
			new address[](0),
			new uint256[](0),
			new address[](0),
			abi.encode(LINK_REFERRAL, abi.encode(STRANGER_CODE))
		);
		assertEq(referral.traderReferralCodes(position), FROSTYDAO);
		assertTrue(referral.traderReferralCodes(position) != STRANGER_CODE);
	}

	// ─── 5. compatibility ────────────────────────────────────────────────────────

	function test_fork_compatibility() public {
		vm.skip(!forked);
		assertEq(address(v3Factory.config()), address(v2Factory));
		vm.expectRevert(VerantaPerpPositionV3Factory.ZeroAddress.selector);
		new VerantaPerpPositionV3Factory(VerantaPerpPositionV2Factory(address(0)));
		(bool hasOwner,) = address(v3Factory).staticcall(abi.encodeWithSignature('owner()'));
		assertFalse(hasOwner, 'ownerless');

		_repoint();
		Comptroller fund = _fund('V3 compat');
		VerantaPerpPositionV3 p = VerantaPerpPositionV3(_create(fund));
		assertEq(address(p.positionFactory()), address(v2Factory), 'positionFactory() = the live V2 factory');
		assertEq(p.comptroller(), address(fund));
		assertEq(address(p.usdc()), address(v2Factory.usdc()));
		assertEq(address(p.router()), address(v2Factory.router()));
		assertEq(address(p.verantaMulticall()), address(v2Factory.verantaMulticall()));
		assertEq(address(p.tradingStorage()), v2Factory.tradingStorage());
		assertEq(address(p.pairStorage()), address(v2Factory.pairStorage()));
		assertEq(IERC20(USDC).allowance(address(p), TRADING_STORAGE), type(uint256).max, 'TradingStorage can pull');

		// the terminal's ordinals
		assertEq(uint8(VerantaPerpPositionV3.Action.OpenTrade), uint8(VerantaPerpPositionV2.Action.OpenTrade));
		assertEq(uint8(VerantaPerpPositionV3.Action.CloseTrade), uint8(VerantaPerpPositionV2.Action.CloseTrade));
		assertEq(
			uint8(VerantaPerpPositionV3.Action.CancelLimitOrder), uint8(VerantaPerpPositionV2.Action.CancelLimitOrder)
		);
		assertEq(
			uint8(VerantaPerpPositionV3.Action.CancelPendingMarketOrder),
			uint8(VerantaPerpPositionV2.Action.CancelPendingMarketOrder)
		);
		assertEq(uint8(VerantaPerpPositionV3.Action.SetAutopilot), uint8(VerantaPerpPositionV2.Action.SetAutopilot));
		assertEq(
			uint8(VerantaPerpPositionV3.Action.RemoveAutopilot), uint8(VerantaPerpPositionV2.Action.RemoveAutopilot)
		);
		assertEq(uint8(VerantaPerpPositionV3.Action.ReturnToVault), uint8(VerantaPerpPositionV2.Action.ReturnToVault));
		assertEq(uint8(VerantaPerpPositionV3.Action.LinkReferral), uint8(VerantaPerpPositionV2.Action.LinkReferral));
		assertEq(uint8(VerantaPerpPositionV3.Action.LinkReferral), 7);
		// isRiskReducing against the DEPLOYED V2 (ALPHA's account)
		for (uint8 raw; raw <= 8; ++raw) {
			bytes memory data = abi.encode(raw, bytes(''));
			assertEq(p.isRiskReducing(data), VerantaPerpPositionV2(ALPHA_PERP).isRiskReducing(data));
		}
		vm.prank(address(fund));
		vm.expectRevert(VerantaPerpPositionV3.UnknownAction.selector);
		p.receiveCallFromFund(abi.encode(uint8(8), bytes('')));

		// an action that reads the config: autopilot delegates to the config's keeper
		vm.prank(manager);
		fund.callOnExternalPosition(
			address(p),
			new address[](0),
			new uint256[](0),
			new address[](0),
			abi.encode(SET_AUTOPILOT, abi.encode(block.timestamp + 30 days))
		);
		(bool enabled,) = IVerantaTradingRouter(ROUTER).multipleDelegations(address(p), v2Factory.autopilotKeeper());
		assertTrue(enabled);
		assertEq(p.activeDelegate(), v2Factory.autopilotKeeper());

		// the comptroller LinkReferral action still links (to the config's current code)
		vm.prank(deployer);
		v2Factory.setReferral(IVerantaReferral(REFERRAL), FROSTYFI);
		vm.expectEmit(address(p));
		emit VerantaPerpPositionV3.ReferralLinked(FROSTYFI);
		vm.prank(manager);
		fund.callOnExternalPosition(address(p), new address[](0), new uint256[](0), new address[](0), _link());
		assertEq(referral.traderReferralCodes(address(p)), FROSTYFI);
	}

	/// The same fund holds a V2 (opened before the re-point) and a V3: identical reports at each state.
	function test_fork_navParityWithV2() public {
		vm.skip(!forked);
		Comptroller fund = _fund('V3 NAV parity');
		address v2 = _create(fund);
		(bool isV3,) = v2.staticcall(abi.encodeWithSignature('linkReferral()'));
		assertFalse(isV3, 'a V2 account');
		_repoint();
		address v3 = _create(fund);
		assertEq(fund.calcGav(), 10_000e6);
		_assertSameNav(v2, v3, 'empty');

		// idle USDC (moved by the comptroller with a LinkReferral call)
		address[] memory usdcOnly = new address[](1);
		usdcOnly[0] = USDC;
		uint256[] memory amount = new uint256[](1);
		amount[0] = 100e6;
		vm.startPrank(manager);
		fund.callOnExternalPosition(v2, usdcOnly, amount, new address[](0), _link());
		fund.callOnExternalPosition(v3, usdcOnly, amount, new address[](0), _link());
		vm.stopPrank();
		_assertSameNav(v2, v3, 'idle USDC');

		// a pending open order at the same params (escrowed by the live TradingStorage)
		(, int256 ethPrice,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();
		uint256 ref = uint256(ethPrice) * 1e2;
		_openTrade(fund, v2, false, ref, 5e10, 200e6);
		_openTrade(fund, v3, false, ref, 5e10, 200e6);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(v2).length, 1);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(v3).length, 1);
		_assertSameNav(v2, v3, 'idle + pending open');
		assertEq(fund.calcGav(), 10_000e6, 'GAV whole');
	}

	// ─── 6. the re-point and the ALPHA op ────────────────────────────────────────

	/// After registerPositionType(6, v3Factory) ALPHA's V2 account still values and the fund owner's
	/// LinkReferral links it to frostydao: the rehearsal of the real op (logged for the founder).
	function test_fork_alphaV2AccountSurvivesRepointAndLinks() public {
		vm.skip(!forked);
		Comptroller alpha = Comptroller(ALPHA);
		(address[] memory m0, uint256[] memory a0) = IExternalPosition(ALPHA_PERP).getManagedAssets();
		(address[] memory d0,) = IExternalPosition(ALPHA_PERP).getDebtAssets();
		uint256 gav0 = alpha.calcGav();

		_repoint();
		assertEq(factory.positionTypeFactories(PERP_TYPE), address(v3Factory));
		(address[] memory m1, uint256[] memory a1) = IExternalPosition(ALPHA_PERP).getManagedAssets();
		(address[] memory d1,) = IExternalPosition(ALPHA_PERP).getDebtAssets();
		assertEq(m1.length, m0.length);
		assertEq(a1.length, a0.length);
		assertEq(d1.length, d0.length);
		assertEq(alpha.calcGav(), gav0, 'same GAV after the re-point');
		// it still values what it holds
		deal(USDC, ALPHA_PERP, 5e6);
		assertEq(alpha.calcGav(), gav0 + 5e6, 'idle USDC on the V2 account counts');

		// a V2 account has no linkReferral(): the fund owner's LinkReferral action is the only way
		(bool hasLink,) = ALPHA_PERP.call(abi.encodeWithSignature('linkReferral()'));
		assertFalse(hasLink);
		bytes memory actionData = _link();
		bytes memory callData = abi.encodeCall(
			Comptroller.callOnExternalPosition,
			(ALPHA_PERP, new address[](0), new uint256[](0), new address[](0), actionData)
		);
		vm.prank(alpha.fundOwner());
		(bool ok,) = ALPHA.call(callData);
		assertTrue(ok, 'the founder op');
		(bytes32 infoCode, address referrer) = referral.getTraderReferralInfo(ALPHA_PERP);
		assertEq(infoCode, FROSTYDAO);
		assertEq(referrer, TREASURY);
		assertEq(alpha.calcGav(), gav0 + 5e6);

		// ALPHA's next perp account is a V3, linked at creation (its type-6 policy allows it)
		vm.prank(alpha.fundOwner());
		address next = alpha.createExternalPosition(PERP_TYPE, '');
		assertEq(address(VerantaPerpPositionV3(next).positionFactory()), address(v2Factory));
		assertEq(referral.traderReferralCodes(next), FROSTYDAO);

		emit log_string('ALPHA LinkReferral (sent by the fund owner 0xaE51...802a to the ALPHA comptroller):');
		emit log_named_address('  to', ALPHA);
		emit log_string('  fn callOnExternalPosition(address,address[],uint256[],address[],bytes)');
		emit log_named_address('  position', ALPHA_PERP);
		emit log_named_bytes('  actionData', actionData);
		emit log_named_bytes('  calldata', callData);
	}

	// ─── 7. tight gas ────────────────────────────────────────────────────────────

	/// The link runs inside the constructor and the CREATE code deposit (200 gas per runtime byte)
	/// is charged after it. A link starved by EIP-150 leaves the constructor 1/64 of its gas, far
	/// below the deposit, so tight gas reverts the whole creation instead of opening an unlinked
	/// account. Proved here at the exact threshold and above it.
	function test_fork_tightGasCannotLeaveAnUnlinkedAccount() public {
		vm.skip(!forked);
		_repoint();
		Comptroller fund = _fund('V3 gas');
		uint256 snap = vm.snapshotState();
		(bool ok, address warm) = _tryCreate(fund, 30_000_000);
		assertTrue(ok);
		uint256 deposit = 200 * warm.code.length;
		vm.revertToState(snap);

		uint256 lo = 100_000;
		uint256 hi = 30_000_000;
		while (hi - lo > 1) {
			uint256 mid = (lo + hi) / 2;
			snap = vm.snapshotState();
			(ok,) = _tryCreate(fund, mid);
			vm.revertToState(snap);
			if (ok) hi = mid;
			else lo = mid;
		}

		snap = vm.snapshotState();
		(ok,) = _tryCreate(fund, hi - 1);
		assertFalse(ok, 'one gas less: the whole creation reverts');
		assertEq(fund.getExternalPositions().length, 0);
		vm.revertToState(snap);

		uint256 probes;
		for (uint256 g = hi; g < hi + 2_000_000; g += (g < hi + 64 ? 1 : 25_000)) {
			snap = vm.snapshotState();
			vm.recordLogs();
			address position;
			(ok, position) = _tryCreate(fund, g);
			if (ok) {
				(uint256 linked, uint256 failed,) = _linkEvents(vm.getRecordedLogs(), position);
				assertEq(failed, 0, 'never a failed link on a created account');
				assertEq(linked, 1);
				assertEq(referral.traderReferralCodes(position), FROSTYDAO, 'every created account is linked');
				++probes;
			}
			vm.revertToState(snap);
		}
		assertGt(probes, 100);

		// at the threshold itself; linkReferral() keeps it linked (the repair of a failed link is
		// proved by the paused, private and unset tests)
		(ok, warm) = _tryCreate(fund, hi);
		assertTrue(ok);
		assertEq(referral.traderReferralCodes(warm), FROSTYDAO);
		vm.prank(stranger);
		VerantaPerpPositionV3(warm).linkReferral();
		assertEq(referral.traderReferralCodes(warm), FROSTYDAO);
		emit log_named_uint('min gas for createExternalPosition', hi);
		emit log_named_uint('V3 runtime bytes', warm.code.length);
		emit log_named_uint('code deposit (gas)', deposit);
		emit log_named_uint('created accounts probed, all linked', probes);
	}

	// ─── 5. the autopilot keeper's margin top-up (perps review 2026-10-05) ─────────

	/// "Margin top-up is probably broken" (perps review 2026-10-05) — confirmed. The autopilot keeper
	/// deposits margin with delegatedAction → updateMargin, which Veranta fulfils at once against the
	/// price it is handed. On mainnet the keeper sent no payload with PYTH_CORE sourcing: Veranta's
	/// aggregator reverts StalePrice() (0x19abf40e), and an empty PYTH_LAZER payload reverts too. A
	/// signed Lazer packet (PYTH_LAZER, the verifier's 1 wei fee) deposits while it is under 30 s old:
	/// 29 s passes, 30 s reverts. funds-keeper now fetches one from Veranta's feed-v3
	/// /v2/pairs/{index}/price-update-data right before each top-up (the source Veranta's SDK uses).
	function test_fork_keeperMarginTopUpNeedsAFreshLazerPacket() public {
		vm.skip(!forked || block.number != PINNED_BLOCK);
		_repoint();
		Comptroller fund = _fund('V3 margin');
		address p = _create(fund);
		_openTrade(fund, p, true, ETH_PACKET_PRICE, 1e10, 200e6);
		vm.roll(block.number + (ETH_PACKET_TS + 2 - block.timestamp) / 2);
		vm.warp(ETH_PACKET_TS + 2);
		_fill(p);
		vm.prank(manager);
		fund.callOnExternalPosition(
			p, new address[](0), new uint256[](0), new address[](0), abi.encode(SET_AUTOPILOT, abi.encode(block.timestamp + 30 days))
		);
		address keeper = v2Factory.autopilotKeeper();
		// the account's idle USDC, which the top-up spends (the manager sends it there)
		deal(USDC, p, 50e6);
		uint256 collateral0 = _collateral(p);
		bytes[] memory lazer = new bytes[](1);
		lazer[0] = ETH_LAZER_PACKET;

		// what the keeper sent until now: no payload, PYTH_CORE
		uint256 snap = vm.snapshotState();
		(bool ok,) = _topUp(keeper, p, new bytes[](0), 0, 0);
		assertFalse(ok, 'no payload + PYTH_CORE: reverts');
		vm.prank(p); // the cause, undisguised by delegatedAction's bare revert
		vm.expectRevert(bytes4(0x19abf40e)); // StalePrice()
		IVerantaTradingRouter(ROUTER).updateMargin(ETH_PAIR, 0, 0, 50e6, new bytes[](0), 0);
		(ok,) = _topUp(keeper, p, new bytes[](0), PYTH_LAZER, 0);
		assertFalse(ok, 'no payload + PYTH_LAZER: reverts');
		assertEq(_collateral(p), collateral0);
		vm.revertToState(snap);

		// a signed Lazer packet 29 s old deposits the 50 USDC, all of it from the account
		snap = vm.snapshotState();
		vm.warp(ETH_PACKET_TS + 29);
		(ok,) = _topUp(keeper, p, lazer, PYTH_LAZER, 1);
		assertTrue(ok, 'fresh Lazer packet: deposits');
		assertEq(_collateral(p), collateral0 + 50e6, 'collateral +50 USDC');
		assertEq(IERC20(USDC).balanceOf(p), 0, 'paid from the account, nothing from the keeper');
		vm.revertToState(snap);

		// 30 s old: refused, so the keeper must fetch the packet right before sending
		vm.warp(ETH_PACKET_TS + 30);
		(ok,) = _topUp(keeper, p, lazer, PYTH_LAZER, 1);
		assertFalse(ok, '30 s old: reverts');
		assertEq(_collateral(p), collateral0);
		emit log_named_decimal_uint('collateral before top-up', collateral0, 6);
	}

	// ─── 6. account value vs a real close (perps review 2026-10-05) ─────────────────

	/// "Close costs aren't in NAV" (perps review 2026-10-05), measured. Valuation counts a trade as
	/// collateral + P&L − rollover − funding; a real close also pays the close fee and the close
	/// spread. A 5× ETH long of 199.57 USDC collateral (≈ $998 notional), valued at the close's own
	/// price, reads 199.472724 USDC; Veranta's operator closes it at that price and pays 199.278151.
	/// NAV is high by 0.194573 USDC: 1.95 bps of notional, ≈ 0.1% of the collateral. A floor, not a
	/// ceiling: the close here uses the spread of Veranta's real open tx, and real closes take the
	/// operator's dynamic spread (a "profit share" and the max-gain cap, which this flat trade doesn't
	/// touch, add more on winning trades).
	function test_fork_navIsAboveTheRealClosePayoutByTheCloseCosts() public {
		vm.skip(!forked || block.number != PINNED_BLOCK);
		_repoint();
		Comptroller fund = _fund('V3 close');
		address p = _create(fund);
		_openTrade(fund, p, true, ETH_PACKET_PRICE, 1e10, 200e6);
		vm.roll(block.number + (ETH_PACKET_TS + 2 - block.timestamp) / 2);
		vm.warp(ETH_PACKET_TS + 2);
		_fill(p);
		uint256 collateral = _collateral(p);
		int256 value = _valueAt(p, ETH_PACKET_PRICE);
		(bool ok, uint256 payout) = _closeAll(fund, p, collateral);
		assertTrue(ok, 'the operator executed the close');
		assertEq(IVerantaTradingStorage(TRADING_STORAGE).openTradesCount(p, ETH_PAIR), 0, 'fully closed');

		int256 gap = value - int256(payout);
		assertEq(value, 199_472_724, 'NAV at the close price');
		assertEq(payout, 199_278_151, 'what the close paid');
		assertEq(gap, 194_573, 'NAV is high by the close costs');
		// small: under 2 bps of the ≈ $998 notional
		uint256 notional = collateral * 5;
		assertLt(uint256(gap) * 10_000, notional * 2);
		emit log_named_decimal_int('NAV at the close price', value, 6);
		emit log_named_decimal_uint('close payout', payout, 6);
		emit log_named_decimal_int('NAV above payout', gap, 6);
	}

	// ─── helpers ─────────────────────────────────────────────────────────────────

	/// @dev The account as NAV counts it, with its WETH leg at `price` (1e10) instead of the VI's.
	function _valueAt(address position, uint256 price) internal returns (int256 value) {
		(address[] memory m, uint256[] memory ma) = IExternalPosition(position).getManagedAssets();
		(address[] memory d, uint256[] memory da) = IExternalPosition(position).getDebtAssets();
		for (uint256 i; i < m.length; ++i) {
			if (m[i] == USDC) value += int256(ma[i]);
			else if (m[i] == WETH) value += int256(ma[i] * price / 1e10 / 1e12);
		}
		for (uint256 i; i < d.length; ++i) {
			if (d[i] == USDC) value -= int256(da[i]);
		}
	}

	/// @dev Close the account's ETH trade through the fund, then fill the close as Veranta's operator
	///      does, at the real packet. Returns the USDC the close paid the account.
	function _closeAll(Comptroller fund, address position, uint256 collateral) internal returns (bool ok, uint256 payout) {
		uint256 usdc0 = IERC20(USDC).balanceOf(position);
		bytes memory close = abi.encode(
			uint8(VerantaPerpPositionV3.Action.CloseTrade), abi.encode(ETH_PAIR, uint256(0), collateral, ETH_PACKET_PRICE)
		);
		vm.prank(manager);
		fund.callOnExternalPosition(position, new address[](0), new uint256[](0), new address[](0), close);
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(position);
		if (pending.length == 0) return (false, 0);
		bytes[] memory update = new bytes[](1);
		update[0] = ETH_LAZER_PACKET;
		IVerantaOperatorRouter.OffChainSpreadParams memory spread = IVerantaOperatorRouter.OffChainSpreadParams({
			spreadP: 1e8, bookDepth: 0, impactParam: 0, byPass: true, maxSpreadP: 0, slot1: false, slot3: 0
		});
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.prank(VERANTA_OPERATOR);
		bytes memory ret;
		(ok, ret) = ROUTER.call{value: 1}(
			abi.encodeCall(IVerantaOperatorRouter.executeMarketOrder, (pending[0].orderId, update, PYTH_LAZER, spread))
		);
		if (!ok) emit log_named_bytes('close revert', ret);
		payout = IERC20(USDC).balanceOf(position) - usdc0;
	}

	/// @dev The autopilot keeper's margin DEPOSIT of 50 USDC into the account's first ETH trade, sent
	///      the way funds-keeper src/veranta/hedge.ts executeTopUp sends it.
	function _topUp(address keeper, address position, bytes[] memory update, uint8 sourcing, uint256 fee)
		internal
		returns (bool ok, bytes memory ret)
	{
		bytes memory inner = abi.encodeCall(IVerantaTradingRouter.updateMargin, (ETH_PAIR, 0, 0, 50e6, update, sourcing));
		vm.deal(keeper, 1 ether);
		vm.prank(keeper);
		(ok, ret) = ROUTER.call{value: fee}(abi.encodeWithSignature('delegatedAction(address,bytes)', position, inner));
	}

	function _collateral(address position) internal view returns (uint256) {
		return IVerantaTradingStorage(TRADING_STORAGE).openTrades(position, ETH_PAIR, 0).initialPosToken;
	}

	/// @dev Founder op 3 (Task 4): type 6 now deploys V3 accounts.
	function _repoint() internal {
		vm.prank(Ownable(address(factory)).owner());
		factory.registerPositionType(PERP_TYPE, address(v3Factory));
	}

	/// @dev A fresh non-degen USDC fund on the live factory with 10,000 USDC deposited.
	function _fund(string memory name) internal returns (Comptroller fund) {
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: name,
					symbol: 'frVP3',
					denominationAsset: IERC20(USDC),
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
		deal(USDC, investor, 10_000e6);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 30);
		fund.executeDepositRequest(investor);
	}

	function _create(Comptroller fund) internal returns (address position) {
		vm.prank(manager);
		position = fund.createExternalPosition(PERP_TYPE, '');
	}

	function _tryCreate(Comptroller fund, uint256 gasLimit) internal returns (bool ok, address position) {
		vm.prank(manager);
		try fund.createExternalPosition{gas: gasLimit}(PERP_TYPE, '') returns (address p) {
			return (true, p);
		} catch {
			return (false, address(0));
		}
	}

	function _link() internal pure returns (bytes memory) {
		return abi.encode(LINK_REFERRAL, bytes(''));
	}

	function _isActive(Comptroller fund, address position) internal view returns (bool) {
		address[] memory positions = fund.getExternalPositions();
		for (uint256 i; i < positions.length; ++i) {
			if (positions[i] == position) return true;
		}
		return false;
	}

	/// @dev OpenTrade on pair 0 (ETH/USD), market, 5x, collateral sent from the vault.
	function _openTrade(Comptroller fund, address position, bool buy, uint256 price, uint256 slippage, uint256 collateral)
		internal
	{
		address[] memory assets = new address[](1);
		assets[0] = USDC;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = collateral;
		bytes memory open = abi.encode(
			uint8(VerantaPerpPositionV3.Action.OpenTrade),
			abi.encode(ETH_PAIR, collateral, uint256(5e10), buy, price, slippage, uint8(0), uint256(0), uint256(0))
		);
		vm.prank(manager);
		fund.callOnExternalPosition(position, assets, amounts, new address[](0), open);
	}

	/// @dev Fill the account's one pending market open the way Veranta's operator does.
	function _fill(address position) internal returns (Referred memory r) {
		IVerantaMulticall.PendingOrder[] memory pending = IVerantaMulticall(MULTICALL).getPendingOrder(position);
		assertEq(pending.length, 1);
		uint256 orderId = pending[0].orderId;
		bytes[] memory update = new bytes[](1);
		update[0] = ETH_LAZER_PACKET;
		IVerantaOperatorRouter.OffChainSpreadParams memory spread = IVerantaOperatorRouter.OffChainSpreadParams({
			spreadP: 1e8,
			bookDepth: 0,
			impactParam: 0,
			byPass: true,
			maxSpreadP: 0,
			slot1: false,
			slot3: 0
		});
		vm.deal(VERANTA_OPERATOR, 1 ether);
		vm.recordLogs();
		vm.prank(VERANTA_OPERATOR);
		IVerantaOperatorRouter(ROUTER).executeMarketOrder{value: 1}(orderId, update, PYTH_LAZER, spread);
		r = _referred(vm.getRecordedLogs(), position);
		assertEq(IVerantaMulticall(MULTICALL).getPendingOrder(position).length, 0, 'filled');
		assertEq(IVerantaTradingStorage(TRADING_STORAGE).openTradesCount(position, ETH_PAIR), 1, 'a stored trade');
	}

	function _referred(Vm.Log[] memory logs, address trader) internal pure returns (Referred memory r) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter != TRADING_STORAGE || logs[i].topics[0] != TRADE_REFERRED) continue;
			(address t, address referrer,, uint256 post, uint256 starting, uint256 rebate,) =
				abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256, uint256));
			if (t != trader) continue;
			++r.count;
			r.referrer = referrer;
			r.postDiscount = post;
			r.startingFees = starting;
			r.rebate = rebate;
		}
	}

	function _linkEvents(Vm.Log[] memory logs, address position)
		internal
		pure
		returns (uint256 linked, uint256 failed, bytes32 code)
	{
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter != position) continue;
			if (logs[i].topics[0] == VerantaPerpPositionV3.ReferralLinked.selector) {
				++linked;
				code = logs[i].topics[1];
			} else if (logs[i].topics[0] == VerantaPerpPositionV3.ReferralLinkFailed.selector) {
				++failed;
				code = logs[i].topics[1];
			}
		}
	}

	function _referralSetEvent(Vm.Log[] memory logs, address account, bytes32 code) internal pure returns (bool) {
		for (uint256 i; i < logs.length; ++i) {
			if (
				logs[i].emitter == REFERRAL && logs[i].topics[0] == SET_TRADER_REFERRAL_CODE
					&& keccak256(logs[i].data) == keccak256(abi.encode(account, code))
			) return true;
		}
		return false;
	}

	function _has(address position, address asset) internal returns (bool) {
		(address[] memory assets,) = IExternalPosition(position).getManagedAssets();
		for (uint256 i; i < assets.length; ++i) {
			if (assets[i] == asset) return true;
		}
		return false;
	}

	function _assertSameNav(address v2, address v3, string memory step) internal {
		(address[] memory m2, uint256[] memory ma2) = IExternalPosition(v2).getManagedAssets();
		(address[] memory m3, uint256[] memory ma3) = IExternalPosition(v3).getManagedAssets();
		(address[] memory d2, uint256[] memory da2) = IExternalPosition(v2).getDebtAssets();
		(address[] memory d3, uint256[] memory da3) = IExternalPosition(v3).getDebtAssets();
		assertEq(m2, m3, string.concat('managed assets: ', step));
		assertEq(ma2, ma3, string.concat('managed amounts: ', step));
		assertEq(d2, d3, string.concat('debt assets: ', step));
		assertEq(da2, da3, string.concat('debt amounts: ', step));
		emit log_named_string('NAV step', step);
		for (uint256 i; i < m3.length; ++i) {
			emit log_named_address('  managed asset (V2 = V3)', m3[i]);
			emit log_named_uint('  managed amount (V2 = V3)', ma3[i]);
		}
	}
}

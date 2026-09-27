// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {SlipstreamLPPosition} from '../../src/positions/SlipstreamLPPosition.sol';
import {MockERC20} from '../utils/Mocks.sol';
import {VerantaFundingFixture as Fx} from '../utils/VerantaFundingFixture.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';

/// @dev The ADVERSARY, not a stand-in for a dependency: a "gauge" a manager points a position
///      at, which keeps whatever NFT it is handed on deposit.
contract StealingGauge {
	IERC721 internal immutable nft;
	address internal immutable thief;

	constructor(IERC721 nft_, address thief_) {
		nft = nft_;
		thief = thief_;
	}

	function deposit(uint256 tokenId) external {
		nft.transferFrom(msg.sender, thief, tokenId);
	}

	function withdraw(uint256) external {}

	function getReward(uint256) external {}

	function earned(address, uint256) external pure returns (uint256) {
		return 0;
	}

	function rewardToken() external pure returns (address) {
		return address(0);
	}
}

/// @notice Aerodrome gauge staking on the genesis deployment against REAL Base: the newer
///         Slipstream deployment's NFT manager, the WETH/USDC (tick spacing 50) pool and its
///         real CLGauge. A position may only ever stake into its own pool's gauge.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/fork/SlipstreamGaugeFork.t.sol -vv
contract SlipstreamGaugeForkTest is Test {
	address internal constant SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	address internal constant POOL = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A; // WETH/USDC ts50, CL2
	address internal constant REAL_GAUGE = 0xA0B61fdB9f1FB9b917Fe38b49427Fd4D87472D28;
	int24 internal constant SPACING = 50;
	int24 internal constant FULL = 887_250; // max tick rounded to the spacing

	bool internal forked;
	address internal manager = makeAddr('manager');
	address internal alice = makeAddr('alice');
	address internal thief = makeAddr('thief');
	FundsMainnet.Deployed internal d;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, Fx.BLOCK);
		forked = true;
		address deployer = makeAddr('deployer');
		MockERC20 frostStandIn = new MockERC20('FROST stand-in', 'FROST', 18);
		vm.startPrank(deployer);
		d = FundsMainnet.deploy(
			FundsMainnet.Config({deployer: deployer, safe: SAFE, frost: address(frostStandIn), autopilotKeeper: makeAddr('keeper'), protocolFeeBps: 25})
		);
		vm.stopPrank();
	}

	function _fundWithWethAndUsdc() internal returns (Comptroller fund) {
		fund = Comptroller(
			d.factory.createFund(
				FundFactory.FundConfig({
					name: 'Gauge Fund',
					symbol: 'frGG',
					denominationAsset: IERC20(FundsMainnet.USDC),
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
		deal(FundsMainnet.USDC, alice, 10_000e6);
		vm.startPrank(alice);
		IERC20(FundsMainnet.USDC).approve(address(fund), 10_000e6);
		fund.requestDeposit(10_000e6);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(alice);
		vm.prank(manager);
		fund.callOnIntegration(
			d.slipstream2Adapter, abi.encode(FundsMainnet.USDC, FundsMainnet.WETH, SPACING, uint256(3_000e6), uint256(0))
		);
	}

	/// WETH (0x42…) sorts before USDC (0x83…): token0 = WETH
	function _position(Comptroller fund, address gauge) internal returns (SlipstreamLPPosition position) {
		vm.prank(manager);
		position = SlipstreamLPPosition(
			fund.createExternalPosition(
				FundsMainnet.SLIPSTREAM2_LP_TYPE, abi.encode(FundsMainnet.WETH, FundsMainnet.USDC, SPACING, gauge)
			)
		);
	}

	function _mintAndStake(Comptroller fund, SlipstreamLPPosition position) internal {
		address[] memory assets = new address[](2);
		assets[0] = FundsMainnet.WETH;
		assets[1] = FundsMainnet.USDC;
		uint256[] memory amounts = new uint256[](2);
		amounts[0] = IERC20(FundsMainnet.WETH).balanceOf(address(fund.vault()));
		amounts[1] = 3_000e6;
		vm.startPrank(manager);
		fund.callOnExternalPosition(
			address(position), assets, amounts, new address[](0),
			abi.encode(uint8(SlipstreamLPPosition.Action.Mint), abi.encode(-FULL, FULL, amounts[0], amounts[1], uint256(0), uint256(0)))
		);
		fund.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(SlipstreamLPPosition.Action.Stake), bytes(''))
		);
		vm.stopPrank();
	}

	/// Regression: pre-fix this test's body (create with a fake gauge → mint → Stake) ended with
	/// the thief owning the fund's LP NFT (fork-proven 2026-09-27). Now creation itself refuses.
	function test_fork_aFakeGaugeIsRefusedAtCreation() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithWethAndUsdc();
		StealingGauge fake = new StealingGauge(IERC721(FundsMainnet.CL2_NPM), thief);
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSignature('GaugeNotPoolGauge(address,address)', address(fake), POOL));
		fund.createExternalPosition(
			FundsMainnet.SLIPSTREAM2_LP_TYPE, abi.encode(FundsMainnet.WETH, FundsMainnet.USDC, SPACING, address(fake))
		);
	}

	/// The pool's own gauge: stake, AERO accrues, claim lands AERO in the vault and GAV
	function test_fork_theRealGaugeStakes_andAeroReachesTheVault() public {
		vm.skip(!forked);
		Comptroller fund = _fundWithWethAndUsdc();
		SlipstreamLPPosition position = _position(fund, REAL_GAUGE);
		_mintAndStake(fund, position);
		assertEq(IERC721(FundsMainnet.CL2_NPM).ownerOf(position.tokenId()), REAL_GAUGE, 'staked in the pool gauge');
		assertTrue(position.staked());

		uint256 gavStaked = fund.calcGav();
		skip(40 minutes); // stays inside WETH's 1h Chainlink heartbeat (the round is already ~14 min old at this block; a fork never gets new rounds)
		address[] memory receive_ = new address[](1);
		receive_[0] = FundsMainnet.AERO; // the fund tracks what it is told it receives
		vm.prank(manager);
		fund.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), receive_,
			abi.encode(uint8(SlipstreamLPPosition.Action.ClaimRewards), bytes(''))
		);
		uint256 aero = IERC20(FundsMainnet.AERO).balanceOf(address(fund.vault()));
		assertGt(aero, 0, 'AERO emissions claimed to the vault');
		assertGt(fund.calcGav(), gavStaked, 'the claimed AERO counts in GAV');

		vm.prank(manager);
		fund.callOnExternalPosition(
			address(position), new address[](0), new uint256[](0), new address[](0),
			abi.encode(uint8(SlipstreamLPPosition.Action.Unstake), bytes(''))
		);
		assertEq(IERC721(FundsMainnet.CL2_NPM).ownerOf(position.tokenId()), address(position), 'unstaked back to the position');
	}
}

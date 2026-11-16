// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../../src/core/ComptrollerBlueprintDeployer.sol';
import {RedemptionQueue} from '../../../src/redemption/RedemptionQueue.sol';
import {RedemptionQueueShortDeadline} from '../../utils/RedemptionQueueShortDeadline.sol';
import {Comptroller} from '../../../src/core/Comptroller.sol';
import {IValueInterpreter} from '../../../src/interfaces/IValueInterpreter.sol';
import {IValueInterpreterAdmin} from '../../../src/interfaces/IValueInterpreterAdmin.sol';
import {IVerantaPerpConfig} from '../../../src/interfaces/IVerantaPerpConfig.sol';
import {VerantaPriceAdapter} from '../../../src/pricing/VerantaPriceAdapter.sol';
import {Release} from '../../../script/release/Release.sol';
import {BaseMainnet} from '../../../script/release/BaseMainnet.sol';
import {ForkTokens} from './ForkTokens.sol';

/// @notice The clean release deployed on a Base fork, for every fork suite: Release.deploy exactly as the broadcast runs
///         it, with this test as the deployer, then the VI handed to the registrar. Suites skip without BASE_MAINNET_RPC.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path 'test/fork/*' -vv
abstract contract ReleaseFork is Test, ForkTokens {
	/// @dev Base after the Aero merger, the Veranta stock prices and the live CLM v2 vaults (2026-11-15).
	uint256 internal constant FORK_BLOCK = 57_944_000;
	/// @dev Today's ValueInterpreter (deployments/base-mainnet.json), read at the fork block for what it lists.
	IValueInterpreter internal constant LIVE_VI = IValueInterpreter(0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4);
	/// @dev Today's perp config (the genesis VerantaPerpPositionV2Factory, deployments/base-mainnet.json verantaFactory).
	IVerantaPerpConfig internal constant LIVE_PERP_CONFIG = IVerantaPerpConfig(0x6B15EC5B2D19f7D4625eEe0edaFfE357b599D8a9);
	/// @dev Today's Veranta price store (deployments/base-mainnet-perp-prices-v2.json store): the release's store's code.
	address internal constant LIVE_VERANTA_STORE = 0xf9Ef795F17eC1007d859dDbdBe8C6bccE8554AA7;

	bool internal forked;
	Release.Deployed internal r;
	address internal keeper = makeAddr('keeper');
	address internal manager = makeAddr('manager');
	address internal investor = makeAddr('investor');
	uint256 private fundNonce;

	function setUp() public virtual {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, _forkBlock());
		forked = true;
		r = Release.deploy(
			Release.Config({owner: address(this), treasury: BaseMainnet.TREASURY, guardian: BaseMainnet.ADMIN_SAFE, keeper: keeper})
		);
		_handOver();
	}

	/// @dev The registrar takes the VI, so a suite lists what it needs through it. The listings suite leaves the VI with
	///      the deployer, as DeployRelease does: ReleaseListings hands it over itself, once the feeds are on it.
	function _handOver() internal virtual {
		Release.handOverValueInterpreter(r);
	}

	/// @dev Lists `asset` on the release's VI with the feed and heartbeat today's VI prices it from at the fork block.
	function _copyFeed(address asset) internal {
		(address aggregator, uint32 heartbeat,,) = LIVE_VI.getAssetInfo(asset);
		require(aggregator != address(0), 'not a primitive on the live VI');
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (asset, aggregator, heartbeat)));
	}

	/// @dev Maps a Veranta pair on the release's perp config to the asset today's perp config maps it to at the fork block.
	function _copyPairAsset(uint256 pairIndex) internal returns (address asset) {
		asset = LIVE_PERP_CONFIG.pairAsset(pairIndex);
		require(asset != address(0), 'not mapped on the live perp config');
		r.perpConfig.setPairAsset(pairIndex, asset);
	}

	/// @dev Puts the price today's Veranta store holds for `pairIndex` at the fork block into the release's store: the same
	///      contract code, so the same word in slot 0's mapping (price, exponent, confirmed and last-trade times).
	function _copyStoredPrice(uint256 pairIndex) internal {
		bytes32 slot = keccak256(abi.encode(pairIndex, uint256(0)));
		bytes32 word = vm.load(LIVE_VERANTA_STORE, slot);
		require(word != bytes32(0), 'the live store holds no price for the pair');
		vm.store(address(r.verantaStore), slot, word);
	}

	/// @dev Lists the marker of a Veranta pair on a market that closes, priced from the release's store as the live VI
	///      lists those (VerantaPriceAdapter, a 5-day heartbeat).
	function _listClosingMarketPair(uint256 pairIndex) internal returns (address marker) {
		marker = _copyPairAsset(pairIndex);
		VerantaPriceAdapter feed = new VerantaPriceAdapter(
			r.verantaStore, pairIndex, BaseMainnet.VERANTA_MAX_PUSH_AGE, BaseMainnet.VERANTA_MAX_FEED_AGE, 'pair / USD'
		);
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (marker, address(feed), BaseMainnet.VERANTA_MAX_FEED_AGE)));
	}

	/// @dev Lists `asset` on the release's VI as a derivative priced by `feed`.
	function _listDerivative(address asset, address feed) internal {
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.addDerivative, (asset, feed)));
	}

	/// @dev New funds onto a queue with a 1-second deadline, so a liquidation runs within the seconds a real price stays
	///      usable (production keeps 4 days).
	function _shortDeadlineQueue() internal returns (RedemptionQueue queue) {
		queue = new RedemptionQueueShortDeadline(address(this));
		queue.setFactory(address(r.factory));
		queue.setKeeper(keeper, true);
		r.factory.setComptrollerDeployer(
			new ComptrollerBlueprintDeployer(type(Comptroller).creationCode, abi.encode(r.registrar, queue, r.perpConfig))
		);
	}

	/// @dev The investor asks `queue` for half their shares, and the 1-second deadline passes.
	function _overdueRedemption(Comptroller fund, RedemptionQueue queue) internal {
		uint256 shares = fund.shares().balanceOf(investor) / 2;
		vm.startPrank(investor);
		IERC20(address(fund.shares())).approve(address(queue), shares);
		queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
		vm.warp(block.timestamp + 2);
		vm.roll(block.number + 10);
		assertTrue(queue.isOverdue(address(fund)));
	}

	/// @dev The block a suite forks at; a suite pinned to an event overrides it.
	function _forkBlock() internal view virtual returns (uint256) {
		return vm.envOr('BASE_FORK_BLOCK', FORK_BLOCK);
	}

	/// @dev A USDC fund with no fees or lock, and `amount` of an investor's USDC deposited and executed.
	function _fundWithDeposit(uint256 amount) internal returns (Comptroller fund) {
		fund = Comptroller(
			r.factory.createFund(
				FundFactory.FundConfig({
					name: string.concat('Release fork fund ', vm.toString(++fundNonce)),
					symbol: 'frREL',
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
		deal(USDC, investor, amount);
		vm.startPrank(investor);
		IERC20(USDC).approve(address(fund), amount);
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		vm.warp(block.timestamp + 1 minutes);
		vm.roll(block.number + 300);
		fund.executeDepositRequest(investor);
	}
}

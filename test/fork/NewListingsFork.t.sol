// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ListNewAssets} from '../../script/listings/ListNewAssets.s.sol';
import {NewListings} from '../../script/listings/NewListings.sol';
import {Release} from '../../script/release/Release.sol';
import {B20LocalStandIns} from '../../script/release/B20LocalStandIn.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IVerantaPriceStore} from '../../src/interfaces/IVerantaPriceStore.sol';
import {IB20Multiplier} from '../../src/interfaces/external/IB20Multiplier.sol';
import {B20VerantaPriceAdapter} from '../../src/pricing/B20VerantaPriceAdapter.sol';
import {VerantaPriceAdapter} from '../../src/pricing/VerantaPriceAdapter.sol';

/// @notice The 2026-11-19 listings (deployments/listings-2026-11-19.json) on the live release, at a block before they
///         were sent: ListNewAssets' own steps run as the registrar's owner, then every asset must price the way its
///         kind does on the release. Coinbase stock tokens are stand-ins holding the real decimals and multiplier.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/NewListingsFork.t.sol -vv
contract NewListingsForkTest is Test, ListNewAssets {
	uint256 internal constant FORK_BLOCK = 59_619_800;
	string internal constant LIST_PATH = 'deployments/listings-2026-11-19.json';
	/// @dev The registrar's and the perp config's owner.
	address internal constant DEPLOYER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a;
	/// @dev TTWOc's Aero pool against USDC (tick spacing 10), which passes the registrar's $25k check at the fork block.
	address internal constant TTWOC_POOL = 0x18907cAE5a9c7b45F85c5d2e1F7508C27c134f83;
	uint256 internal constant ANT_PAIR = 222;

	bool internal forked;
	Release.Deployed internal d;
	string internal list;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', FORK_BLOCK));
		forked = true;
		d = _read(vm.readFile(RELEASE_PATH));
		list = vm.readFile(LIST_PATH);
		B20LocalStandIns.standIn(_tokens(list, '.chainlinkStocks'));
		B20LocalStandIns.standIn(_tokens(list, '.verantaStocks'));
		B20LocalStandIns.standIn(_tokens(list, '.poolPriced'));
	}

	/// @dev The script's listing steps as the owner sends them. External, so a test can expect its revert.
	function listAsOwner() external {
		vm.startPrank(DEPLOYER);
		_list(d, list);
		vm.stopPrank();
	}

	function test_chainlinkStock_pricesFromItsFeedInsideABand() public {
		if (!forked) return;
		this.listAsOwner();
		address token = vm.parseJsonAddress(list, '.chainlinkStocks[0].token');
		address feed = vm.parseJsonAddress(list, '.chainlinkStocks[0].feed');
		(address aggregator, uint32 heartbeat, uint8 assetDecimals, uint8 rateDecimals) = d.valueInterpreter.getAssetInfo(token);
		assertEq(aggregator, feed, 'the Chainlink feed');
		assertEq(heartbeat, 5 days, 'a closing market\'s heartbeat');
		assertEq(assetDecimals, 8);
		assertEq(rateDecimals, 8);
		(, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
		(int256 min, int256 max) = d.valueInterpreter.answerBounds(token);
		assertEq(min, answer / 3, 'band floor');
		assertEq(max, answer * 3, 'band ceiling');
		assertEq(d.valueInterpreter.calcUsdRate(token), uint256(answer) * 1e10, 'priced at the feed\'s answer');
	}

	function test_verantaStocks_priceFromTheStoreTimesTheMultiplier() public {
		if (!forked) return;
		this.listAsOwner();
		uint256 count = _tokens(list, '.verantaStocks').length;
		assertEq(count, 5);
		for (uint256 i; i < count; ++i) {
			string memory at = string.concat('.verantaStocks[', vm.toString(i), ']');
			address token = vm.parseJsonAddress(list, string.concat(at, '.token'));
			uint256 pairIndex = vm.parseJsonUint(list, string.concat(at, '.pair'));
			uint256 price = vm.parseJsonUint(list, string.concat(at, '.referencePrice'));
			uint256 answer = price * IB20Multiplier(token).multiplier() / 1e18;

			(address aggregator, uint32 heartbeat,,) = d.valueInterpreter.getAssetInfo(token);
			B20VerantaPriceAdapter adapter = B20VerantaPriceAdapter(aggregator);
			assertEq(adapter.token(), token);
			assertEq(adapter.pairIndex(), pairIndex);
			assertEq(address(adapter.store()), address(d.verantaStore), 'the release\'s store');
			assertEq(adapter.maxPushAge(), 120);
			assertEq(adapter.maxFeedAge(), 5 days);
			assertEq(heartbeat, 120);
			(int256 min, int256 max) = d.valueInterpreter.answerBounds(token);
			assertEq(min, int256(answer / 3), 'band floor');
			assertEq(max, int256(answer * 3), 'band ceiling');

			// nobody has stored the pair yet: no price, as for any Veranta stock between stores
			vm.expectRevert(abi.encodeWithSelector(B20VerantaPriceAdapter.NeverPushed.selector, pairIndex));
			d.valueInterpreter.calcUsdRate(token);

			_store(pairIndex, price);
			assertEq(d.valueInterpreter.calcUsdRate(token), answer * 1e10, 'priced at Veranta x multiplier');
			_store(pairIndex, price * 4);
			vm.expectRevert();
			d.valueInterpreter.calcUsdRate(token);
		}
	}

	function test_perpMarket_mapsThePairToAMarkerOnVerantasPrice() public {
		if (!forked) return;
		assertEq(d.perpConfig.pairAsset(ANT_PAIR), address(0), 'unmapped before');
		this.listAsOwner();
		address marker = d.perpConfig.pairAsset(ANT_PAIR);
		assertEq(IERC20Metadata(marker).symbol(), 'vmANT');
		assertEq(IERC20Metadata(marker).totalSupply(), 0);
		(address aggregator, uint32 heartbeat,,) = d.valueInterpreter.getAssetInfo(marker);
		VerantaPriceAdapter adapter = VerantaPriceAdapter(aggregator);
		assertEq(adapter.pairIndex(), ANT_PAIR);
		assertEq(address(adapter.store()), address(d.verantaStore), 'the release\'s store');
		assertEq(adapter.maxPushAge(), 600);
		assertEq(heartbeat, 5 days);
		_store(ANT_PAIR, 96_70745000);
		assertEq(d.valueInterpreter.calcUsdRate(marker), 96_70745000 * 1e10);
	}

	function test_poolPricedTokens_areRegisteredOnTheirPools() public {
		if (!forked) return;
		this.listAsOwner();
		address[] memory tokens = _tokens(list, '.poolPriced');
		assertEq(tokens.length, 2);
		for (uint256 i; i < tokens.length; ++i) {
			(address aggregator,,,) = d.valueInterpreter.getAssetInfo(tokens[i]);
			assertTrue(aggregator != address(0), 'priced');
			assertEq(d.registrar.poolPricedAdapter(tokens[i]), aggregator, 'from its pool');
			assertGt(d.valueInterpreter.calcUsdRate(tokens[i]), 0, 'the pool\'s price reads');
		}
	}

	function test_secondRun_changesNothing() public {
		if (!forked) return;
		this.listAsOwner();
		address token = vm.parseJsonAddress(list, '.verantaStocks[0].token');
		(address aggregator,,,) = d.valueInterpreter.getAssetInfo(token);
		address marker = d.perpConfig.pairAsset(ANT_PAIR);
		vm.recordLogs();
		this.listAsOwner();
		assertEq(vm.getRecordedLogs().length, 0, 'no call that changes anything');
		(address aggregatorAfter,,,) = d.valueInterpreter.getAssetInfo(token);
		assertEq(aggregatorAfter, aggregator);
		assertEq(d.perpConfig.pairAsset(ANT_PAIR), marker);
	}

	/// @dev `register` is open to anyone: a stock registered on its pool before its feed is listed must stop the run, not
	///      be overwritten (the registrar would keep calling it pool-priced).
	function test_stockSomeonePoolPricedFirst_stopsTheRun() public {
		if (!forked) return;
		address token = vm.parseJsonAddress(list, '.verantaStocks[0].token');
		vm.prank(makeAddr('outsider'));
		address poolAdapter = d.registrar.register(token, TTWOC_POOL);
		vm.expectRevert(abi.encodeWithSelector(NewListings.PricedAnotherWay.selector, token, poolAdapter));
		this.listAsOwner();
	}

	function test_listedVault_isLeftAlone() public {
		if (!forked) return;
		address[] memory all = _clmVaults();
		assertEq(all.length, 24);
		Release.Deployed memory m = d;
		vm.recordLogs();
		vm.startPrank(DEPLOYER);
		for (uint256 i; i < all.length; ++i) {
			assertFalse(NewListings.clmVault(m, all[i]), 'already listed');
		}
		vm.stopPrank();
		assertEq(vm.getRecordedLogs().length, 0);
	}

	/// @dev A price for the pair as the store answers it after a push in this block: confirmed and last traded now.
	function _store(uint256 pairIndex, uint256 price) private {
		uint64 nowUs = uint64(block.timestamp * 1e6);
		vm.mockCall(
			address(d.verantaStore),
			abi.encodeCall(IVerantaPriceStore.latest, (pairIndex)),
			abi.encode(int64(uint64(price)), int16(-8), nowUs)
		);
		vm.mockCall(address(d.verantaStore), abi.encodeCall(IVerantaPriceStore.feedUpdatedUs, (pairIndex)), abi.encode(nowUs));
	}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IValueInterpreterAdmin} from '../../src/interfaces/IValueInterpreterAdmin.sol';
import {IPythLazerVerifier} from '../../src/interfaces/external/IPythLazerVerifier.sol';
import {VerantaPriceStore} from '../../src/pricing/VerantaPriceStore.sol';
import {B20VerantaPriceAdapter} from '../../src/pricing/B20VerantaPriceAdapter.sol';
import {BaseMainnet} from '../../script/release/BaseMainnet.sol';
import {B20Mirror} from '../utils/B20Mirror.sol';
import {ReleaseFork} from './utils/ReleaseFork.sol';
import {VerantaWeekendFixture as Fx} from '../utils/VerantaWeekendFixture.sol';

/// @dev A B20 stock token's two reads the VI and the adapter make, answered with the real token's values read from
///      Base at the fork block (B20Mirror._chainCall): Foundry can't run the B20 precompile.
contract B20PriceStandIn {
	uint8 public decimals;
	uint256 public multiplier;

	function set(uint8 decimals_, uint256 multiplier_) external {
		decimals = decimals_;
		multiplier = multiplier_;
	}
}

/// @notice The weekend-proof Veranta store against REAL Base data (founder 2026-10-25, option b): Pyth's real Lazer
///         verifier, Veranta's real pair→feed mapping and real packets signed on Sunday 2026-10-25 for the seven
///         stocks (VerantaWeekendFixture), on the release's store, each listed through the release's registrar.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/VerantaPriceStoreFork.t.sol
contract VerantaPriceStoreFork is ReleaseFork, B20Mirror {
	IPythLazerVerifier internal constant LAZER = IPythLazerVerifier(BaseMainnet.PYTH_LAZER_VERIFIER);
	uint32 internal constant MAX_PUSH_AGE = BaseMainnet.VERANTA_MAX_PUSH_AGE;
	uint32 internal constant MAX_FEED_AGE = BaseMainnet.VERANTA_MAX_FEED_AGE;

	address internal constant MUC = 0xb200000000000000000000Fd2f87532B90095211;
	address internal constant PLTRC = 0xb2000000000000000000007d16372840dF4dAbbe;
	address internal constant NFLXC = 0xb20000000000000000000058B8c947e44011dFE6;
	address internal constant AMDC = 0xB2000000000000000000000d8Ce462E99ee7A47B;
	address internal constant AVGOC = 0xB200000000000000000000Fc737aeA6196aB5a4c;
	address internal constant MRVLC = 0xB200000000000000000000eC3c4c7395Cc609813;
	address internal constant LLYC = 0xB200000000000000000000f1a0F91e34892E4718;

	struct Stock {
		address token;
		uint256 pair;
		int64 price;
		int16 exponent;
		uint64 feedUs;
		bytes packet;
	}

	ValueInterpreter internal vi;
	VerantaPriceStore internal store;
	uint256 internal fee;

	function _forkBlock() internal pure override returns (uint256) {
		return Fx.BLOCK;
	}

	function setUp() public override {
		super.setUp();
		if (!forked) return;
		vi = r.valueInterpreter;
		store = r.verantaStore;
		fee = LAZER.verification_fee();
	}

	function _stocks() internal pure returns (Stock[7] memory s) {
		s[0] = Stock(MUC, Fx.MU_PAIR, Fx.MU_PRICE, Fx.MU_EXPONENT, Fx.MU_FEED_US, Fx.MU_PACKET_1);
		s[1] = Stock(PLTRC, Fx.PLTR_PAIR, Fx.PLTR_PRICE, Fx.PLTR_EXPONENT, Fx.PLTR_FEED_US, Fx.PLTR_PACKET_1);
		s[2] = Stock(NFLXC, Fx.NFLX_PAIR, Fx.NFLX_PRICE, Fx.NFLX_EXPONENT, Fx.NFLX_FEED_US, Fx.NFLX_PACKET_1);
		s[3] = Stock(AMDC, Fx.AMD_PAIR, Fx.AMD_PRICE, Fx.AMD_EXPONENT, Fx.AMD_FEED_US, Fx.AMD_PACKET_1);
		s[4] = Stock(AVGOC, Fx.AVGO_PAIR, Fx.AVGO_PRICE, Fx.AVGO_EXPONENT, Fx.AVGO_FEED_US, Fx.AVGO_PACKET_1);
		s[5] = Stock(MRVLC, Fx.MRVL_PAIR, Fx.MRVL_PRICE, Fx.MRVL_EXPONENT, Fx.MRVL_FEED_US, Fx.MRVL_PACKET_1);
		s[6] = Stock(LLYC, Fx.LLY_PAIR, Fx.LLY_PRICE, Fx.LLY_EXPONENT, Fx.LLY_FEED_US, Fx.LLY_PACKET_1);
	}

	/// The stand-in at `token` (real decimals and multiplier), its adapter, listed through the registrar as the
	/// deployer. Returns the adapter and the real multiplier.
	function _list(Stock memory s) internal returns (B20VerantaPriceAdapter adapter, uint256 multiplier) {
		adapter = new B20VerantaPriceAdapter(store, s.pair, s.token, MAX_PUSH_AGE, MAX_FEED_AGE, 'stock / USD');
		multiplier = _listWith(s.token, adapter);
	}

	function _listWith(address token, B20VerantaPriceAdapter adapter) internal returns (uint256 multiplier) {
		uint8 decimals = abi.decode(_chainCall(token, abi.encodeWithSignature('decimals()')), (uint8));
		multiplier = abi.decode(_chainCall(token, abi.encodeWithSignature('multiplier()')), (uint256));
		if (_isB20(token)) {
			vm.etch(token, type(B20PriceStandIn).runtimeCode);
			B20PriceStandIn(token).set(decimals, multiplier);
		}
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.addPrimitive, (token, address(adapter), MAX_PUSH_AGE)));
	}

	/// price × 10^exponent at 8 decimals × multiplier / 1e18, then the VI's 1e18 rate precision
	function _expectedRate(Stock memory s, uint256 multiplier) internal pure returns (uint256) {
		int256 shift = 8 + int256(s.exponent);
		uint256 share = shift >= 0
			? uint256(uint64(s.price)) * 10 ** uint256(shift)
			: uint256(uint64(s.price)) / 10 ** uint256(-shift);
		return Math.mulDiv(share, multiplier, 1e18) * 1e10;
	}

	function test_fork_storesRealWeekendPacket() public {
		vm.skip(!forked);
		assertTrue(store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_1));
		(int64 price, int16 exponent, uint64 confirmedUs) = store.latest(Fx.MU_PAIR);
		assertEq(price, Fx.MU_PRICE, 'MU 879.92');
		assertEq(exponent, Fx.MU_EXPONENT);
		assertEq(confirmedUs, Fx.MU_HEADER_1, 'confirmed when Pyth signed it, on Sunday');
		assertEq(store.feedUpdatedUs(Fx.MU_PAIR), Fx.MU_FEED_US, 'last traded Friday');
	}

	function test_fork_weekendPacketReconfirms() public {
		vm.skip(!forked);
		store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_1);
		assertTrue(store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_2), 'the later Sunday packet re-confirms');
		(int64 price,, uint64 confirmedUs) = store.latest(Fx.MU_PAIR);
		assertEq(price, Fx.MU_PRICE, 'same Friday close');
		assertEq(confirmedUs, Fx.MU_HEADER_2);
		assertEq(store.feedUpdatedUs(Fx.MU_PAIR), Fx.MU_FEED_US);
		assertFalse(store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_1), 'the earlier packet is no longer news');
	}

	function test_fork_tamperedPacketRefused() public {
		vm.skip(!forked);
		bytes memory tampered = Fx.MU_PACKET_1;
		tampered[10] = bytes1(uint8(tampered[10]) ^ 0x01); // inside Pyth's signature
		vm.expectRevert();
		store.submit{value: fee}(Fx.MU_PAIR, tampered);
	}

	function test_fork_packetForAnotherPairRefused() public {
		vm.skip(!forked);
		vm.expectRevert(
			abi.encodeWithSelector(VerantaPriceStore.FeedNotFound.selector, Fx.MU_PAIR, uint32(store.pairs().getLazerFeedId(Fx.MU_PAIR)))
		);
		store.submit{value: fee}(Fx.MU_PAIR, Fx.PLTR_PACKET_1);
	}

	function test_fork_allSevenPriceThroughTheVi() public {
		vm.skip(!forked);
		Stock[7] memory stocks = _stocks();
		for (uint256 i; i < stocks.length; ++i) {
			assertTrue(_isB20(stocks[i].token), 'a real B20 token on Base');
			(, uint256 multiplier) = _list(stocks[i]);
			assertTrue(store.submit{value: fee}(stocks[i].pair, stocks[i].packet), 'its own Sunday packet');
			assertEq(vi.calcUsdRate(stocks[i].token), _expectedRate(stocks[i], multiplier), 'Veranta price x multiplier');
			assertEq(r.registrar.poolPricedAdapter(stocks[i].token), address(0), 'not long-tail');
		}
	}

	function test_fork_weekendPriceStaysReadable() public {
		vm.skip(!forked);
		Stock memory mu = _stocks()[0];
		_list(mu);
		store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_1);
		uint256 confirmed1 = Fx.MU_HEADER_1 / 1e6;

		store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_2); // the next confirmation, 24 s later
		uint256 confirmed2 = Fx.MU_HEADER_2 / 1e6;

		vm.warp(confirmed2 + MAX_PUSH_AGE);
		assertGt(vi.calcUsdRate(MUC), 0, 'a Friday close confirmed 2 minutes ago still prices on Sunday');

		vm.warp(confirmed2 + MAX_PUSH_AGE + 1);
		vm.expectRevert(abi.encodeWithSelector(B20VerantaPriceAdapter.StalePush.selector, confirmed2));
		vi.calcUsdRate(MUC);
	}

	/// Corporate actions (review 2026-10-25): the listing script bands each stock at ⅓×–3× its listing price, so a 4:1
	/// split whose multiplier moves while Pyth still confirms the old close reverts instead of pricing 4× too high.
	function test_fork_theBandStopsASplitMismatch() public {
		vm.skip(!forked);
		Stock memory mu = _stocks()[0];
		(, uint256 multiplier) = _list(mu);
		store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_1);
		int256 answer = int256(_expectedRate(mu, multiplier) / 1e10); // 8 decimals, as list-veranta-stocks.sh reads it
		r.registrar.execute(abi.encodeCall(IValueInterpreterAdmin.setAnswerBounds, (MUC, answer / 3, answer * 3)));
		assertGt(vi.calcUsdRate(MUC), 0, 'inside its band');

		B20PriceStandIn(MUC).set(8, multiplier * 4); // Coinbase applies a 4:1 split; Pyth still re-confirms Friday's close
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.AnswerOutOfBounds.selector, MUC, answer * 4));
		vi.calcUsdRate(MUC);
	}

	/// Price picking (review 2026-10-25): a packet can't be held back and relayed later — only one signed within the
	/// last minute is stored, so the stored price is at most about 3 minutes old when a fund is valued on it.
	function test_fork_aHeldBackPacketIsRefused() public {
		vm.skip(!forked);
		store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_1);
		vm.warp(Fx.MU_HEADER_2 / 1e6 + store.MAX_RELAY_AGE() + 1);
		vm.expectRevert(abi.encodeWithSelector(VerantaPriceStore.PacketTooOld.selector, Fx.MU_HEADER_2));
		store.submit{value: fee}(Fx.MU_PAIR, Fx.MU_PACKET_2);
	}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console} from 'forge-std/Script.sol';
import {StdCheats} from 'forge-std/StdCheats.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {AggregatorV3Interface} from '../../src/interfaces/AggregatorV3Interface.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {ISlipstreamSwapRouter} from '../../src/interfaces/external/ISlipstreamSwapRouter.sol';
import {IUniswapV2Router02} from '../../src/interfaces/external/IUniswapV2Router02.sol';
import {IAerodromeRouter} from '../../src/interfaces/external/IAerodromeRouter.sol';
import {IConcentratedPoolOracle} from '../../src/pricing/TwapAggregatorAdapter.sol';
import {TwapAggregatorAdapterV2} from '../../src/pricing/TwapAggregatorAdapterV2.sol';
import {IAerodromeBasicPool} from '../../src/pricing/AerodromeBasicTwapAdapter.sol';
import {IUniswapV2Pair} from '../../src/pricing/UniswapV2ObservationRecorder.sol';
import {ITwapPriceAdapter} from '../../src/interfaces/ITwapPriceAdapter.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {TwapListingV2} from './TwapListingV2.sol';

/// @notice A Slipstream pool factory's enabled tick spacings (all three Aerodrome deployments).
interface ISlipstreamFactorySpacings {
	function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
	function tickSpacings() external view returns (int24[] memory);
}

/// @notice A concentrated pool's swap fee in pips (Uniswap v3: the tier; Slipstream: the current fee).
interface IPoolFeePips {
	function fee() external view returns (uint24);
}

/// @notice Aerodrome PoolFactory 0x420D…40Da: the pool's fee in basis points (verified source).
interface IAerodromeFeeFactory {
	function getFee(address pool, bool stable) external view returns (uint256);
}

/// @notice Aerodrome basic pool: the x·y=k quote after the pool fee (verified source).
interface IAerodromeAmountOut {
	function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

/// @notice Reads a token's ERC-20 symbol from its own contract, so a symbol() that reverts or isn't a
///         string is caught by the caller's try (a script may not call itself).
contract SymbolReader {
	function symbolOf(address token) external view returns (string memory) {
		return IERC20Metadata(token).symbol();
	}
}

/// @title MeasureListable
/// @notice TWAP listing v2b, Task 9: how many tokens would list TODAY, measured against live Base
///         state by the real system. READ-ONLY: run with `--fork-url` and never `--broadcast` (there
///         is no vm.broadcast here; every state change lives in the fork simulation and dies with it).
///         The system is deployed as the acceptance test does it: TwapListingV2.deploy under the
///         genesis deployer's prank (deployments/base-mainnet.json), with a measurement keeper on the
///         PriceListingModule. For every token given:
///         1. the live VI (0x3CDb…98D4) already prices it → VI_PRICED, nothing else read;
///         2. for each quote it trades against (USDC / WETH / cbBTC, from the candidate list) every
///            venue factory is asked for every listable fee tier / tick spacing (Uniswap v3
///            500/3000/10000; every Slipstream factory's tickSpacings() ≥ 10; Uniswap v2 getPair;
///            Aerodrome getPool(…, false), plus (…, true) for the stable-only reason); the tiers under
///            MIN_TICK_SPACING (Uniswap v3 100/200/300/400, Slipstream 1), which can never list, are
///            asked only where the candidate list saw such a pool (for the spacing reason);
///         3. each pool found: under MIN_TICK_SPACING → SPACING; Aerodrome stable → STABLE; its QUOTE
///            balance × the quote feed < MIN_QUOTE_RESERVE_USD → RESERVE (one read, the pool itself
///            untouched: every venue's reserve read is at most that balance, so nothing that could
///            qualify is skipped);
///         4. the rest are tried LARGEST QUOTE BALANCE FIRST, as the keeper would, and the first that
///            lists ends the token (later ones → NOT_NEEDED):
///            - concentrated pools with cardinality ≥ MIN_OBSERVATION_CARDINALITY and Aerodrome
///              volatile pools: the keeper's `module.list` in a state snapshot → LISTS_NOW, or
///              REFUSED with the registry's revert data;
///            - only if none lists now: Uniswap v2 pairs get the recorder's snapshot at the fork block
///              and, after ONE 31-min warp (~930 blocks), `module.list` → AFTER_V2_HISTORY / REFUSED;
///              concentrated pools under the cardinality minimum are read through the registry's
///              adapter after a 31-min warp in a snapshot (the keeper raises the ring and waits; a
///              quiet window, TWAP = spot) → AFTER_PREP / PREP_REFUSED;
///            next to each listing an adapter built by the registry's own deployer with the
///            registry's parameters fills the reserve / band / price columns;
///         5. the pool a token lists on gets the keeper policy's round trip: buy ~$100 of the token
///            with the quote through the venue's router, one block later sell it all back; a loss over
///            2 × pool fee + 1% or a reverting leg → taxed / honeypot.
///         The CL and Aerodrome measurements run at the fork block, on the pools' own observations;
///         the warps happen only in snapshots or after them. Output: pipe-separated META / TOKEN /
///         ROW / B20 lines, parsed by .ops-scratch/twap-scan/analyze.py.
/// @dev Input (env, comma-separated, parallel arrays): MEASURE_TOKENS; MEASURE_QMASK (bit 0 USDC,
///      1 WETH, 2 cbBTC); MEASURE_FINE (bit 2q: Uniswap v3 fine tiers vs quote q, bit 2q+1:
///      Slipstream spacing 1 vs quote q); optional MEASURE_B20 (B20 tokens: only the VI is asked —
///      Foundry has no B20 precompile, so the token itself is never called). Run (no broadcast):
///      forge script script/mainnet/MeasureListable.s.sol --tc MeasureListable
///        --fork-url <rpc> --fork-block-number <n> --compute-units-per-second <cups>
contract MeasureListable is Script, StdCheats {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';
	uint256 internal constant WARP = 31 minutes;
	uint256 internal constant WARP_BLOCKS = 930;
	uint256 internal constant PROBE_USD = 100;
	uint256 internal constant MAX_POOLS = 128;
	address internal constant TRADER = address(uint160(uint256(keccak256('frosty.measure.taxprobe'))));

	TwapListingV2.Deployed internal d;
	ValueInterpreter internal vi;
	SymbolReader internal symbols;
	address internal keeper;
	uint256 internal minReserve18;
	uint256 internal minBand18;
	int24 internal minSpacing;
	uint16 internal minCardinality;
	address[3] internal slipFactories;
	TwapListingRegistryV2.Venue[3] internal slipVenues;
	mapping(uint256 => int24[]) internal slipSpacings;

	struct Pool {
		address token;
		address quote;
		TwapListingRegistryV2.Venue venue;
		int24 fee;
		address pool;
	}

	struct Cand {
		Pool p;
		uint256 balanceUsd18;
		int24 spacing;
		uint16 cardinality;
		bool live;
	}

	/// @dev One token's pools found so far: c[0..n) the live candidates, `found` every pool found.
	struct Found {
		Cand[] c;
		uint256 n;
		uint256 found;
	}

	struct Eval {
		string outcome;
		bytes err;
		int24 spacing;
		uint16 cardinality;
		uint256 balanceUsd18;
		uint256 reserveUsd18;
		uint256 bandUsd18;
		uint256 twapUsd18;
		uint256 spotUsd18;
		int24 meanTick;
		int24 spotTick;
		bool assetIsToken0;
		bool ticksKnown;
		bool windowNow;
		string tax;
		uint256 lossBps;
		uint256 thresholdBps;
		uint256 buyTaxBps;
		uint256 sellTaxBps;
	}

	/// @dev Uniswap v2 pairs awaiting the phase-B warp, largest first within each token.
	Cand[] internal v2Pending;

	function run() external {
		_deploySystem();
		address[] memory tokens = vm.envOr('MEASURE_TOKENS', ',', new address[](0));
		uint256[] memory qmask = vm.envOr('MEASURE_QMASK', ',', new uint256[](0));
		uint256[] memory fine = vm.envOr('MEASURE_FINE', ',', new uint256[](0));
		address[] memory b20 = vm.envOr('MEASURE_B20', ',', new address[](0));
		require(tokens.length == qmask.length && tokens.length == fine.length, 'input lengths');
		_logFeeds('fork');

		// phase A, at the fork block
		for (uint256 i; i < tokens.length; ++i) {
			_token(tokens[i], qmask[i], fine[i]);
		}
		// phase B: one 31-min warp gives every recorded v2 pair its window
		vm.warp(block.timestamp + WARP);
		vm.roll(block.number + WARP_BLOCKS);
		_logFeeds('warped');
		bool tokenDone;
		for (uint256 i; i < v2Pending.length; ++i) {
			if (i == 0 || v2Pending[i].p.token != v2Pending[i - 1].p.token) tokenDone = false;
			if (tokenDone) {
				_skip(v2Pending[i]);
			} else {
				tokenDone = _evalV2(v2Pending[i]);
			}
		}
		for (uint256 i; i < b20.length; ++i) {
			console.log(string.concat('B20|', vm.toString(b20[i]), '|', vm.toString(vi.isSupportedAsset(b20[i]))));
		}
		console.log('META|done');
	}

	// ─── setup ──────────────────────────────────────────────────────────────────

	function _deploySystem() internal {
		string memory genesis = vm.readFile(GENESIS_FILE);
		address deployer = vm.parseJsonAddress(genesis, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		keeper = address(uint160(uint256(keccak256('frosty.measure.keeper'))));
		vm.startPrank(deployer);
		d = TwapListingV2.deploy(
			TwapListingV2.Config({
				deployer: deployer,
				valueInterpreter: vi,
				factory: FundFactory(vm.parseJsonAddress(genesis, '.factory')),
				twapPolicyV1: vm.parseJsonAddress(genesis, '.twapPolicy'),
				keeper: keeper
			})
		);
		vm.stopPrank();
		symbols = new SymbolReader();
		minReserve18 = d.registry.MIN_QUOTE_RESERVE_USD() * 1e18;
		minBand18 = d.registry.MIN_BAND_DEPTH_USD() * 1e18;
		minSpacing = d.registry.MIN_TICK_SPACING();
		minCardinality = d.registry.MIN_OBSERVATION_CARDINALITY();
		slipFactories = [FundsMainnet.CL_FACTORY, FundsMainnet.CL2_FACTORY, TwapListingV2.CL3_FACTORY];
		slipVenues = [
			TwapListingRegistryV2.Venue.Slipstream,
			TwapListingRegistryV2.Venue.Slipstream2,
			TwapListingRegistryV2.Venue.Slipstream3
		];
		for (uint256 f; f < 3; ++f) {
			int24[] memory s = ISlipstreamFactorySpacings(slipFactories[f]).tickSpacings();
			for (uint256 i; i < s.length; ++i) {
				slipSpacings[f].push(s[i]);
			}
		}
		console.log(
			string.concat(
				'META|system|',
				vm.toString(address(d.registry)),
				'|',
				vm.toString(address(vi)),
				'|',
				vm.toString(block.number),
				'|',
				vm.toString(block.timestamp)
			)
		);
		console.log(
			string.concat(
				'META|rules|',
				vm.toString(minReserve18 / 1e18),
				'|',
				vm.toString(minBand18 / 1e18),
				'|',
				vm.toString(int256(minSpacing)),
				'|',
				vm.toString(uint256(minCardinality)),
				'|',
				vm.toString(uint256(d.registry.WINDOW())),
				'|',
				vm.toString(uint256(d.registry.MAX_DEVIATION_BPS()))
			)
		);
	}

	/// @dev Each quote feed's age against its registry heartbeat (fresh = the adapters accept it).
	function _logFeeds(string memory stage) internal view {
		address[3] memory qs = [FundsMainnet.USDC, FundsMainnet.WETH, FundsMainnet.CBBTC];
		for (uint256 i; i < 3; ++i) {
			(AggregatorV3Interface feed, uint32 heartbeat) = d.registry.quotes(qs[i]);
			(, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
			console.log(
				string.concat(
					'META|feed|',
					stage,
					'|',
					vm.toString(qs[i]),
					'|',
					vm.toString(answer),
					'|',
					vm.toString(block.timestamp - updatedAt),
					'|',
					vm.toString(uint256(heartbeat)),
					'|',
					vm.toString(block.timestamp <= updatedAt + heartbeat)
				)
			);
		}
	}

	// ─── per token ──────────────────────────────────────────────────────────────

	function _token(address token, uint256 qmask, uint256 fine) internal {
		string memory sym = '?';
		try symbols.symbolOf(token) returns (string memory s) {
			sym = s;
		} catch {}
		if (vi.isSupportedAsset(token)) {
			_tokenLine(token, sym, 'VI_PRICED', 0, qmask);
			return;
		}
		address[3] memory qs = [FundsMainnet.USDC, FundsMainnet.WETH, FundsMainnet.CBBTC];
		Found memory x = Found(new Cand[](MAX_POOLS), 0, 0);
		for (uint256 q; q < 3; ++q) {
			if ((qmask >> q) & 1 == 0) continue;
			uint256 hint = (fine >> (2 * q)) & 3;
			_enumUniswapV3(token, qs[q], hint & 1 == 1, x);
			for (uint256 f; f < 3; ++f) {
				_enumSlipstream(token, qs[q], f, hint & 2 == 2, x);
			}
			_enumBasic(token, qs[q], x);
		}
		uint256[] memory order = _byBalance(x.c, x.n);
		if (!_listNowPass(x.c, order)) {
			_deferV2(x.c, order);
			_prepPass(x.c, order);
		}
		for (uint256 i; i < order.length; ++i) {
			if (x.c[order[i]].live) _skip(x.c[order[i]]);
		}
		_tokenLine(token, sym, 'MEASURED', x.found, qmask);
	}

	function _tokenLine(address token, string memory sym, string memory what, uint256 found, uint256 qmask)
		internal
		pure
	{
		console.log(
			string.concat(
				'TOKEN|', vm.toString(token), '|', sym, '|', what, '|', vm.toString(found), '|', vm.toString(qmask)
			)
		);
	}

	// ─── enumeration: every factory, every tier ─────────────────────────────────

	function _enumUniswapV3(address token, address quote, bool fineTiers, Found memory x) internal {
		uint24[3] memory coarse = [uint24(500), 3000, 10000];
		for (uint256 i; i < 3; ++i) {
			_consider(x, _uniPool(token, quote, coarse[i]), _uniSpacing(coarse[i]));
		}
		if (fineTiers) {
			uint24[4] memory fineFees = [uint24(100), 200, 300, 400];
			for (uint256 i; i < 4; ++i) {
				_consider(x, _uniPool(token, quote, fineFees[i]), _uniSpacing(fineFees[i]));
			}
		}
	}

	function _uniPool(address token, address quote, uint24 fee) internal view returns (Pool memory) {
		address p = d.registry.uniswapFactory().getPool(token, quote, fee);
		return Pool(token, quote, TwapListingRegistryV2.Venue.UniswapV3, int24(fee), p);
	}

	/// @dev feeAmountTickSpacing on Base's Uniswap v3 factory (cast 2026-10-01; 250/1000/2500/5000/20000
	///      are not enabled). The registry itself reads tickSpacing() from the pool.
	function _uniSpacing(uint24 fee) internal pure returns (int24) {
		if (fee == 100) return 1;
		if (fee == 200) return 4;
		if (fee == 300) return 6;
		if (fee == 400) return 8;
		if (fee == 500) return 10;
		if (fee == 3000) return 60;
		return 200;
	}

	function _enumSlipstream(address token, address quote, uint256 f, bool fineTiers, Found memory x) internal {
		int24[] storage spacings = slipSpacings[f];
		for (uint256 i; i < spacings.length; ++i) {
			int24 ts = spacings[i];
			if (ts < minSpacing && !fineTiers) continue;
			address p = ISlipstreamFactorySpacings(slipFactories[f]).getPool(token, quote, ts);
			_consider(x, Pool(token, quote, slipVenues[f], ts, p), ts);
		}
	}

	function _enumBasic(address token, address quote, Found memory x) internal {
		address v2 = d.registry.uniswapV2Factory().getPair(token, quote);
		_consider(x, Pool(token, quote, TwapListingRegistryV2.Venue.UniswapV2, 0, v2), 0);
		address aero = d.registry.aerodromeBasicFactory().getPool(token, quote, false);
		_consider(x, Pool(token, quote, TwapListingRegistryV2.Venue.AerodromeBasic, 0, aero), 0);
		address stable = d.registry.aerodromeBasicFactory().getPool(token, quote, true);
		if (stable != address(0)) {
			++x.found;
			Eval memory e;
			e.outcome = 'STABLE';
			e.balanceUsd18 = _balanceUsd18(quote, stable);
			_row(Pool(token, quote, TwapListingRegistryV2.Venue.AerodromeBasic, -1, stable), e);
		}
	}

	/// @dev A found pool: SPACING / RESERVE rows right away, otherwise a live candidate.
	function _consider(Found memory x, Pool memory p, int24 spacing) internal {
		if (p.pool == address(0)) return;
		++x.found;
		Eval memory e;
		e.spacing = spacing;
		e.balanceUsd18 = _balanceUsd18(p.quote, p.pool);
		bool concentrated = uint256(p.venue) <= uint256(TwapListingRegistryV2.Venue.Slipstream3);
		if (concentrated && spacing < minSpacing) {
			e.outcome = 'SPACING';
			_row(p, e);
		} else if (e.balanceUsd18 < minReserve18) {
			e.outcome = 'RESERVE';
			_row(p, e);
		} else {
			require(x.n < MAX_POOLS, 'MAX_POOLS');
			x.c[x.n] = Cand(p, e.balanceUsd18, spacing, 0, true);
			++x.n;
		}
	}

	/// @dev Indices of c[0..n) by quote balance, largest first.
	function _byBalance(Cand[] memory c, uint256 n) internal pure returns (uint256[] memory order) {
		order = new uint256[](n);
		for (uint256 i; i < n; ++i) {
			order[i] = i;
			for (uint256 j = i; j > 0 && c[order[j - 1]].balanceUsd18 < c[order[j]].balanceUsd18; --j) {
				(order[j - 1], order[j]) = (order[j], order[j - 1]);
			}
		}
	}

	// ─── passes ─────────────────────────────────────────────────────────────────

	/// @dev Concentrated (ring ≥ minimum) and Aerodrome volatile pools, largest first; true at the first listing.
	function _listNowPass(Cand[] memory c, uint256[] memory order) internal returns (bool) {
		for (uint256 i; i < order.length; ++i) {
			Cand memory k = c[order[i]];
			if (k.p.venue == TwapListingRegistryV2.Venue.UniswapV2) continue;
			if (k.p.venue == TwapListingRegistryV2.Venue.AerodromeBasic) {
				k.live = false;
				if (_evalAero(k)) return true;
				continue;
			}
			k.cardinality = _cardinality(k.p.pool);
			if (k.cardinality < minCardinality) continue;
			k.live = false;
			if (_evalCLNow(k)) return true;
		}
		return false;
	}

	/// @dev Nothing lists now: every live v2 pair gets the recorder's first snapshot (the keeper's
	///      step), at the fork block, and waits for phase B.
	function _deferV2(Cand[] memory c, uint256[] memory order) internal {
		for (uint256 i; i < order.length; ++i) {
			Cand memory k = c[order[i]];
			if (!k.live || k.p.venue != TwapListingRegistryV2.Venue.UniswapV2) continue;
			k.live = false;
			try d.recorder.record(k.p.pool) returns (bool) {
				v2Pending.push(k);
			} catch (bytes memory err) {
				Eval memory e;
				e.outcome = 'RECORD_REVERTS';
				e.balanceUsd18 = k.balanceUsd18;
				e.err = err;
				_row(k.p, e);
			}
		}
	}

	/// @dev Nothing lists now: concentrated pools under the ring minimum, largest first, until one
	///      would list after the keeper's oracle prep.
	function _prepPass(Cand[] memory c, uint256[] memory order) internal {
		for (uint256 i; i < order.length; ++i) {
			Cand memory k = c[order[i]];
			if (!k.live || uint256(k.p.venue) > uint256(TwapListingRegistryV2.Venue.Slipstream3)) continue;
			k.live = false;
			if (_evalCLAfterPrep(k)) return;
		}
	}

	function _skip(Cand memory k) internal {
		k.live = false;
		Eval memory e;
		e.outcome = 'NOT_NEEDED';
		e.spacing = k.spacing;
		e.cardinality = k.cardinality;
		e.balanceUsd18 = k.balanceUsd18;
		_row(k.p, e);
	}

	function _eval(Cand memory k) internal pure returns (Eval memory e) {
		e.spacing = k.spacing;
		e.cardinality = k.cardinality;
		e.balanceUsd18 = k.balanceUsd18;
	}

	// ─── concentrated liquidity ─────────────────────────────────────────────────

	function _evalCLNow(Cand memory k) internal returns (bool listed) {
		Eval memory e = _eval(k);
		(uint256 snap, uint256 t0, uint256 n0) = _snap();
		(bool ok, bytes memory ret) = _list(k.p);
		TwapAggregatorAdapterV2 a = _clAdapter(k.p, e);
		if (address(a) != address(0)) {
			_readAdapter(ITwapPriceAdapter(address(a)), e);
			_ticks(a, k.p, e);
		}
		listed = _settle(k.p, e, ok, ret, 'LISTS_NOW');
		_restore(snap, t0, n0);
		_row(k.p, e);
	}

	/// @dev Ring under the registry's minimum: the keeper raises it and waits for a window of history.
	///      The registry-parameter adapter is read now (does the window serve today?) and after a
	///      quiet 31-min warp (what the keeper lists into), inside a snapshot.
	function _evalCLAfterPrep(Cand memory k) internal returns (bool listed) {
		Eval memory e = _eval(k);
		(uint256 snap, uint256 t0, uint256 n0) = _snap();
		TwapAggregatorAdapterV2 a = _clAdapter(k.p, e);
		e.outcome = 'PREP_REFUSED';
		if (address(a) != address(0)) {
			try a.latestRoundData() returns (uint80, int256, uint256, uint256, uint80) {
				e.windowNow = true;
			} catch {}
			vm.warp(block.timestamp + WARP);
			vm.roll(block.number + WARP_BLOCKS);
			_readAdapter(ITwapPriceAdapter(address(a)), e);
			_ticks(a, k.p, e);
			if (e.err.length == 0 && e.twapUsd18 > 0 && e.reserveUsd18 >= minReserve18 && e.bandUsd18 >= minBand18) {
				e.outcome = 'AFTER_PREP';
				listed = true;
				_probe(k.p, e);
			}
		}
		_restore(snap, t0, n0);
		_row(k.p, e);
	}

	function _clAdapter(Pool memory p, Eval memory e) internal returns (TwapAggregatorAdapterV2) {
		(AggregatorV3Interface feed, uint32 heartbeat) = d.registry.quotes(p.quote);
		try d.clDeployer.deploy(
			IConcentratedPoolOracle(p.pool),
			p.token,
			feed,
			d.registry.WINDOW(),
			d.registry.MIN_QUOTE_RESERVE_USD(),
			d.registry.MAX_DEVIATION_BPS(),
			heartbeat,
			'measure'
		) returns (address a) {
			e.assetIsToken0 = TwapAggregatorAdapterV2(a).assetIsToken0();
			return TwapAggregatorAdapterV2(a);
		} catch (bytes memory err) {
			e.err = err;
			return TwapAggregatorAdapterV2(address(0));
		}
	}

	function _ticks(TwapAggregatorAdapterV2 a, Pool memory p, Eval memory e) internal view {
		try a.consult() returns (int24 meanTick, uint128) {
			e.meanTick = meanTick;
			e.ticksKnown = true;
		} catch {}
		(bool ok, bytes memory data) = p.pool.staticcall(abi.encodeWithSignature('slot0()'));
		if (ok && data.length >= 64) (, e.spotTick) = abi.decode(data, (uint160, int24));
	}

	/// @dev slot0's fourth word (Uniswap v3 and Slipstream alike), as the registry reads it.
	function _cardinality(address pool) internal view returns (uint16 cardinality) {
		(bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature('slot0()'));
		if (!ok || data.length < 128) return 0;
		(,,, cardinality) = abi.decode(data, (uint160, int24, uint16, uint16));
	}

	// ─── Aerodrome basic + Uniswap v2 ───────────────────────────────────────────

	function _evalAero(Cand memory k) internal returns (bool listed) {
		Eval memory e = _eval(k);
		(uint256 snap, uint256 t0, uint256 n0) = _snap();
		(bool ok, bytes memory ret) = _list(k.p);
		(AggregatorV3Interface feed, uint32 heartbeat) = d.registry.quotes(k.p.quote);
		try d.aeroDeployer.deploy(
			IAerodromeBasicPool(k.p.pool),
			k.p.token,
			feed,
			d.registry.WINDOW(),
			d.registry.MIN_QUOTE_RESERVE_USD(),
			d.registry.MAX_DEVIATION_BPS(),
			heartbeat,
			'measure'
		) returns (address a) {
			_readAdapter(ITwapPriceAdapter(a), e);
			(uint256 r0, uint256 r1,) = IAerodromeBasicPool(k.p.pool).getReserves();
			e.spotUsd18 = _spotUsd18(k.p, r0, r1);
		} catch (bytes memory err) {
			if (e.err.length == 0) e.err = err;
		}
		listed = _settle(k.p, e, ok, ret, 'LISTS_NOW');
		_restore(snap, t0, n0);
		_row(k.p, e);
	}

	function _evalV2(Cand memory k) internal returns (bool listed) {
		Eval memory e = _eval(k);
		(uint256 snap, uint256 t0, uint256 n0) = _snap();
		(bool ok, bytes memory ret) = _list(k.p);
		(AggregatorV3Interface feed, uint32 heartbeat) = d.registry.quotes(k.p.quote);
		try d.v2Deployer.deploy(
			IUniswapV2Pair(k.p.pool),
			k.p.token,
			feed,
			d.recorder,
			d.registry.WINDOW(),
			d.registry.MIN_QUOTE_RESERVE_USD(),
			d.registry.MAX_DEVIATION_BPS(),
			heartbeat,
			'measure'
		) returns (address a) {
			_readAdapter(ITwapPriceAdapter(a), e);
			(uint112 r0, uint112 r1,) = IUniswapV2Pair(k.p.pool).getReserves();
			e.spotUsd18 = _spotUsd18(k.p, r0, r1);
		} catch (bytes memory err) {
			if (e.err.length == 0) e.err = err;
		}
		listed = _settle(k.p, e, ok, ret, 'AFTER_V2_HISTORY');
		_restore(snap, t0, n0);
		_row(k.p, e);
	}

	/// @dev The registry's verdict decides the outcome; a listing gets the tax probe.
	function _settle(Pool memory p, Eval memory e, bool ok, bytes memory ret, string memory listed)
		internal
		returns (bool)
	{
		if (!ok) {
			e.outcome = 'REFUSED';
			e.err = ret;
			return false;
		}
		e.outcome = listed;
		e.err = '';
		_probe(p, e);
		return true;
	}

	/// @dev USD (18 dp) per whole asset at the reserves' spot, rounded once (the adapters' math);
	///      only reached once the adapter's constructor has read both tokens' decimals.
	function _spotUsd18(Pool memory p, uint256 r0, uint256 r1) internal view returns (uint256) {
		bool assetIs0 = IUniswapV2Pair(p.pool).token0() == p.token;
		(uint256 rA, uint256 rQ) = assetIs0 ? (r0, r1) : (r1, r0);
		if (rA == 0) return 0;
		uint256 scale = 10 ** IERC20Metadata(p.token).decimals() * _quoteUsd18(p.quote);
		return Math.mulDiv(rQ, scale, rA) / 10 ** IERC20Metadata(p.quote).decimals();
	}

	// ─── shared reads ───────────────────────────────────────────────────────────

	/// @dev The registry-parameter adapter's three reads; the first revert is kept in e.err.
	function _readAdapter(ITwapPriceAdapter a, Eval memory e) internal view {
		try a.latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
			e.twapUsd18 = uint256(answer);
		} catch (bytes memory err) {
			if (e.err.length == 0) e.err = err;
		}
		try a.quoteReserveUsd() returns (uint256 r) {
			e.reserveUsd18 = r;
		} catch (bytes memory err) {
			if (e.err.length == 0) e.err = err;
		}
		try a.poolDepthUsd() returns (uint256 b) {
			e.bandUsd18 = b;
		} catch (bytes memory err) {
			if (e.err.length == 0) e.err = err;
		}
	}

	/// @dev The keeper's listing call, as the module receives it; returns the raw revert data.
	function _list(Pool memory p) internal returns (bool ok, bytes memory ret) {
		vm.prank(keeper);
		(ok, ret) =
			address(d.module).call(abi.encodeCall(PriceListingModule.list, (p.token, p.quote, p.venue, p.fee)));
	}

	function _balanceUsd18(address quote, address pool) internal view returns (uint256) {
		return Math.mulDiv(IERC20(quote).balanceOf(pool), _quoteUsd18(quote), 10 ** IERC20Metadata(quote).decimals());
	}

	function _quoteUsd18(address quote) internal view returns (uint256) {
		(AggregatorV3Interface feed,) = d.registry.quotes(quote);
		(, int256 answer,,,) = feed.latestRoundData();
		return uint256(answer) * 10 ** (18 - feed.decimals());
	}

	function _snap() internal returns (uint256 snap, uint256 t0, uint256 n0) {
		return (vm.snapshotState(), block.timestamp, block.number);
	}

	/// @dev Roll the fork back, block env included (set explicitly: the warps must not leak).
	function _restore(uint256 snap, uint256 t0, uint256 n0) internal {
		vm.revertToStateAndDelete(snap);
		vm.warp(t0);
		vm.roll(n0);
	}

	// ─── keeper policy: transfer-tax / honeypot round trip ──────────────────────

	/// @dev ~$100 of quote → token through the venue's router, one block later the whole proceeds
	///      back. Inside the caller's snapshot, so the swaps are rolled back.
	function _probe(Pool memory p, Eval memory e) internal {
		uint256 amountIn = Math.mulDiv(PROBE_USD * 1e18, 10 ** IERC20Metadata(p.quote).decimals(), _quoteUsd18(p.quote));
		e.thresholdBps = 2 * _feePips(p) / 100 + 100;
		deal(p.quote, TRADER, amountIn);
		vm.startPrank(TRADER, TRADER);
		uint256 tokenBefore = IERC20(p.token).balanceOf(TRADER);
		(bool okBuy, uint256 expectedBuy) = _swap(p, p.quote, p.token, amountIn);
		uint256 got = okBuy ? _delta(IERC20(p.token).balanceOf(TRADER), tokenBefore) : 0;
		if (!okBuy || got == 0) {
			e.tax = okBuy ? 'BUY_ZERO' : 'BUY_REVERTS';
			e.lossBps = 10_000;
			vm.stopPrank();
			return;
		}
		e.buyTaxBps = expectedBuy > got ? (expectedBuy - got) * 10_000 / expectedBuy : 0;
		vm.roll(block.number + 1);
		vm.warp(block.timestamp + 2);
		uint256 quoteBefore = IERC20(p.quote).balanceOf(TRADER);
		(bool okSell, uint256 expectedSell) = _swap(p, p.token, p.quote, got);
		uint256 back = okSell ? _delta(IERC20(p.quote).balanceOf(TRADER), quoteBefore) : 0;
		vm.stopPrank();
		if (!okSell) {
			e.tax = 'SELL_REVERTS';
			e.lossBps = 10_000;
			return;
		}
		e.sellTaxBps = expectedSell > back ? (expectedSell - back) * 10_000 / expectedSell : 0;
		e.lossBps = back >= amountIn ? 0 : (amountIn - back) * 10_000 / amountIn;
		e.tax = e.lossBps > e.thresholdBps ? 'TAXED' : 'OK';
	}

	function _delta(uint256 afterBal, uint256 beforeBal) internal pure returns (uint256) {
		return afterBal > beforeBal ? afterBal - beforeBal : 0;
	}

	function _feePips(Pool memory p) internal view returns (uint256) {
		if (p.venue == TwapListingRegistryV2.Venue.UniswapV2) return 3000;
		if (p.venue == TwapListingRegistryV2.Venue.AerodromeBasic) {
			return IAerodromeFeeFactory(TwapListingV2.AERODROME_POOL_FACTORY).getFee(p.pool, false) * 100;
		}
		return IPoolFeePips(p.pool).fee();
	}

	/// @dev One exact-input swap on the measured pool's venue; `expectedOut` is what the pool pays
	///      before any transfer tax (CL: the router's return; v2 / Aerodrome: the pool's x·y=k quote of
	///      the full amount in), so expectedOut − received is the token's transfer tax.
	function _swap(Pool memory p, address tokenIn, address tokenOut, uint256 amountIn)
		internal
		returns (bool ok, uint256 expectedOut)
	{
		if (p.venue == TwapListingRegistryV2.Venue.UniswapV2) return _swapV2(p, tokenIn, tokenOut, amountIn);
		if (p.venue == TwapListingRegistryV2.Venue.AerodromeBasic) return _swapAero(p, tokenIn, tokenOut, amountIn);
		if (p.venue == TwapListingRegistryV2.Venue.UniswapV3) {
			_approve(tokenIn, FundsMainnet.UNI_SWAP_ROUTER02, amountIn);
			try IUniswapV3SwapRouter(FundsMainnet.UNI_SWAP_ROUTER02).exactInputSingle(
				IUniswapV3SwapRouter.ExactInputSingleParams(tokenIn, tokenOut, uint24(p.fee), TRADER, amountIn, 0, 0)
			) returns (uint256 out) {
				return (true, out);
			} catch {
				return (false, 0);
			}
		}
		address router = _slipstreamRouter(p.venue);
		_approve(tokenIn, router, amountIn);
		try ISlipstreamSwapRouter(router).exactInputSingle(
			ISlipstreamSwapRouter.ExactInputSingleParams(tokenIn, tokenOut, p.fee, TRADER, block.timestamp, amountIn, 0, 0)
		) returns (uint256 out) {
			return (true, out);
		} catch {
			return (false, 0);
		}
	}

	function _swapV2(Pool memory p, address tokenIn, address tokenOut, uint256 amountIn)
		internal
		returns (bool, uint256 expectedOut)
	{
		(uint112 r0, uint112 r1,) = IUniswapV2Pair(p.pool).getReserves();
		(uint256 rIn, uint256 rOut) = IUniswapV2Pair(p.pool).token0() == tokenIn ? (r0, r1) : (r1, r0);
		uint256 inWithFee = amountIn * 997;
		expectedOut = Math.mulDiv(inWithFee, rOut, rIn * 1000 + inWithFee);
		_approve(tokenIn, TwapListingV2.UNI_V2_ROUTER, amountIn);
		address[] memory path = new address[](2);
		path[0] = tokenIn;
		path[1] = tokenOut;
		try IUniswapV2Router02(TwapListingV2.UNI_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
			amountIn, 0, path, TRADER, block.timestamp
		) {
			return (true, expectedOut);
		} catch {
			return (false, 0);
		}
	}

	function _swapAero(Pool memory p, address tokenIn, address tokenOut, uint256 amountIn)
		internal
		returns (bool, uint256 expectedOut)
	{
		expectedOut = IAerodromeAmountOut(p.pool).getAmountOut(amountIn, tokenIn);
		_approve(tokenIn, TwapListingV2.AERODROME_ROUTER, amountIn);
		IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
		routes[0] = IAerodromeRouter.Route(tokenIn, tokenOut, false, TwapListingV2.AERODROME_POOL_FACTORY);
		try IAerodromeRouter(TwapListingV2.AERODROME_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
			amountIn, 0, routes, TRADER, block.timestamp
		) {
			return (true, expectedOut);
		} catch {
			return (false, 0);
		}
	}

	/// @dev Low-level approve: a non-standard token's approve neither reverts the probe nor needs a bool.
	function _approve(address token, address spender, uint256 amount) internal {
		(bool ok,) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
		ok;
	}

	function _slipstreamRouter(TwapListingRegistryV2.Venue venue) internal pure returns (address) {
		if (venue == TwapListingRegistryV2.Venue.Slipstream) return FundsMainnet.CL_SWAP_ROUTER;
		if (venue == TwapListingRegistryV2.Venue.Slipstream2) return FundsMainnet.CL2_SWAP_ROUTER;
		return TwapListingV2.CL3_SWAP_ROUTER;
	}

	// ─── output ─────────────────────────────────────────────────────────────────

	function _row(Pool memory p, Eval memory e) internal pure {
		string memory head = string.concat(
			'ROW|',
			vm.toString(p.token),
			'|',
			vm.toString(p.quote),
			'|',
			vm.toString(uint256(p.venue)),
			'|',
			vm.toString(int256(p.fee)),
			'|',
			vm.toString(p.pool),
			'|',
			e.outcome
		);
		string memory pool = string.concat(
			'|',
			vm.toString(int256(e.spacing)),
			'|',
			vm.toString(uint256(e.cardinality)),
			'|',
			vm.toString(e.balanceUsd18),
			'|',
			vm.toString(e.reserveUsd18),
			'|',
			vm.toString(e.bandUsd18)
		);
		string memory price = string.concat(
			'|',
			vm.toString(e.twapUsd18),
			'|',
			vm.toString(e.spotUsd18),
			'|',
			vm.toString(int256(e.meanTick)),
			'|',
			vm.toString(int256(e.spotTick)),
			'|',
			vm.toString(e.assetIsToken0),
			'|',
			vm.toString(e.ticksKnown),
			'|',
			vm.toString(e.windowNow),
			'|',
			vm.toString(e.err)
		);
		string memory tax = string.concat(
			'|',
			e.tax,
			'|',
			vm.toString(e.lossBps),
			'|',
			vm.toString(e.thresholdBps),
			'|',
			vm.toString(e.buyTaxBps),
			'|',
			vm.toString(e.sellTaxBps)
		);
		console.log(string.concat(head, pool, price, tax));
	}
}

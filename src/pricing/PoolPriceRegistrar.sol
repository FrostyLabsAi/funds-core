// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ValueInterpreter} from '../core/ValueInterpreter.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {ConcentratedPoolPriceAdapter} from './ConcentratedPoolPriceAdapter.sol';
import {BasicPoolPriceAdapter} from './BasicPoolPriceAdapter.sol';

/// @notice The pool views every supported venue shares.
interface IDexPool {
	function factory() external view returns (address);
	function token0() external view returns (address);
	function token1() external view returns (address);
}

interface IUniswapV3PoolKey {
	function fee() external view returns (uint24);
}

interface ISlipstreamPoolKey {
	function tickSpacing() external view returns (int24);
}

interface IObservationGrowth {
	function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

interface IUniswapV3Factory {
	function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface ISlipstreamFactory {
	function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

interface IAerodromeBasicFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

/// @title PoolPriceRegistrar
/// @notice Owns the ValueInterpreter and lets anyone price a token from its own DEX pool — no
///         list, no keeper. `register(asset, pool)` checks that a known factory (Uniswap v3,
///         Aerodrome's three Slipstream deployments, Aerodrome basic volatile) made the pool, that
///         its other token is an allowed quote (USDC/WETH/cbBTC), and that it holds at least
///         MIN_LIQUIDITY_USD; then it grows a concentrated pool's price history, deploys the
///         asset's price adapter (a minimal clone) and adds it to the VI as a primitive. The
///         caller pays the gas, a few cents.
/// @dev The owner (governance) keeps every other VI admin call through `execute` — Chainlink
///      listings, Veranta pairs, bounds, ownership — and can move any token onto a pool with
///      `setPool` (the migration off the old TWAP registry, or a better pool), with no liquidity
///      check. Which pool prices a token is the registrant's choice among canonical pools; the
///      owner corrects a poor one.
contract PoolPriceRegistrar is Ownable2Step {
	struct Wiring {
		ValueInterpreter valueInterpreter;
		address uniswapV3Factory;
		address[3] slipstreamFactories;
		address aerodromeBasicFactory;
		/// @dev Each must be a VI primitive (its own USD feed), never pool-priced.
		address[] quotes;
	}

	/// @notice Whole USD of pool liquidity (IPoolPriceAdapter.liquidityUsd) a registration needs.
	uint256 public constant MIN_LIQUIDITY_USD = 25_000;
	/// @notice Price-history slots a concentrated pool is grown to: 15 minutes of a swap in every
	///         Base block, ≈ 10M gas from one slot, inside a single transaction's limit. A pool
	///         that fills them faster prices over the shorter history it has.
	uint16 public constant OBSERVATION_SLOTS = 450;
	/// @notice The adapters stamp every answer with the read's own time; staleness is the quote's.
	uint32 public constant HEARTBEAT = 1 hours;
	uint8 private constant MAX_DECIMALS = 38;

	ValueInterpreter public immutable valueInterpreter;
	address public immutable concentratedAdapter;
	address public immutable basicAdapter;
	address public immutable uniswapV3Factory;
	address public immutable slipstreamFactory1;
	address public immutable slipstreamFactory2;
	address public immutable slipstreamFactory3;
	address public immutable aerodromeBasicFactory;

	mapping(address quote => bool) public isQuote;
	/// @notice The adapter this registrar last pointed `asset` at (see poolPricedAdapter).
	mapping(address asset => address) public adapterOf;
	/// @dev Every asset this registrar ever pointed at a pool, once each, in order (the terminal's
	///      market list; one moved to another feed since stays listed — poolPricedAdapter tells).
	address[] internal registeredAssets;

	event Registered(address indexed asset, address indexed pool, address adapter, address indexed registrant);
	event PoolSet(address indexed asset, address indexed pool, address adapter);
	event Executed(bytes data);

	error ZeroAddress();
	error QuoteNotPriced(address quote);
	error AlreadyPriced(address asset);
	error AssetNotInPool(address asset, address pool);
	error QuoteNotAllowed(address quote);
	error UnknownVenue(address factory);
	error NotCanonicalPool(address pool);
	error UnsupportedDecimals(uint8 decimals);
	error NotEnoughLiquidity(uint256 liquidityUsd18);

	constructor(Wiring memory w, address owner_) Ownable(owner_) {
		if (
			address(w.valueInterpreter) == address(0) || w.uniswapV3Factory == address(0)
				|| w.slipstreamFactories[0] == address(0) || w.slipstreamFactories[1] == address(0)
				|| w.slipstreamFactories[2] == address(0) || w.aerodromeBasicFactory == address(0)
		) revert ZeroAddress();

		valueInterpreter = w.valueInterpreter;
		uniswapV3Factory = w.uniswapV3Factory;
		slipstreamFactory1 = w.slipstreamFactories[0];
		slipstreamFactory2 = w.slipstreamFactories[1];
		slipstreamFactory3 = w.slipstreamFactories[2];
		aerodromeBasicFactory = w.aerodromeBasicFactory;
		concentratedAdapter = address(new ConcentratedPoolPriceAdapter());
		basicAdapter = address(new BasicPoolPriceAdapter());

		for (uint256 i; i < w.quotes.length; ++i) {
			(address aggregator,,,) = w.valueInterpreter.getAssetInfo(w.quotes[i]);
			if (aggregator == address(0)) revert QuoteNotPriced(w.quotes[i]);
			isQuote[w.quotes[i]] = true;
		}
	}

	/// @notice Price `asset` from `pool` in the ValueInterpreter. Open to anyone.
	function register(address asset, address pool) external returns (address adapter) {
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		adapter = _deploy(asset, pool);
		uint256 liquidity = IPoolPriceAdapter(adapter).liquidityUsd();
		if (liquidity < MIN_LIQUIDITY_USD * 1e18) revert NotEnoughLiquidity(liquidity);
		_point(asset, adapter);
		emit Registered(asset, pool, adapter, msg.sender);
	}

	/// @notice Price `asset` from `pool`, replacing whatever prices it now. No liquidity check.
	function setPool(address asset, address pool) external onlyOwner returns (address adapter) {
		adapter = _deploy(asset, pool);
		_point(asset, adapter);
		emit PoolSet(asset, pool, adapter);
	}

	/// @notice Governance passthrough: any VI admin call. Reverts bubble up unchanged.
	function execute(bytes calldata data) external onlyOwner returns (bytes memory result) {
		bool ok;
		(ok, result) = address(valueInterpreter).call(data);
		if (!ok) {
			assembly ('memory-safe') {
				revert(add(result, 32), mload(result))
			}
		}
		emit Executed(data);
	}

	/// @notice The adapter that prices `asset` in the VI if it is one of this registrar's, else 0
	///         (never registered, or moved to another feed since).
	function poolPricedAdapter(address asset) external view returns (address) {
		address adapter = adapterOf[asset];
		if (adapter == address(0)) return address(0);
		(address aggregator,,,) = valueInterpreter.getAssetInfo(asset);
		return aggregator == adapter ? adapter : address(0);
	}

	/// @notice Every asset ever registered or moved onto a pool here, once each.
	function getRegisteredAssets() external view returns (address[] memory) {
		return registeredAssets;
	}

	function _point(address asset, address adapter) internal {
		if (adapterOf[asset] == address(0)) registeredAssets.push(asset);
		adapterOf[asset] = adapter;
		valueInterpreter.addPrimitive(asset, adapter, HEARTBEAT);
	}

	function _deploy(address asset, address pool) internal returns (address) {
		address token0 = IDexPool(pool).token0();
		address token1 = IDexPool(pool).token1();
		bool assetIsToken0 = asset == token0;
		if (!assetIsToken0 && asset != token1) revert AssetNotInPool(asset, pool);
		address quote = assetIsToken0 ? token1 : token0;
		if (!isQuote[quote]) revert QuoteNotAllowed(quote);

		address implementation = _canonicalImplementation(pool, token0, token1);
		uint8 assetDecimals = IERC20Metadata(asset).decimals();
		if (assetDecimals > MAX_DECIMALS) revert UnsupportedDecimals(assetDecimals);

		IPoolPriceAdapter.Config memory c = IPoolPriceAdapter.Config({
			valueInterpreter: IValueInterpreter(address(valueInterpreter)),
			pool: pool,
			asset: asset,
			quoteAsset: quote,
			assetIsToken0: assetIsToken0,
			assetDecimals: assetDecimals,
			quoteDecimals: IERC20Metadata(quote).decimals()
		});
		return Clones.cloneWithImmutableArgs(implementation, abi.encode(c));
	}

	/// @dev The adapter implementation for `pool`'s venue, once its factory confirms the pool is
	///      its own; a concentrated pool's price history is grown here.
	function _canonicalImplementation(address pool, address token0, address token1) internal returns (address) {
		address factory = IDexPool(pool).factory();
		address canonical;
		address implementation = concentratedAdapter;
		if (factory == uniswapV3Factory) {
			canonical = IUniswapV3Factory(factory).getPool(token0, token1, IUniswapV3PoolKey(pool).fee());
		} else if (factory == slipstreamFactory1 || factory == slipstreamFactory2 || factory == slipstreamFactory3) {
			canonical = ISlipstreamFactory(factory).getPool(token0, token1, ISlipstreamPoolKey(pool).tickSpacing());
		} else if (factory == aerodromeBasicFactory) {
			canonical = IAerodromeBasicFactory(factory).getPool(token0, token1, false);
			implementation = basicAdapter;
		} else {
			revert UnknownVenue(factory);
		}
		if (canonical != pool) revert NotCanonicalPool(pool);
		if (implementation == concentratedAdapter) IObservationGrowth(pool).increaseObservationCardinalityNext(OBSERVATION_SLOTS);
		return implementation;
	}
}

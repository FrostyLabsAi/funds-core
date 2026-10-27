// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {ValueInterpreter} from '../core/ValueInterpreter.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {
	PoolPriceRegistrar, IDexPool, ISlipstreamPoolKey, IObservationGrowth, ISlipstreamFactory
} from './PoolPriceRegistrar.sol';
import {PoolPriceRegistrarV2} from './PoolPriceRegistrarV2.sol';

/// @title PoolPriceRegistrarV3
/// @notice Registrar V2 plus one venue, Aero (FrostyFi 2026-10-25). Aerodrome and Velodrome merged into Aero on
///         2026-10-22 and most liquidity moved to Aero's CL pools, which registrar V2 refuses (its venue list is
///         immutable: UnknownVenue). Anyone can price a token from its Aero CL pool here, with V2's rules: an approved
///         quote, a canonical pool, $25k of quote-side liquidity, a 30-minute average (ConcentratedPoolPriceAdapter,
///         unchanged — Aero's pools answer observe, slot0, observations and increaseObservationCardinalityNext,
///         checked on Base 2026-10-25).
/// @dev - Owns registrar V2 (Ownable2Step), which keeps owning today's registrar, which keeps owning the VI: this
///        registrar writes a price through V2's `callOldRegistrar` → `execute`. V2 keeps its state and every function
///        (v3/Slipstream/v4 registration, quotes, v4 pool and hook approvals; the keeper's v4 sampler reads it).
///      - New funds are built on this registrar (a fund names its registrar immutably): `poolPricedAdapter` answers for
///        its own tokens first, then V2's (which answers V2's, then today's registrar's), so a fund on V3 treats every
///        long-tail token alike (in-kind redemption, realized-only fees, $25k buys). The v4 views a fund's
///        UniswapV4SwapAdapter reads are V2's, forwarded.
///      - Funds on V2 or today's registrar don't see this registrar's tokens as long-tail (the same "new funds only" as
///        V2's v4 tokens, founder 2026-10-08); on 2026-10-25 no fund was on V2 and the four on today's registrar held
///        about $1 each.
contract PoolPriceRegistrarV3 is Ownable2Step {
	/// @notice Whole USD of quote-side pool liquidity a registration needs (V2's).
	uint256 public constant MIN_LIQUIDITY_USD = 25_000;
	/// @notice Price-history slots a pool is grown to (V2's).
	uint16 public constant OBSERVATION_SLOTS = 450;
	/// @notice The adapters stamp every answer with the read's own time; staleness is the quote's (V2's).
	uint32 public constant HEARTBEAT = 1 hours;
	uint8 private constant MAX_DECIMALS = 38;

	PoolPriceRegistrarV2 public immutable registrarV2;
	ValueInterpreter public immutable valueInterpreter;
	/// @notice Aero's CL factory (Base 0x9CB220581b91b0C83223012FE69688b92aD07a76): getPool(token0, token1, tickSpacing).
	address public immutable aeroFactory;
	/// @notice V2's (today's registrar's) ConcentratedPoolPriceAdapter implementation, cloned per token.
	address public immutable concentratedAdapter;

	/// @notice The adapter this registrar last pointed `asset` at (see poolPricedAdapter).
	mapping(address asset => address) public adapterOf;
	address[] internal registeredAssets;

	event Registered(address indexed asset, address indexed pool, address adapter, address indexed registrant);
	event PoolSet(address indexed asset, address indexed pool, address adapter);

	error ZeroAddress();
	error AlreadyPriced(address asset);
	error AssetNotInPool(address asset);
	error QuoteNotAllowed(address quote);
	error NotAeroPool(address factory);
	error NotCanonicalPool(address pool);
	error UnsupportedDecimals(uint8 decimals);
	error NotEnoughLiquidity(uint256 liquidityUsd18);
	error QuoteIsPoolPriced(address quote);
	error UseSetQuote();

	constructor(PoolPriceRegistrarV2 registrarV2_, address aeroFactory_, address owner_) Ownable(owner_) {
		if (address(registrarV2_) == address(0) || aeroFactory_ == address(0)) revert ZeroAddress();
		registrarV2 = registrarV2_;
		valueInterpreter = registrarV2_.valueInterpreter();
		aeroFactory = aeroFactory_;
		concentratedAdapter = registrarV2_.concentratedAdapter();
	}

	// ─── Registration (anyone) ───────────────────────────────────────────────────

	/// @notice Price `asset` from its Aero CL pool against an approved quote (V2's list).
	function register(address asset, address pool) external returns (address adapter) {
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		adapter = _deploy(asset, pool);
		uint256 liquidity = IPoolPriceAdapter(adapter).liquidityUsd();
		if (liquidity < MIN_LIQUIDITY_USD * 1e18) revert NotEnoughLiquidity(liquidity);
		_point(asset, adapter);
		emit Registered(asset, pool, adapter, msg.sender);
	}

	// ─── Owner ───────────────────────────────────────────────────────────────────

	/// @notice Re-price `asset` from an Aero CL pool (a correction); no liquidity check.
	function setPool(address asset, address pool) external onlyOwner returns (address adapter) {
		adapter = _deploy(asset, pool);
		_point(asset, adapter);
		emit PoolSet(asset, pool, adapter);
	}

	/// @notice Take over registrar V2 after its owner proposed this contract (Ownable2Step).
	function acceptRegistrarV2() external onlyOwner {
		registrarV2.acceptOwnership();
	}

	/// @notice Approve (or revoke) a quote token on V2's list (the one both registrars price against). A pool-priced
	///         token is refused here too: V2's own check (QuoteIsPoolPriced) can't see the tokens this registrar prices
	///         from Aero (review 2026-10-25), and a pool-priced quote would chain one pool price onto another.
	function setQuote(address token, bool approved) external onlyOwner {
		if (approved && _poolPricedAdapter(token) != address(0)) revert QuoteIsPoolPriced(token);
		registrarV2.setQuote(token, approved);
	}

	/// @notice Governance passthrough to registrar V2 — `setPoolApproved`, `setHook`, `setPoolApprover`, `setPool(V4)`,
	///         `callOldRegistrar` (Chainlink and Veranta listings, any VI admin call), `transferOwnership`. Reverts bubble
	///         up unchanged. Quotes go through this registrar's own setQuote, which sees its tokens.
	function callRegistrarV2(bytes calldata data) external onlyOwner returns (bytes memory result) {
		if (data.length >= 4 && bytes4(data[:4]) == PoolPriceRegistrarV2.setQuote.selector) revert UseSetQuote();
		bool ok;
		(ok, result) = address(registrarV2).call(data);
		if (!ok) {
			assembly ('memory-safe') {
				revert(add(result, 32), mload(result))
			}
		}
	}

	/// @notice V2's `callOldRegistrar` (today's registrar's `execute`: any VI admin call), one hop further. Same
	///         signature as V2's, so the listing scripts (ListingModuleBook, list-*-stocks.sh, ClmFundsDeploy) send the
	///         same call to whichever of V2 and V3 the deployer owns — without it each would revert
	///         OwnableUnauthorizedAccount(deployer) once V2 is handed over (as on 2026-10-09, health line 8).
	function callOldRegistrar(bytes calldata data) external onlyOwner returns (bytes memory) {
		return registrarV2.callOldRegistrar(data);
	}

	// ─── Views ───────────────────────────────────────────────────────────────────

	/// @notice The adapter that prices `asset` if it is pool-priced here, on V2 or on today's registrar, else 0.
	function poolPricedAdapter(address asset) external view returns (address) {
		return _poolPricedAdapter(asset);
	}

	function _poolPricedAdapter(address asset) internal view returns (address) {
		address adapter = adapterOf[asset];
		if (adapter != address(0)) {
			(address aggregator,,,) = valueInterpreter.getAssetInfo(asset);
			if (aggregator == adapter) return adapter;
		}
		return registrarV2.poolPricedAdapter(asset);
	}

	/// @notice V2's quote list (set through callRegistrarV2).
	function isQuote(address token) external view returns (bool) {
		return registrarV2.isQuote(token);
	}

	/// @notice V2's v4 pool approvals (read by UniswapV4SwapAdapter).
	function isPoolApproved(bytes32 poolId) external view returns (bool) {
		return registrarV2.isPoolApproved(poolId);
	}

	/// @notice V2's v4 hook approvals (read by UniswapV4SwapAdapter).
	function isHookAllowed(address hook) external view returns (bool) {
		return registrarV2.isHookAllowed(hook);
	}

	/// @notice V2's v4 hook approval and hookData (read by UniswapV4SwapAdapter).
	function hookOf(address hook) external view returns (bool approved, bytes memory hookData) {
		return registrarV2.hookOf(hook);
	}

	// V2's venue factories and WETH, forwarded: funds-keeper's USDC exit reads them off a fund's registrar to find the
	// pools it sells on (src/protect/usdc-exit.ts venuePools, longTailRoute, viaWethRoute) — without them it couldn't
	// raise USDC for any fund built on V3 (review 2026-10-25, Critical).

	function uniswapV3Factory() external view returns (address) {
		return registrarV2.uniswapV3Factory();
	}

	function slipstreamFactory1() external view returns (address) {
		return registrarV2.slipstreamFactory1();
	}

	function slipstreamFactory2() external view returns (address) {
		return registrarV2.slipstreamFactory2();
	}

	function slipstreamFactory3() external view returns (address) {
		return registrarV2.slipstreamFactory3();
	}

	function aerodromeBasicFactory() external view returns (address) {
		return registrarV2.aerodromeBasicFactory();
	}

	function weth() external view returns (address) {
		return registrarV2.weth();
	}

	/// @notice The v4 pool V2 prices `asset` from (the keeper sells a v4 token there) — empty while V3's own Aero
	///         price is the live one: V3's setPool can't clear V2's key the way V2's own setPool does.
	function v4KeyOf(address asset)
		external
		view
		returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
	{
		address own = adapterOf[asset];
		if (own != address(0)) {
			(address aggregator,,,) = valueInterpreter.getAssetInfo(asset);
			if (aggregator == own) return (address(0), address(0), 0, 0, address(0));
		}
		return registrarV2.v4KeyOf(asset);
	}

	/// @notice Every asset registered on today's registrar, V2 and here (a token re-pointed across them may repeat).
	function getRegisteredAssets() external view returns (address[] memory all) {
		address[] memory older = registrarV2.getRegisteredAssets();
		all = new address[](older.length + registeredAssets.length);
		for (uint256 i; i < older.length; ++i) {
			all[i] = older[i];
		}
		for (uint256 i; i < registeredAssets.length; ++i) {
			all[older.length + i] = registeredAssets[i];
		}
	}

	// ─── Internals ───────────────────────────────────────────────────────────────

	function _point(address asset, address adapter) internal {
		if (adapterOf[asset] == address(0)) registeredAssets.push(asset);
		adapterOf[asset] = adapter;
		bytes memory listing = abi.encodeCall(ValueInterpreter.addPrimitive, (asset, adapter, HEARTBEAT));
		registrarV2.callOldRegistrar(abi.encodeCall(PoolPriceRegistrar.execute, (listing)));
	}

	/// @dev V2's pool checks (PoolPriceRegistrarV2._deploy) for an Aero CL pool, against V2's quotes.
	function _deploy(address asset, address pool) internal returns (address) {
		address factory = IDexPool(pool).factory();
		if (factory != aeroFactory) revert NotAeroPool(factory);
		address token0 = IDexPool(pool).token0();
		address token1 = IDexPool(pool).token1();
		bool assetIsToken0 = asset == token0;
		if (!assetIsToken0 && asset != token1) revert AssetNotInPool(asset);
		address quote = assetIsToken0 ? token1 : token0;
		if (!registrarV2.isQuote(quote)) revert QuoteNotAllowed(quote);
		if (ISlipstreamFactory(factory).getPool(token0, token1, ISlipstreamPoolKey(pool).tickSpacing()) != pool) {
			revert NotCanonicalPool(pool);
		}
		uint8 assetDecimals = IERC20Metadata(asset).decimals();
		if (assetDecimals > MAX_DECIMALS) revert UnsupportedDecimals(assetDecimals);
		IObservationGrowth(pool).increaseObservationCardinalityNext(OBSERVATION_SLOTS);

		IPoolPriceAdapter.Config memory c = IPoolPriceAdapter.Config({
			valueInterpreter: IValueInterpreter(address(valueInterpreter)),
			pool: pool,
			asset: asset,
			quoteAsset: quote,
			assetIsToken0: assetIsToken0,
			assetDecimals: assetDecimals,
			quoteDecimals: IERC20Metadata(quote).decimals()
		});
		return Clones.cloneWithImmutableArgs(concentratedAdapter, abi.encode(c));
	}
}

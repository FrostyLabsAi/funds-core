// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IValueInterpreter} from '../interfaces/IValueInterpreter.sol';
import {IValueInterpreterAdmin} from '../interfaces/IValueInterpreterAdmin.sol';
import {IPoolPriceAdapter} from '../interfaces/IPoolPriceAdapter.sol';
import {IPoolPriceRegistrar} from '../interfaces/IPoolPriceRegistrar.sol';
import {IV4PriceSampler} from '../interfaces/IV4PriceSampler.sol';
import {IDexPool} from '../interfaces/external/IDexPool.sol';
import {IUniswapV3Pool, ISlipstreamPool, IConcentratedPool} from '../interfaces/external/IConcentratedPool.sol';
import {
	IUniswapV3PoolFactory,
	ISlipstreamPoolFactory,
	IAerodromeBasicFactory
} from '../interfaces/external/IPoolFactories.sol';
import {IV4StateView, PoolKey, PoolKeyId} from '../interfaces/external/IUniswapV4.sol';
import {PoolPriceMath} from '../libraries/PoolPriceMath.sol';
import {ConcentratedPoolPriceAdapter} from './ConcentratedPoolPriceAdapter.sol';
import {BasicPoolPriceAdapter} from './BasicPoolPriceAdapter.sol';
import {V4PoolPriceAdapter} from './V4PoolPriceAdapter.sol';
import {IV4PoolPriceAdapter} from '../interfaces/IV4PoolPriceAdapter.sol';

/// @title PoolPriceRegistrar
/// @notice Owns the ValueInterpreter and lets anyone price a token from its own DEX pool — no list, no keeper.
///         `register(asset, pool)` checks that a known factory made the pool (Uniswap v3, Aerodrome's three Slipstream
///         deployments, Aerodrome basic volatile, Aero CL), that its other token is an approved quote, and that it holds
///         at least MIN_LIQUIDITY_USD; then it grows a concentrated pool's price history, deploys the asset's price
///         adapter (a minimal clone) and adds it to the VI as a primitive. The caller pays the gas, a few cents.
///         Uniswap v4 pools (keeper-sampled history, V4PoolPriceAdapter) register the same way once approved
///         (`registerV4`). Quotes are USDC/WETH/cbBTC plus Chainlink-priced stock tokens, so memestocks paired against
///         the stock itself can be priced (spec 2026-10-08 §4.3; founder 2026-10-08).
/// @dev - The owner (governance) keeps every other VI admin call through `execute` — Chainlink listings, Veranta
///        pairs, bounds, ownership — and can move any token onto a pool with `setPool` / `setPoolV4`, with no liquidity
///        check. Which pool prices a token is the registrant's choice among canonical pools; the owner corrects a poor one.
///      - Every adapter's ≈ $0 rule reads the window's liquidity, not the pool's balance now (red-team PRICING-POOL-01,
///        2026-10-27).
///      - A v4 pool is registered (and traded by the v4 swap adapter) only once it is approved by its PoolId — by the
///        owner or a pool approver (founder 2026-10-08: the Admin Safe, so approvals don't wait for the timelock). v4
///        keeps a pool's tokens in the PoolManager, so its liquidity can't be capped by a balance as on v3: a one-tick
///        position holding no quote token, or liquidity added for one call, passes a liquidity check (final review
///        2026-10-08, H1), and an open registration would let a manager list and sell his own token to his fund.
///        Approval is the gate; the $25k check stays as a second one.
///      - A v4 pool with a hook also needs the owner's approval of that hook; hookData is the bytes the v4 swap adapter
///        passes to it (o1: the Treasury as referrer), never chosen by a fund manager.
///      - The venue factories and WETH are public: funds-keeper's USDC exit reads them off a fund's registrar to find
///        the pools it sells on (review 2026-10-25, Critical).
contract PoolPriceRegistrar is IPoolPriceRegistrar, Ownable2Step {
	struct Wiring {
		IValueInterpreterAdmin valueInterpreter;
		address uniswapV3Factory;
		address[3] slipstreamFactories;
		address aerodromeBasicFactory;
		/// @dev Aero's CL factory (Base 0x9CB220581b91b0C83223012FE69688b92aD07a76): getPool(token0, token1, tickSpacing).
		address aeroFactory;
		IV4StateView stateView;
		/// @dev Uniswap v4's PoolManager (shown as the v4 adapters' `config().pool`).
		address poolManager;
		IV4PriceSampler sampler;
		/// @dev Native ETH in a v4 pool is quoted as WETH.
		address weth;
		/// @dev Each must be a VI primitive (its own USD feed), never pool-priced.
		address[] quotes;
	}

	struct HookApproval {
		bool approved;
		bytes hookData;
	}

	/// @inheritdoc IPoolPriceRegistrar
	uint256 public constant MIN_LIQUIDITY_USD = 25_000;
	/// @notice Price-history slots a concentrated pool is grown to: 15 minutes of a swap in every Base block, ≈ 10M gas
	///         from one slot, inside a single transaction's limit. A pool that fills them faster prices over the shorter
	///         history it has.
	uint16 public constant OBSERVATION_SLOTS = 450;
	/// @notice The adapters stamp every answer with the read's own time; staleness is the quote's.
	uint32 public constant HEARTBEAT = 1 hours;
	uint8 private constant MAX_DECIMALS = 38;
	/// @notice The most sale tax the owner may record for a pool (hard rule 5): the keeper's liquidation cap rises by
	///         at most this much.
	uint16 public constant MAX_SALE_TAX_BPS = 500;

	IValueInterpreterAdmin public immutable valueInterpreter;
	IV4StateView public immutable stateView;
	address public immutable poolManager;
	IV4PriceSampler public immutable sampler;
	address public immutable weth;
	address public immutable concentratedAdapter;
	address public immutable basicAdapter;
	address public immutable v4Adapter;
	address public immutable uniswapV3Factory;
	address public immutable slipstreamFactory1;
	address public immutable slipstreamFactory2;
	address public immutable slipstreamFactory3;
	address public immutable aerodromeBasicFactory;
	address public immutable aeroFactory;

	mapping(address quote => bool) public isQuote;
	mapping(address hook => HookApproval) internal _hooks;
	/// @notice The adapter this registrar last pointed `asset` at (see poolPricedAdapter).
	mapping(address asset => address) public adapterOf;
	/// @notice The v4 pool a v4-priced asset is read from (zero key for other venues).
	mapping(address asset => PoolKey) public v4KeyOf;
	/// @inheritdoc IPoolPriceRegistrar
	mapping(bytes32 poolId => bool) public isPoolApproved;
	/// @notice Who may approve or revoke v4 pools besides the owner. That is all they can do: an approval lets anyone
	///         register the pool and funds trade it, under every other rule; it moves nothing and changes no setting.
	mapping(address approver => bool) public isPoolApprover;
	/// @inheritdoc IPoolPriceRegistrar
	mapping(bytes32 poolId => uint16) public poolSaleTaxBps;
	/// @dev Every asset this registrar ever pointed at a pool, once each, in order (the terminal's market list; one moved
	///      to another feed since stays listed — poolPricedAdapter tells).
	address[] internal registeredAssets;

	event Registered(address indexed asset, address indexed pool, address adapter, address indexed registrant);
	event RegisteredV4(address indexed asset, bytes32 indexed poolId, address adapter, address indexed registrant);
	event PoolSet(address indexed asset, address indexed pool, address adapter);
	event PoolSetV4(address indexed asset, bytes32 indexed poolId, address adapter);
	event HookSet(address indexed hook, bool approved, bytes hookData);
	event QuoteSet(address indexed quote, bool approved);
	event PoolSaleTaxSet(bytes32 indexed poolId, uint16 taxBps);
	event PoolApproved(bytes32 indexed poolId, bool approved, address indexed by);
	event PoolApproverSet(address indexed approver, bool allowed);
	event Executed(bytes data);

	error ZeroAddress();
	error QuoteNotPriced(address quote);
	error QuoteIsPoolPriced(address quote);
	error QuoteNotAllowed(address quote);
	error HookNotApproved(address hook);
	error AlreadyPriced(address asset);
	error AssetNotInPool(address asset);
	error PoolNotInitialized(bytes32 poolId);
	error UnknownVenue(address factory);
	error NotCanonicalPool(address pool);
	error UnsupportedDecimals(uint8 decimals);
	error NotEnoughLiquidity(uint256 liquidityUsd18);
	error PoolNotApproved(bytes32 poolId);
	error NotPoolApprover(address caller);
	error SaleTaxTooHigh(uint16 taxBps);

	constructor(Wiring memory w, address owner_) Ownable(owner_) {
		if (
			address(w.valueInterpreter) == address(0) || w.uniswapV3Factory == address(0)
				|| w.slipstreamFactories[0] == address(0) || w.slipstreamFactories[1] == address(0)
				|| w.slipstreamFactories[2] == address(0) || w.aerodromeBasicFactory == address(0)
				|| w.aeroFactory == address(0) || address(w.stateView) == address(0) || w.poolManager == address(0)
				|| address(w.sampler) == address(0) || w.weth == address(0)
		) revert ZeroAddress();
		valueInterpreter = w.valueInterpreter;
		uniswapV3Factory = w.uniswapV3Factory;
		slipstreamFactory1 = w.slipstreamFactories[0];
		slipstreamFactory2 = w.slipstreamFactories[1];
		slipstreamFactory3 = w.slipstreamFactories[2];
		aerodromeBasicFactory = w.aerodromeBasicFactory;
		aeroFactory = w.aeroFactory;
		stateView = w.stateView;
		poolManager = w.poolManager;
		sampler = w.sampler;
		weth = w.weth;
		concentratedAdapter = address(new ConcentratedPoolPriceAdapter());
		basicAdapter = address(new BasicPoolPriceAdapter());
		v4Adapter = address(new V4PoolPriceAdapter());
		for (uint256 i; i < w.quotes.length; ++i) {
			_setQuote(w.quotes[i], true);
		}
	}

	// ─── Registration (anyone) ───────────────────────────────────────────────────

	/// @notice Price `asset` from a Uniswap v3, Slipstream, Aerodrome basic or Aero CL pool against an approved quote.
	function register(address asset, address pool) external returns (address adapter) {
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		adapter = _deploy(asset, pool);
		uint256 liquidity = IPoolPriceAdapter(adapter).liquidityUsd();
		if (liquidity < MIN_LIQUIDITY_USD * 1e18) revert NotEnoughLiquidity(liquidity);
		// a token delisted from its v4 pool and registered here keeps no v4 key: the keeper sells where it is priced
		delete v4KeyOf[asset];
		_point(asset, adapter);
		emit Registered(asset, pool, adapter, msg.sender);
	}

	/// @notice Price `asset` from its approved Uniswap v4 pool `key`. Open to anyone once the pool is approved; the price
	///         reads once the keeper has taken four samples (≈ 40 minutes), and nobody can buy before.
	function registerV4(address asset, PoolKey calldata key) external returns (address adapter) {
		if (valueInterpreter.isSupportedAsset(asset)) revert AlreadyPriced(asset);
		bytes32 id = PoolKeyId.toId(key);
		if (!isPoolApproved[id]) revert PoolNotApproved(id);
		(adapter,) = _deployV4(asset, key, true);
		_pointV4(asset, key, adapter);
		emit RegisteredV4(asset, id, adapter, msg.sender);
	}

	// ─── Pool approvers (and the owner) ──────────────────────────────────────────

	/// @notice Approve (or revoke) v4 pool `poolId` for registration and v4 trading. Revoking stops new registrations and
	///         v4 trades in it; a token already priced from it keeps its price.
	function setPoolApproved(bytes32 poolId, bool approved) external {
		if (msg.sender != owner() && !isPoolApprover[msg.sender]) revert NotPoolApprover(msg.sender);
		isPoolApproved[poolId] = approved;
		emit PoolApproved(poolId, approved, msg.sender);
	}

	// ─── Owner ───────────────────────────────────────────────────────────────────

	/// @notice Re-price `asset` from a v3, Slipstream, Aerodrome basic or Aero CL pool (a correction); no liquidity check.
	function setPool(address asset, address pool) external onlyOwner returns (address adapter) {
		adapter = _deploy(asset, pool);
		delete v4KeyOf[asset];
		_point(asset, adapter);
		emit PoolSet(asset, pool, adapter);
	}

	/// @notice Re-price `asset` from v4 pool `key` (a correction); no liquidity check. The owner choosing the pool
	///         approves it.
	function setPoolV4(address asset, PoolKey calldata key) external onlyOwner returns (address adapter) {
		bytes32 id = PoolKeyId.toId(key);
		(adapter,) = _deployV4(asset, key, false);
		_pointV4(asset, key, adapter);
		if (!isPoolApproved[id]) {
			isPoolApproved[id] = true;
			emit PoolApproved(id, true, msg.sender);
		}
		emit PoolSetV4(asset, id, adapter);
	}

	/// @notice Let `approver` approve and revoke v4 pools (or stop it).
	function setPoolApprover(address approver, bool allowed) external onlyOwner {
		if (approver == address(0)) revert ZeroAddress();
		isPoolApprover[approver] = allowed;
		emit PoolApproverSet(approver, allowed);
	}

	/// @notice Approve (or revoke) a v4 hook; `hookData` is what the v4 swap adapter passes it on every swap.
	function setHook(address hook, bool approved, bytes calldata hookData) external onlyOwner {
		if (hook == address(0)) revert ZeroAddress();
		_hooks[hook] = HookApproval({approved: approved, hookData: hookData});
		emit HookSet(hook, approved, hookData);
	}

	/// @notice Record the fixed tax a sale through v4 pool `poolId` pays (its hook's), in bps of what is sold, so the keeper
	///         can liquidate its token: a keeper sale through that pool may lose MAX_LIQUIDATION_LOSS_BPS plus this
	///         (founder 2026-11-15: a STFY or FROSTY sale costs over the 3% cap at any size, so an overdue exit could
	///         never sell it). Per pool, not per token: a sale of the same token on an untaxed pool keeps the plain cap.
	///         The manager's trades and their slippage budget are unchanged: a tax still counts there.
	function setPoolSaleTax(bytes32 poolId, uint16 taxBps) external onlyOwner {
		if (poolId == bytes32(0)) revert ZeroAddress();
		if (taxBps > MAX_SALE_TAX_BPS) revert SaleTaxTooHigh(taxBps);
		poolSaleTaxBps[poolId] = taxBps;
		emit PoolSaleTaxSet(poolId, taxBps);
	}

	/// @notice Approve (or revoke) a quote token: it must have its own VI price and not be pool-priced.
	function setQuote(address token, bool approved) external onlyOwner {
		_setQuote(token, approved);
	}

	/// @notice Take over the ValueInterpreter after its owner proposed this contract (Ownable2Step).
	function acceptValueInterpreter() external onlyOwner {
		valueInterpreter.acceptOwnership();
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

	// ─── Views ───────────────────────────────────────────────────────────────────

	/// @inheritdoc IPoolPriceRegistrar
	function poolPricedAdapter(address asset) external view returns (address) {
		return _poolPricedAdapter(asset);
	}

	/// @inheritdoc IPoolPriceRegistrar
	function hookOf(address hook) external view returns (bool approved, bytes memory hookData) {
		HookApproval storage h = _hooks[hook];
		return (h.approved, h.hookData);
	}

	/// @inheritdoc IPoolPriceRegistrar
	function isHookAllowed(address hook) public view returns (bool) {
		return hook == address(0) || _hooks[hook].approved;
	}

	/// @notice Every asset ever registered or moved onto a pool here, once each.
	function getRegisteredAssets() external view returns (address[] memory) {
		return registeredAssets;
	}

	// ─── Internals ───────────────────────────────────────────────────────────────

	/// @dev The adapter that prices `asset` in the VI if it is one of this registrar's, else 0 (never registered, or moved
	///      to another feed since).
	function _poolPricedAdapter(address asset) internal view returns (address) {
		address adapter = adapterOf[asset];
		if (adapter == address(0)) return address(0);
		(address aggregator,,,) = valueInterpreter.getAssetInfo(asset);
		return aggregator == adapter ? adapter : address(0);
	}

	function _setQuote(address token, bool approved) internal {
		if (approved) {
			(address aggregator,,,) = valueInterpreter.getAssetInfo(token);
			if (aggregator == address(0)) revert QuoteNotPriced(token);
			if (_poolPricedAdapter(token) != address(0)) revert QuoteIsPoolPriced(token);
		}
		isQuote[token] = approved;
		emit QuoteSet(token, approved);
	}

	function _point(address asset, address adapter) internal {
		if (adapterOf[asset] == address(0)) registeredAssets.push(asset);
		adapterOf[asset] = adapter;
		valueInterpreter.addPrimitive(asset, adapter, HEARTBEAT);
	}

	function _pointV4(address asset, PoolKey calldata key, address adapter) internal {
		v4KeyOf[asset] = key;
		_point(asset, adapter);
	}

	function _deploy(address asset, address pool) internal returns (address) {
		address token0 = IDexPool(pool).token0();
		address token1 = IDexPool(pool).token1();
		bool assetIsToken0 = asset == token0;
		if (!assetIsToken0 && asset != token1) revert AssetNotInPool(asset);
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

	/// @dev The adapter implementation for `pool`'s venue, once its factory confirms the pool is its own; a concentrated
	///      pool's price history is grown here.
	function _canonicalImplementation(address pool, address token0, address token1) internal returns (address) {
		address factory = IDexPool(pool).factory();
		address canonical;
		address implementation = concentratedAdapter;
		if (factory == uniswapV3Factory) {
			canonical = IUniswapV3PoolFactory(factory).getPool(token0, token1, IUniswapV3Pool(pool).fee());
		} else if (
			factory == slipstreamFactory1 || factory == slipstreamFactory2 || factory == slipstreamFactory3
				|| factory == aeroFactory
		) {
			canonical = ISlipstreamPoolFactory(factory).getPool(token0, token1, ISlipstreamPool(pool).tickSpacing());
		} else if (factory == aerodromeBasicFactory) {
			canonical = IAerodromeBasicFactory(factory).getPool(token0, token1, false);
			implementation = basicAdapter;
		} else {
			revert UnknownVenue(factory);
		}
		if (canonical != pool) revert NotCanonicalPool(pool);
		if (implementation == concentratedAdapter) {
			IConcentratedPool(pool).increaseObservationCardinalityNext(OBSERVATION_SLOTS);
		}
		return implementation;
	}

	/// @dev Checks the pool and deploys the asset's v4 price clone; with `checkLiquidity`, refuses under $25k measured on
	///      the pool right now (no samples exist yet).
	function _deployV4(address asset, PoolKey calldata key, bool checkLiquidity)
		internal
		returns (address adapter, bytes32 id)
	{
		id = PoolKeyId.toId(key);
		(uint160 sqrtPriceX96,,,) = stateView.getSlot0(id);
		if (sqrtPriceX96 == 0) revert PoolNotInitialized(id);
		if (asset == address(0) || (asset != key.currency0 && asset != key.currency1)) revert AssetNotInPool(asset);
		bool assetIsToken0 = asset == key.currency0;
		address quoteCurrency = assetIsToken0 ? key.currency1 : key.currency0;
		address quote = quoteCurrency == address(0) ? weth : quoteCurrency;
		if (!isQuote[quote]) revert QuoteNotAllowed(quote);
		if (!isHookAllowed(key.hooks)) revert HookNotApproved(key.hooks);
		uint8 assetDecimals = IERC20Metadata(asset).decimals();
		if (assetDecimals > MAX_DECIMALS) revert UnsupportedDecimals(assetDecimals);
		uint8 quoteDecimals = IERC20Metadata(quote).decimals();

		if (checkLiquidity) {
			uint256 reserve = PoolPriceMath.quoteReserve(stateView.getLiquidity(id), sqrtPriceX96, assetIsToken0);
			uint256 liquidity = Math.mulDiv(reserve, valueInterpreter.calcUsdRate(quote), 10 ** quoteDecimals);
			if (liquidity < MIN_LIQUIDITY_USD * 1e18) revert NotEnoughLiquidity(liquidity);
		}

		IPoolPriceAdapter.Config memory c = IPoolPriceAdapter.Config({
			valueInterpreter: IValueInterpreter(address(valueInterpreter)),
			pool: poolManager,
			asset: asset,
			quoteAsset: quote,
			assetIsToken0: assetIsToken0,
			assetDecimals: assetDecimals,
			quoteDecimals: quoteDecimals
		});
		IV4PoolPriceAdapter.V4Extra memory e = IV4PoolPriceAdapter.V4Extra({sampler: sampler, stateView: stateView, poolId: id});
		adapter = Clones.cloneWithImmutableArgs(v4Adapter, abi.encode(c, e));
	}
}

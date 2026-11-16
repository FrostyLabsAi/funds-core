// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/ComptrollerBlueprintDeployer.sol';
import {SharesVaultDeployer} from '../../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IShares} from '../../src/interfaces/IShares.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../../src/adapters/UniswapV3SwapAdapter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {RegistrarFixture} from '../utils/RegistrarFixture.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {CumulativeSlippageTolerancePolicy} from '../../src/policies/CumulativeSlippageTolerancePolicy.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {MockERC20, MockAggregator, MockSwapRouter} from '../utils/Mocks.sol';
import {MockPerpAccountFactory} from '../utils/MockRedemptionQueue.sol';
import {MockUnwindPosition, MockUnwindPositionFactory} from '../utils/MockUnwindPosition.sol';
import {ScriptedCLPool, MockUniswapV3Factory, MockSlipstreamFactory, MockAerodromeBasicFactory} from '../utils/PoolPriceMocks.sol';

/// @notice Theft rules for fund v6 (founder 2026-11-04: "the worst possible thing that could happen is an attacker finding an
///         exploit in the contracts and draining funds"). The real Comptroller, RedemptionQueue, Vault, Shares, ValueInterpreter,
///         windowed registrar and mandatory policies, on mock tokens, feeds, a scripted pool and a router that pays what it's told.
///         Run on a copy of the repo, one target at a time, because it rewrites crytic-export and fills medusa-corpus:
///         medusa fuzz --config medusa.json --target-contracts OutsiderTheft (or ManagerTheft, FloorTheft, WaitRules)
///         Medusa can't parse a library function with a dotted type in its ABI (IPolicy.PolicyHook, in ComptrollerLib). So first,
///         once: run crytic-compile with medusa.json's two args and --export-format solc, drop every ABI entry with an input or output type
///         containing a dot from crytic-export/combined_solc.json, keep the file outside the copy, and put a crytic-compile first on PATH
///         that only copies it back into crytic-export.
interface IHevm {
	function warp(uint256) external;
}

/// @dev Every investor, attacker, manager and keeper is one of these, so nothing here needs a prank.
contract Actor {
	function run(address to, bytes calldata data) external returns (bool ok, bytes memory ret) {
		(ok, ret) = to.call(data);
	}
}

abstract contract TheftWorld {
	IHevm internal constant vm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
	uint256 internal constant UNWIND_TYPE = 99;
	uint128 internal constant PLENTY = 1_000_000e6;
	uint256 internal constant BUDGET_BPS = 500;
	uint256 internal constant LINE_BPS = 10;
	uint256 internal constant MAX_DEPOSIT = 2_000_000e6;

	ValueInterpreter internal vi;
	PoolPriceRegistrar internal registrar;
	FundFactory internal factory;
	RedemptionQueue internal queue;
	CumulativeSlippageTolerancePolicy internal slippage;
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal adapter;
	ScriptedCLPool internal pool;
	Comptroller internal fund;
	IShares internal shares;
	address internal vault;

	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal stk; // a stock: 5-day heartbeat, so a closed market shows
	MockERC20 internal tkn; // long-tail, priced from `pool`
	MockAggregator internal usdcFeed;
	MockAggregator internal wethFeed;
	MockAggregator internal stkFeed;
	uint256 internal wethPx = 2000e6;
	uint256 internal stkPx = 100e6;

	Actor internal manager;
	Actor internal keeper;
	Actor internal alice;
	Actor internal bob;
	Actor internal eve;
	Actor[] internal investors;

	uint256 internal clock = 30 days;
	uint256 internal startClock;
	uint256 internal ops;
	uint256 internal supplyOffset;
	uint256 internal sharesDonatedToQueue;
	uint256 internal usdcDonatedToFund;
	mapping(address => uint256) internal minted;
	uint256 internal priceRounding;

	modifier step() {
		vm.warp(clock);
		++ops;
		_;
		_afterStep();
	}

	function _afterStep() internal virtual {}

	function _build(uint16 perfBps) internal {
		vm.warp(clock);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		stk = new MockERC20('Stock', 'STK', 8);
		tkn = new MockERC20('Token', 'TKN', 6);
		usdcFeed = new MockAggregator(8, 1e8);
		wethFeed = new MockAggregator(8, 2000e8);
		stkFeed = new MockAggregator(8, 100e8);
		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(address(usdc), address(usdcFeed), 25 hours);
		vi.addPrimitive(address(weth), address(wethFeed), 25 hours);
		vi.addPrimitive(address(stk), address(stkFeed), 5 days);

		MockUniswapV3Factory uniswap = new MockUniswapV3Factory();
		address[] memory quotes = new address[](1);
		quotes[0] = address(usdc);
		registrar = RegistrarFixture.deploy(
			address(vi), address(uniswap), [address(new MockSlipstreamFactory()), address(new MockSlipstreamFactory()), address(new MockSlipstreamFactory())], address(new MockAerodromeBasicFactory()), quotes, address(this)
		);
		vi.transferOwnership(address(registrar));
		registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
		pool = new ScriptedCLPool(address(tkn), address(usdc), address(uniswap), 3000, 60);
		pool.setHistory(2 days);
		pool.setOracle(0, PLENTY);
		usdc.mint(address(pool), 1_000_000e6);
		uniswap.setPool(address(tkn), address(usdc), 3000, address(pool));
		registrar.register(address(tkn), address(pool));

		queue = new RedemptionQueue(address(this));
		factory = new FundFactory(
			vi,
			new ComptrollerBlueprintDeployer(
				type(Comptroller).creationCode,
				abi.encode(PoolPriceRegistrar(address(registrar)), queue, new MockPerpAccountFactory(IERC20(address(usdc))))
			),
			new SharesVaultDeployer()
		);
		queue.setFactory(address(factory));
		router = new MockSwapRouter();
		adapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)), address(0xFEE), 0, address(this));
		factory.registerAdapter(address(adapter));
		slippage = new CumulativeSlippageTolerancePolicy(BUDGET_BPS);
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](3);
		mandatory[0] = FundFactory.PolicyReg({
			hook: IPolicy.PolicyHook.PostCallOnIntegration,
			policy: address(new MinPoolLiquidityPolicy(PoolPriceRegistrar(address(registrar))))
		});
		mandatory[1] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(slippage)});
		mandatory[2] = FundFactory.PolicyReg({hook: IPolicy.PolicyHook.PostCallOnExternalPosition, policy: address(slippage)});
		factory.setMandatoryPolicies(mandatory);
		factory.registerPositionType(UNWIND_TYPE, address(new MockUnwindPositionFactory(IERC20(address(usdc)))));

		manager = new Actor();
		keeper = new Actor();
		alice = new Actor();
		bob = new Actor();
		eve = new Actor();
		queue.setKeeper(address(keeper), true);
		investors.push(alice);
		investors.push(bob);
		investors.push(eve);
		fund = Comptroller(
			factory.createFund(
				FundFactory.FundConfig({
					name: 'Theft Rules',
					symbol: 'TR',
					denominationAsset: IERC20(address(usdc)),
					fundOwner: address(manager),
					mgmtScaledPerSecondRate: 0,
					perfFeeBps: perfBps,
					sharesActionTimelock: 0,
					minRequestDuration: 1 minutes,
					executionWindow: 1 days,
					allowRiskyAssets: false
				})
			)
		);
		shares = fund.shares();
		vault = address(fund.vault());
		_approveAll(alice);
		_approveAll(bob);
		_approveAll(eve);
		_approveAll(manager);
		startClock = clock;
	}

	function _approveAll(Actor a) internal {
		a.run(address(usdc), abi.encodeCall(IERC20.approve, (address(fund), type(uint256).max)));
		a.run(address(shares), abi.encodeCall(IERC20.approve, (address(queue), type(uint256).max)));
	}

	function _seed(Actor a, uint256 amount) internal {
		usdc.mint(address(a), amount);
		a.run(address(fund), abi.encodeCall(Comptroller.requestDeposit, (amount, type(uint256).max)));
		clock += 61;
		vm.warp(clock);
		(bool ok,) = keeper.run(address(fund), abi.encodeCall(Comptroller.executeDepositRequest, (address(a))));
		require(ok, 'seed');
	}

	/// @dev What everyone holds once the world is built is what they start with: the first depositor pays for the bootstrap shares.
	function _baseline() internal {
		uint256 held;
		for (uint256 i; i < investors.length; ++i) {
			(, minted[address(investors[i])]) = _wealth(investors[i]);
			held += shares.balanceOf(address(investors[i]));
		}
		supplyOffset = shares.totalSupply() - held - shares.balanceOf(address(manager));
	}

	function _who(uint256 i) internal view returns (Actor) {
		return investors[i % investors.length];
	}

	function _token(uint256 i) internal view returns (MockERC20) {
		uint256 k = i % 4;
		return k == 0 ? usdc : k == 1 ? weth : k == 2 ? stk : tkn;
	}

	function _px(MockERC20 t) internal view returns (uint256) {
		return t == weth ? wethPx : t == stk ? stkPx : 1e6;
	}

	function _unit(MockERC20 t) internal view returns (uint256) {
		return 10 ** t.decimals();
	}

	function _usd(MockERC20 t, uint256 amount) internal view returns (uint256) {
		return Math.mulDiv(amount, _px(t), _unit(t));
	}

	function _fairOut(MockERC20 tin, MockERC20 tout, uint256 amountIn) internal view returns (uint256) {
		return Math.mulDiv(_usd(tin, amountIn), _unit(tout), _px(tout));
	}

	function _tradeData(MockERC20 tin, MockERC20 tout, uint256 amountIn) internal pure returns (bytes memory) {
		return abi.encode(address(tin), address(tout), uint24(3000), amountIn, uint256(0));
	}

	function _trade(MockERC20 tin, MockERC20 tout, uint256 amountIn, uint256 amountOut) internal returns (bool ok) {
		router.setNextAmountOut(amountOut);
		(ok,) = manager.run(
			address(fund), abi.encodeCall(Comptroller.callOnIntegration, (address(adapter), _tradeData(tin, tout, amountIn)))
		);
	}

	function _gav() internal returns (bool known, uint256 gav) {
		try fund.calcGav() returns (uint256 g) {
			return (true, g);
		} catch {
			return (false, 0);
		}
	}

	/// @dev All an actor owns, in USDC: cash, a deposit in escrow, and its shares (held or queued) at the fund's value.
	function _wealth(Actor a) internal returns (bool known, uint256 wealth) {
		uint256 gav;
		(known, gav) = _gav();
		if (!known) return (false, 0);
		(uint256 escrow,,) = fund.depositRequests(address(a));
		uint256 supply = shares.totalSupply();
		wealth = usdc.balanceOf(address(a)) + escrow;
		if (supply != 0) wealth += Math.mulDiv(gav, _sharesOwned(a), supply);
	}

	function _sharesOwned(Actor a) internal view returns (uint256 owned) {
		(bool exists,, RedemptionQueue.Request memory r) = queue.requestOf(address(fund), address(a));
		owned = shares.balanceOf(address(a));
		if (exists) owned += r.shares;
	}

	function _queued(Actor a) internal view returns (uint256) {
		(bool exists,, RedemptionQueue.Request memory r) = queue.requestOf(address(fund), address(a));
		return exists ? r.shares : 0;
	}

	/// @dev Rounding: at most a couple of USDC wei per action, plus what each deposit's price rounded.
	function _dust() internal view returns (uint256) {
		return 1_000 + ops * 10 + priceRounding;
	}

	// ─── Anyone ──────────────────────────────────────────────────────────────

	function requestDeposit(uint256 who, uint256 amount) public virtual step {
		Actor a = _who(who);
		amount = 1 + amount % MAX_DEPOSIT;
		usdc.mint(address(a), amount);
		minted[address(a)] += amount;
		a.run(address(fund), abi.encodeCall(Comptroller.requestDeposit, (amount, type(uint256).max)));
	}

	function cancelDeposit(uint256 who) public virtual step {
		Actor a = _who(who);
		(uint256 escrow,,) = fund.depositRequests(address(a));
		uint256 before = usdc.balanceOf(address(a));
		(bool ok,) = a.run(address(fund), abi.encodeCall(Comptroller.cancelDepositRequest, ()));
		// "Always available"
		if (escrow != 0) assert(ok && usdc.balanceOf(address(a)) == before + escrow);
	}

	function executeDeposit(uint256 caller, uint256 who) public virtual step {
		uint256 supply = shares.totalSupply();
		(bool ok,) = _who(caller).run(address(fund), abi.encodeCall(Comptroller.executeDepositRequest, (address(_who(who)))));
		// The deposit price rounds down to a whole USDC wei per share, for the depositor. Known and reported; not what these rules look for.
		if (ok) priceRounding += supply / 1e18 + 1;
		_synced();
	}

	function redeemNow(uint256 who, uint256 seed) public virtual step {
		_redeem(_who(who), seed);
		_synced();
	}

	function _redeem(Actor a, uint256 seed) internal returns (bool ok) {
		uint256 balance = shares.balanceOf(address(a));
		if (balance == 0) return false;
		uint256 amount = seed % 2 == 0 ? balance : 1 + seed % balance;
		(bool known, uint256 gav) = _gav();
		uint256 fair = known ? Math.mulDiv(gav, amount, shares.totalSupply()) : type(uint256).max - 2;
		uint256 before = usdc.balanceOf(address(a));
		bytes32 tokens = _tokensHeld();
		(ok,) = a.run(address(fund), abi.encodeCall(Comptroller.redeemShares, (amount)));
		if (!ok) return false;
		assert(_tokensHeld() == tokens); // USDC only, never a token
		assert(usdc.balanceOf(address(a)) - before <= fair + 2); // nobody leaves with more than their share
	}

	function _tokensHeld() internal view returns (bytes32) {
		return keccak256(abi.encode(weth.balanceOf(vault), stk.balanceOf(vault), tkn.balanceOf(vault)));
	}

	function queueRequest(uint256 who, uint256 seed) public virtual step {
		Actor a = _who(who);
		uint256 balance = shares.balanceOf(address(a));
		if (balance == 0) return;
		uint256 amount = seed % 2 == 0 ? balance : 1 + seed % balance;
		a.run(address(queue), abi.encodeCall(RedemptionQueue.requestRedeem, (address(fund), amount)));
		_synced();
	}

	function queueCancel(uint256 who) public virtual step {
		_who(who).run(address(queue), abi.encodeCall(RedemptionQueue.cancel, (address(fund))));
		_synced();
	}

	/// @dev Eve's to give away: Alice handing Eve shares would read as Eve's profit, and Eve handing them to the manager as the manager's.
	function transferShares(uint256 to, uint256 seed) public virtual step {
		uint256 balance = shares.balanceOf(address(eve));
		if (balance == 0 || _who(to) == manager) return;
		eve.run(address(shares), abi.encodeCall(IERC20.transfer, (address(_who(to)), 1 + seed % balance)));
		_synced();
	}

	function advance(uint256 seconds_, bool refresh) public virtual {
		clock += seconds_ % 3 == 0 ? 61 : 1 + seconds_ % 2 days;
		vm.warp(clock);
		++ops;
		if (refresh) _refreshFeeds();
		_afterStep();
	}

	function _refreshFeeds() internal virtual {
		usdcFeed.setAnswer(1e8);
		wethFeed.setAnswer(int256(wethPx * 100));
		stkFeed.setAnswer(int256(stkPx * 100));
	}

	function settleFees() public virtual step {
		eve.run(address(fund), abi.encodeCall(Comptroller.settleFees, ()));
	}

	function keeperSettle(uint256 maxRequests) public virtual step {
		_settle(keeper, maxRequests);
		_synced();
	}

	/// @dev No redeemer is paid more than their shares' part of what the fund is worth.
	function _settle(Actor caller, uint256 maxRequests) internal returns (bool ok) {
		(bool known, uint256 gav) = _gav();
		uint256 supply = shares.totalSupply();
		uint256[] memory cash = new uint256[](investors.length);
		uint256[] memory queued = new uint256[](investors.length);
		for (uint256 i; i < investors.length; ++i) {
			cash[i] = usdc.balanceOf(address(investors[i]));
			queued[i] = _queued(investors[i]);
		}
		(ok,) = caller.run(address(queue), abi.encodeCall(RedemptionQueue.settle, (address(fund), 1 + maxRequests % 5)));
		if (!ok || !known) return ok;
		for (uint256 i; i < investors.length; ++i) {
			uint256 paid = usdc.balanceOf(address(investors[i])) - cash[i];
			// what the queue burned: the manager's fee shares landing in the same settle don't count against it
			uint256 burned = queued[i] - _queued(investors[i]);
			assert(paid <= Math.mulDiv(gav, burned, supply) + 2);
		}
	}

	/// @dev An action an investor took themselves: their shares may have moved.
	function _synced() internal virtual {}
}

/// @notice An outsider against a fund whose prices don't move and whose manager trades fairly. Eve can deposit, leave, queue, donate
///         any token to any contract, and call everything she shouldn't be able to.
contract OutsiderTheft is TheftWorld {
	constructor() {
		_build(0);
		_seed(alice, 100_000e6);
		_seed(bob, 50_000e6);
		require(_trade(usdc, weth, 30_000e6, 15e18) && _trade(usdc, stk, 30_000e6, 300e8) && _trade(usdc, tkn, 100e6, 100e6), 'trades');
		_baseline();
	}

	function eveDonate(uint256 tokenSeed, uint256 amount, uint256 destSeed) public step {
		MockERC20 t = _token(tokenSeed);
		amount = 1 + amount % Math.mulDiv(100_000e6, _unit(t), _px(t));
		uint256 k = destSeed % 3;
		address dest = k == 0 ? vault : k == 1 ? address(fund) : address(queue);
		t.mint(address(eve), amount);
		minted[address(eve)] += _usd(t, amount) + 1;
		(bool ok,) = eve.run(address(t), abi.encodeCall(IERC20.transfer, (dest, amount)));
		if (ok && t == usdc && dest == address(fund)) usdcDonatedToFund += amount;
	}

	function eveDonateShares(uint256 seed) public step {
		uint256 balance = shares.balanceOf(address(eve));
		if (balance == 0) return;
		uint256 amount = 1 + seed % balance;
		(bool ok,) = eve.run(address(shares), abi.encodeCall(IERC20.transfer, (address(queue), amount)));
		if (ok) sharesDonatedToQueue += amount;
	}

	/// @dev Everything only the fund, its manager, the queue, a keeper or the owner may call. None of it may work for Eve.
	function eveAttack(uint256 kind, uint256 seed) public step {
		bytes memory trade = _tradeData(usdc, weth, 1 + seed % 1_000e6);
		address a = address(eve);
		uint256 k = kind % 22;
		address to;
		bytes memory data;
		if (k == 0) (to, data) = (vault, abi.encodeWithSignature('withdraw(address,address,uint256)', address(usdc), a, 1 + seed % 1_000e6));
		else if (k == 1) (to, data) = (address(shares), abi.encodeWithSignature('mint(address,uint256)', a, 1 + seed % 1e24));
		else if (k == 2) (to, data) = (address(shares), abi.encodeWithSignature('burn(address,uint256)', address(alice), 1));
		else if (k == 3) (to, data) = (address(shares), abi.encodeCall(IERC20.transferFrom, (address(alice), a, 1)));
		else if (k == 4) (to, data) = (address(fund), abi.encodeCall(Comptroller.payOutRedemption, (a, 0, 1 + seed % 1_000e6)));
		else if (k == 5) (to, data) = (address(fund), abi.encodeCall(Comptroller.settleFeesForRedemption, ()));
		else if (k == 6) (to, data) = (address(fund), abi.encodeCall(Comptroller.liquidateTrade, (address(adapter), trade)));
		else if (k == 7) (to, data) = (address(fund), abi.encodeCall(Comptroller.callOnIntegration, (address(adapter), trade)));
		else if (k == 8) (to, data) = (address(fund), abi.encodeCall(Comptroller.addTrackedAsset, (address(weth))));
		else if (k == 9) (to, data) = (address(fund), abi.encodeCall(Comptroller.removeTrackedAsset, (address(weth))));
		else if (k == 10) (to, data) = (address(fund), abi.encodeCall(Comptroller.setOwnerDepositsPaused, (true)));
		else if (k == 11) (to, data) = (address(fund), abi.encodeCall(Comptroller.setGuardianDepositsPaused, (true)));
		else if (k == 12) (to, data) = (address(fund), abi.encodeCall(Comptroller.shutDownFund, ()));
		else if (k == 13) (to, data) = (address(fund), abi.encodeCall(Comptroller.initialize, (shares, fund.vault())));
		else if (k == 14) (to, data) = (address(fund), abi.encodeCall(Comptroller.createExternalPosition, (UNWIND_TYPE, '')));
		else if (k == 15) (to, data) = (address(fund), abi.encodeCall(Comptroller.addPolicy, (IPolicy.PolicyHook.PostCallOnIntegration, address(slippage))));
		else if (k == 16) (to, data) = (address(fund), abi.encodeCall(Comptroller.writeOffAsset, (address(tkn))));
		else if (k == 17) (to, data) = (address(queue), abi.encodeCall(RedemptionQueue.settle, (address(fund), 1)));
		else if (k == 18) (to, data) = (address(queue), abi.encodeCall(RedemptionQueue.liquidate, (address(fund), address(adapter), trade)));
		else if (k == 19) (to, data) = (address(queue), abi.encodeCall(RedemptionQueue.setKeeper, (a, true)));
		else if (k == 20) (to, data) = (address(factory), abi.encodeCall(FundFactory.registerAdapter, (a)));
		else (to, data) = (address(factory), abi.encodeCall(FundFactory.setGuardian, (a)));
		(bool ok,) = eve.run(to, data);
		assert(!ok);
	}

	/// @dev The manager, honest here: a trade at the oracle's price, in either direction, to change how much USDC the vault has.
	function fairTrade(uint256 tokenSeed, bool buy, uint256 amount) public step {
		MockERC20 t = tokenSeed % 2 == 0 ? weth : stk;
		MockERC20 tin = buy ? usdc : t;
		MockERC20 tout = buy ? t : usdc;
		uint256 held = tin.balanceOf(vault);
		if (held == 0) return;
		amount = 1 + amount % held;
		_trade(tin, tout, amount, _fairOut(tin, tout, amount) + 1);
	}

	function keeperLiquidate(uint256 tokenSeed, uint256 amount) public step {
		MockERC20 t = _token(1 + tokenSeed % 3);
		uint256 held = t.balanceOf(vault);
		if (held == 0) return;
		amount = 1 + amount % held;
		router.setNextAmountOut(_fairOut(t, usdc, amount) + 1);
		keeper.run(address(queue), abi.encodeCall(RedemptionQueue.liquidate, (address(fund), address(adapter), _tradeData(t, usdc, amount))));
	}

	/// Eve never ends up with more than she put in, however she goes about it.
	function property_outsider_never_profits() public returns (bool) {
		vm.warp(clock);
		(bool known, uint256 wealth) = _wealth(eve);
		return !known || wealth <= minted[address(eve)] + _dust();
	}

	/// Nothing Eve does costs Alice or Bob anything.
	function property_investors_keep_their_value() public returns (bool) {
		vm.warp(clock);
		(bool known, uint256 a) = _wealth(alice);
		if (!known) return true;
		(, uint256 b) = _wealth(bob);
		return a + _dust() >= minted[address(alice)] && b + _dust() >= minted[address(bob)];
	}

	/// No shares appear from nowhere.
	function property_every_share_has_an_owner() public view returns (bool) {
		uint256 held = shares.balanceOf(address(queue)) + shares.balanceOf(address(manager));
		for (uint256 i; i < investors.length; ++i) held += shares.balanceOf(address(investors[i]));
		return shares.totalSupply() == held + supplyOffset;
	}

	/// The queue holds exactly the shares of its open requests.
	function property_queue_escrow_matches() public view returns (bool) {
		uint256 open;
		for (uint256 i; i < investors.length; ++i) {
			(bool exists,, RedemptionQueue.Request memory r) = queue.requestOf(address(fund), address(investors[i]));
			if (exists) open += r.shares;
		}
		return shares.balanceOf(address(queue)) == open + sharesDonatedToQueue;
	}

	/// The fund holds exactly the USDC of its open deposit requests.
	function property_deposit_escrow_matches() public view returns (bool) {
		uint256 open;
		for (uint256 i; i < investors.length; ++i) {
			(uint256 escrow,,) = fund.depositRequests(address(investors[i]));
			open += escrow;
		}
		return usdc.balanceOf(address(fund)) == open + usdcDonatedToFund;
	}
}

/// @notice A hostile manager, with their own venue: the router takes what the fund sells and pays whatever the manager sets. Prices
///         don't move, so all the manager can gain is what the rules let them take. The bound is the slippage budget and its refill.
contract ManagerTheft is TheftWorld {
	int256 internal managerNet; // what the manager's venue took in, less what it paid out
	uint256 internal peakGav;
	mapping(address => uint256) internal mirror;
	MockUnwindPosition internal position;

	constructor() {
		_build(2_000);
		_seed(alice, 100_000e6);
		_seed(bob, 50_000e6);
		require(_trade(usdc, weth, 30_000e6, 15e18) && _trade(usdc, stk, 30_000e6, 300e8) && _trade(usdc, tkn, 100e6, 100e6), 'trades');
		investors.push(manager);
		_baseline();
		_synced();
		peakGav = 150_000e6;
	}

	function _afterStep() internal override {
		(bool known, uint256 gav) = _gav();
		if (known && gav > peakGav) peakGav = gav;
	}

	function _synced() internal override {
		mirror[address(alice)] = _sharesOwned(alice);
		mirror[address(bob)] = _sharesOwned(bob);
	}

	/// @dev Half of these are tiny: a loop of trades too small to round up to a charge would walk past the budget.
	function managerTrade(uint256 inSeed, uint256 outSeed, uint256 amount, uint256 outBps) public step {
		MockERC20 tin = _token(inSeed);
		MockERC20 tout = _token(outSeed);
		if (tin == tout) return;
		uint256 held = tin.balanceOf(vault);
		if (held == 0) return;
		amount = amount % 2 == 0 ? 1 + amount % 1_000 : 1 + amount % held;
		if (amount > held) amount = held;
		uint256 out = Math.mulDiv(_fairOut(tin, tout, amount), outBps % 10_200, 10_000);
		if (_trade(tin, tout, amount, out)) managerNet += int256(_usd(tin, amount)) - int256(_usd(tout, out));
	}

	function managerSettle(uint256 maxRequests) public step {
		_settle(manager, maxRequests);
		_synced();
	}

	function managerPause(bool paused) public step {
		manager.run(address(fund), abi.encodeCall(Comptroller.setOwnerDepositsPaused, (paused)));
	}

	function managerTrack(uint256 tokenSeed) public step {
		manager.run(address(fund), abi.encodeCall(Comptroller.addTrackedAsset, (address(_token(tokenSeed)))));
	}

	function managerUntrack(uint256 tokenSeed) public step {
		manager.run(address(fund), abi.encodeCall(Comptroller.removeTrackedAsset, (address(_token(tokenSeed)))));
	}

	function managerWriteOff(uint256 tokenSeed) public step {
		manager.run(address(fund), abi.encodeCall(Comptroller.writeOffAsset, (address(_token(tokenSeed)))));
	}

	function managerOpenPosition(uint256 amount) public step {
		if (address(position) == address(0)) {
			(bool ok, bytes memory ret) =
				manager.run(address(fund), abi.encodeCall(Comptroller.createExternalPosition, (UNWIND_TYPE, '')));
			if (!ok) return;
			position = MockUnwindPosition(abi.decode(ret, (address)));
		}
		uint256 held = usdc.balanceOf(vault);
		if (held == 0) return;
		amount = 1 + amount % held;
		address[] memory assets = new address[](1);
		assets[0] = address(usdc);
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = amount;
		manager.run(address(fund), abi.encodeCall(
			Comptroller.callOnExternalPosition, (address(position), assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(amount)))
		));
	}

	function managerClosePosition(uint256 amount) public step {
		if (address(position) == address(0)) return;
		amount = 1 + amount % 200_000e6;
		manager.run(address(fund), abi.encodeCall(
			Comptroller.callOnExternalPosition, (address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), abi.encode(amount)))
		));
		address[] memory back = new address[](1);
		back[0] = address(usdc);
		manager.run(address(fund), abi.encodeCall(
			Comptroller.callOnExternalPosition, (address(position), new address[](0), new uint256[](0), back, abi.encode(uint8(6), abi.encode(amount)))
		));
	}

	function managerRemovePosition() public step {
		if (address(position) == address(0)) return;
		manager.run(address(fund), abi.encodeCall(Comptroller.removeExternalPosition, (address(position))));
	}

	/// The keeper's sale never loses more than 3% to the oracle, whatever the venue pays.
	function keeperLiquidate(uint256 tokenSeed, uint256 amount, uint256 outBps) public step {
		MockERC20 t = _token(1 + tokenSeed % 3);
		uint256 held = t.balanceOf(vault);
		if (held == 0) return;
		amount = 1 + amount % held;
		uint256 out = Math.mulDiv(_fairOut(t, usdc, amount), outBps % 10_000, 10_000);
		router.setNextAmountOut(out);
		(bool ok,) = keeper.run(address(queue), abi.encodeCall(RedemptionQueue.liquidate, (address(fund), address(adapter), _tradeData(t, usdc, amount))));
		if (ok) assert(out + 2 >= Math.mulDiv(_usd(t, amount), 9_700, 10_000));
	}

	function _budget() internal view returns (uint256) {
		uint256 base = Math.mulDiv(peakGav, BUDGET_BPS, 10_000);
		return base + Math.mulDiv(base, clock - startClock, 7 days);
	}

	/// The most a manager can come away with is the slippage budget plus its refill, by trades, fees and their own shares together.
	function property_manager_take_within_budget() public returns (bool) {
		vm.warp(clock);
		(bool known, uint256 wealth) = _wealth(manager);
		if (!known) return true;
		return int256(wealth) - int256(minted[address(manager)]) + managerNet <= int256(_budget() + _dust());
	}

	/// The manager can't touch an investor's shares.
	function property_only_an_investor_moves_their_shares() public view returns (bool) {
		return _sharesOwned(alice) == mirror[address(alice)] && _sharesOwned(bob) == mirror[address(bob)];
	}
}

/// @notice A long-tail holding the fund paid `TKN_COST` for, under the 0.1% line, with an LP who can pull the pool's liquidity whenever
///         they like. Nothing else moves. A deposit made while it reads $0 buys in without paying for it.
contract FloorTheft is TheftWorld {
	uint256 internal constant TKN_COST = 100e6;
	bool internal floored;

	constructor() {
		_build(0);
		_seed(alice, 100_000e6);
		_seed(bob, 50_000e6);
		require(_trade(usdc, tkn, TKN_COST, TKN_COST), 'trade');
		_baseline();
	}

	function floorOn() public step {
		pool.setDip(1, 0, 721);
		floored = true;
	}

	function floorOff() public step {
		pool.setDip(0, 0, 0);
		floored = false;
	}

	/// A deposit never goes through at the floor, at any size (founder 2026-11-05, tool run Finding 1).
	function executeDeposit(uint256 caller, uint256 who) public override {
		(uint256 escrow,,) = fund.depositRequests(address(_who(who)));
		bool atFloor = floored && tkn.balanceOf(vault) > 0;
		super.executeDeposit(caller, who);
		(uint256 left,,) = fund.depositRequests(address(_who(who)));
		if (escrow != 0 && left == 0) assert(!atFloor);
	}

	/// Exits keep the 0.1% line, so someone leaving at the floor can be paid short and those who stay gain: at most the holding's worth.
	function property_floor_gain_at_most_one_holding() public returns (bool) {
		vm.warp(clock);
		if (floored) return true;
		(bool known, uint256 wealth) = _wealth(eve);
		return !known || wealth <= minted[address(eve)] + TKN_COST + _dust();
	}
}

/// @notice Prices move here, so these rules are about when money may move, not how much anyone ends up with.
contract WaitRules is TheftWorld {
	bool internal floored;
	bool internal marketClosed;

	constructor() {
		_build(0);
		_seed(alice, 100_000e6);
		_seed(bob, 50_000e6);
		require(_trade(usdc, weth, 30_000e6, 15e18) && _trade(usdc, stk, 30_000e6, 300e8) && _trade(usdc, tkn, 100e6, 100e6), 'trades');
		_baseline();
	}

	function _refreshFeeds() internal override {
		usdcFeed.setAnswer(1e8);
		wethFeed.setAnswer(int256(wethPx * 100));
		if (!marketClosed) stkFeed.setAnswer(int256(stkPx * 100));
	}

	function marketClose() public step {
		marketClosed = true;
	}

	function marketOpen(uint256 moveBps) public step {
		marketClosed = false;
		stkPx = Math.mulDiv(stkPx, 8_000 + moveBps % 4_001, 10_000);
		if (stkPx == 0) stkPx = 1;
		stkFeed.setAnswer(int256(stkPx * 100));
	}

	function moveWeth(uint256 moveBps) public step {
		wethPx = Math.mulDiv(wethPx, 9_000 + moveBps % 2_001, 10_000);
		if (wethPx == 0) wethPx = 1;
		wethFeed.setAnswer(int256(wethPx * 100));
	}

	function floorOn() public step {
		pool.setDip(1, 0, 721);
		floored = true;
	}

	function floorOff() public step {
		pool.setDip(0, 0, 0);
		floored = false;
	}

	/// @dev Moves how much of the stock and the token the fund holds, across the 0.1% line in both directions.
	function fairTrade(uint256 tokenSeed, bool buy, uint256 amount) public step {
		MockERC20 t = tokenSeed % 2 == 0 ? stk : tkn;
		MockERC20 tin = buy ? usdc : t;
		MockERC20 tout = buy ? t : usdc;
		uint256 held = tin.balanceOf(vault);
		if (held == 0) return;
		amount = 1 + amount % held;
		if (amount % 2 == 0) amount = 1 + amount % Math.mulDiv(1_000e6, _unit(tin), _px(tin));
		_trade(tin, tout, amount, _fairOut(tin, tout, amount) + 1);
	}

	/// @dev Whether the rules require a wait right now, from the fund's value: with a little margin, so rounding at the line isn't a finding.
	function _waits() internal returns (bool known, bool stockWaits, bool longTailBig) {
		uint256 gav;
		(known, gav) = _gav();
		if (!known) return (false, false, false);
		uint256 line = Math.mulDiv(gav, LINE_BPS, 10_000);
		uint256 stkValue = Math.mulDiv(stk.balanceOf(vault), stkPx, _unit(stk));
		uint256 tknSize = Math.max(tkn.balanceOf(vault), fund.costBasis(address(tkn)));
		stockWaits = clock > stkFeed.updatedAt() + 4 hours && stkValue > line + line / 100 + 1_000;
		longTailBig = tknSize > line + line / 100 + 1_000;
	}

	/// An instant exit never pays past a wait: a stock on a closed market or a long-tail token over the line.
	function redeemNow(uint256 who, uint256 seed) public override step {
		(bool known, bool stockWaits, bool longTailBig) = _waits();
		bool ok = _redeem(_who(who), seed);
		if (ok && known) assert(!stockWaits && !longTailBig);
	}

	/// The queue doesn't pay past a stock on a closed market, even overdue, or past a long-tail token over the line at the floor, until overdue.
	function keeperSettle(uint256 maxRequests) public override step {
		(bool known, bool stockWaits, bool longTailBig) = _waits();
		bool overdue = queue.isOverdue(address(fund));
		bool ok = _settle(keeper, maxRequests);
		if (ok && known) {
			assert(!stockWaits);
			assert(!floored || !longTailBig || overdue);
		}
	}

	/// A deposit doesn't buy in past a long-tail token at the floor, at any size (founder 2026-11-05, tool run Finding 1).
	function executeDeposit(uint256 caller, uint256 who) public override step {
		bool atFloor = floored && tkn.balanceOf(vault) > 0;
		(uint256 escrow,,) = fund.depositRequests(address(_who(who)));
		(bool ok,) = _who(caller).run(address(fund), abi.encodeCall(Comptroller.executeDepositRequest, (address(_who(who)))));
		if (ok && escrow != 0) assert(!atFloor);
	}
}

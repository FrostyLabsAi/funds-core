// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerBlueprintDeployer} from '../../src/core/ComptrollerBlueprintDeployer.sol';
import {SharesVaultDeployer} from '../../src/core/SharesVaultDeployer.sol';
import {Comptroller} from '../../src/core/Comptroller.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IUniswapV3SwapRouter} from '../../src/interfaces/external/IUniswapV3SwapRouter.sol';
import {UniswapV3SwapAdapter} from '../../src/adapters/UniswapV3SwapAdapter.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {RegistrarFixture} from './RegistrarFixture.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {RedemptionQueue} from '../../src/redemption/RedemptionQueue.sol';
import {Shares} from '../../src/fund/Shares.sol';
import {MockERC20, MockAggregator, MockSwapRouter} from './Mocks.sol';
import {MockPerpAccountFactory} from './MockRedemptionQueue.sol';
import {MockUnwindPosition, MockUnwindPositionFactory} from './MockUnwindPosition.sol';
import {ScriptedCLPool, MockUniswapV3Factory, MockSlipstreamFactory, MockAerodromeBasicFactory} from './PoolPriceMocks.sol';
import {IShares} from '../../src/interfaces/IShares.sol';

/// @notice Fund version 6 (USDC-only exit, founder 2026-10-11) on a real factory wired to a real RedemptionQueue:
///         The world (USDC denomination $1, WETH $2,000 Chainlink-style, TKN $1 pool-priced,
///         MockUnwindPosition as a perp stand-in) with fund v6 funds and the queue's keeper.
abstract contract RedemptionFixture is Test {
	uint128 internal constant PLENTY = 1_000_000e6;
	uint256 internal constant UNWIND_TYPE = 99;

	ValueInterpreter internal vi;
	PoolPriceRegistrar internal registrar;
	FundFactory internal factory;
	RedemptionQueue internal queue;
	MockPerpAccountFactory internal perpConfig;
	MockSwapRouter internal router;
	UniswapV3SwapAdapter internal uniAdapter;
	MockERC20 internal usdc;
	MockERC20 internal weth;
	MockERC20 internal tkn;
	MockAggregator internal wethFeed;
	MockAggregator internal usdcFeed;
	ScriptedCLPool internal pool;

	address internal manager = makeAddr('manager');
	address internal guardian = makeAddr('guardian');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');
	address internal carol = makeAddr('carol');
	address internal stranger = makeAddr('stranger');
	address internal keeper = makeAddr('keeper');
	uint256 internal nonce;

	function setUp() public virtual {
		vm.warp(30 days);
		usdc = new MockERC20('USD Coin', 'USDC', 6);
		weth = new MockERC20('Wrapped Ether', 'WETH', 18);
		tkn = new MockERC20('Token', 'TKN', 6);
		wethFeed = new MockAggregator(8, 2000e8);
		usdcFeed = new MockAggregator(8, 1e8);
		vi = new ValueInterpreter(address(this));
		vi.addPrimitive(address(usdc), address(usdcFeed), 25 hours);
		vi.addPrimitive(address(weth), address(wethFeed), 25 hours);

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
		deal(address(usdc), address(pool), 1_000_000e6);
		uniswap.setPool(address(tkn), address(usdc), 3000, address(pool));
		registrar.register(address(tkn), address(pool));

		queue = new RedemptionQueue(address(this));
		perpConfig = new MockPerpAccountFactory(IERC20(address(usdc)));
		factory = new FundFactory(
			vi,
			new ComptrollerBlueprintDeployer(type(Comptroller).creationCode, abi.encode(registrar, queue, perpConfig)),
			new SharesVaultDeployer()
		);
		queue.setFactory(address(factory));
		queue.setKeeper(keeper, true);
		factory.setGuardian(guardian);
		router = new MockSwapRouter();
		uniAdapter = new UniswapV3SwapAdapter(IUniswapV3SwapRouter(address(router)), address(0xFEE), 0, address(this));
		factory.registerAdapter(address(uniAdapter));
		FundFactory.PolicyReg[] memory mandatory = new FundFactory.PolicyReg[](1);
		mandatory[0] = FundFactory.PolicyReg({
			hook: IPolicy.PolicyHook.PostCallOnIntegration, policy: address(new MinPoolLiquidityPolicy(registrar))
		});
		factory.setMandatoryPolicies(mandatory);
		factory.registerPositionType(UNWIND_TYPE, address(new MockUnwindPositionFactory(IERC20(address(usdc)))));
	}

	function _config(uint128 mgmtRate, uint16 perfBps, uint64 timelock) internal returns (FundFactory.FundConfig memory) {
		return FundFactory.FundConfig({
			name: string.concat('Fund #', vm.toString(++nonce)),
			symbol: 'QF',
			denominationAsset: IERC20(address(usdc)),
			fundOwner: manager,
			mgmtScaledPerSecondRate: mgmtRate,
			perfFeeBps: perfBps,
			sharesActionTimelock: timelock,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		});
	}

	/// @dev A fund where alice deposited 10,000 USDC at the bootstrap price.
	function _fund() internal returns (Comptroller fund) {
		fund = Comptroller(factory.createFund(_config(0, 0, 0)));
		_deposit(fund, alice, 10_000e6);
	}

	/// @dev `_fund()` with `locked` USDC moved into a MockUnwindPosition (a perp stand-in).
	function _fundWithPosition(uint256 locked) internal returns (Comptroller fund, MockUnwindPosition position) {
		fund = _fund();
		position = _openPosition(fund, locked);
	}

	function _openPosition(Comptroller fund, uint256 locked) internal returns (MockUnwindPosition position) {
		vm.startPrank(manager);
		position = MockUnwindPosition(fund.createExternalPosition(UNWIND_TYPE, ''));
		_lock(fund, position, locked);
		vm.stopPrank();
	}

	/// @dev manager's call: move `amount` USDC from the vault into the position and lock it.
	function _lock(Comptroller fund, MockUnwindPosition position, uint256 amount) internal {
		address[] memory assets = new address[](1);
		assets[0] = address(usdc);
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = amount;
		fund.callOnExternalPosition(address(position), assets, amounts, new address[](0), abi.encode(uint8(0), abi.encode(amount)));
	}

	/// @dev The manager closes `amount` and returns it to the vault.
	function _managerReturns(Comptroller fund, MockUnwindPosition position, uint256 amount) internal {
		vm.startPrank(manager);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), new address[](0), abi.encode(uint8(1), abi.encode(amount)));
		address[] memory back = new address[](1);
		back[0] = address(usdc);
		fund.callOnExternalPosition(address(position), new address[](0), new uint256[](0), back, abi.encode(uint8(6), abi.encode(amount)));
		vm.stopPrank();
	}

	function _deposit(Comptroller fund, address who, uint256 amount) internal {
		deal(address(usdc), who, amount);
		vm.startPrank(who);
		usdc.approve(address(fund), amount);
		fund.requestDeposit(amount, type(uint256).max);
		vm.stopPrank();
		skip(1 minutes);
		fund.executeDepositRequest(who);
	}

	function _swap(Comptroller fund, MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn, uint256 amountOut) internal {
		router.setNextAmountOut(amountOut);
		vm.prank(manager);
		fund.callOnIntegration(
			address(uniAdapter), abi.encode(address(tokenIn), address(tokenOut), uint24(3000), amountIn, uint256(0))
		);
	}

	function _request(Comptroller fund, address who, uint256 shares) internal returns (uint256 id) {
		IShares fundShares = fund.shares();
		vm.startPrank(who);
		fundShares.approve(address(queue), shares);
		id = queue.requestRedeem(address(fund), shares);
		vm.stopPrank();
	}

	function _sharesOf(Comptroller fund, address who) internal view returns (uint256) {
		return fund.shares().balanceOf(who);
	}

	function _held(Comptroller fund, MockERC20 token) internal view returns (uint256) {
		return token.balanceOf(address(fund.vault()));
	}

	function _refreshFeeds() internal {
		usdcFeed.setAnswer(1e8);
		wethFeed.setAnswer(wethFeed.answer());
	}
}

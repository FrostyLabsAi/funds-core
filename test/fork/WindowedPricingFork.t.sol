// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {console2} from 'forge-std/console2.sol';
import {IPoolWatch} from '../../src/interfaces/IPoolWatch.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {IPoolPriceAdapter} from '../../src/interfaces/IPoolPriceAdapter.sol';
import {PoolPriceRegistrarV2} from '../../src/pricing/PoolPriceRegistrarV2.sol';
import {PoolPriceRegistrarV3} from '../../src/pricing/PoolPriceRegistrarV3.sol';
import {PoolPriceRegistrarWindowed} from '../../src/pricing/PoolPriceRegistrarWindowed.sol';
import {WindowedPricing} from '../../script/mainnet/WindowedPricing.sol';
import {B20Mirror} from '../utils/B20Mirror.sol';

/// @notice Rehearses the PRICING-POOL-01 rollout (WindowedPricing, as DeployWindowedPricing and WindowedPricingOwnerSteps
///         run it) on live mainnet state. Every B20 token or quote is mirrored from the real chain, because Foundry can't run
///         B20 code; on mainnet those listings go through migrate-windowed-b20.sh, which sends the same setPool with cast.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/WindowedPricingFork.t.sol -vv
contract WindowedPricingForkTest is B20Mirror {
	/// @dev After the deployer's EIP-7702 delegation was revoked (block 53,379,300) and every 2026-10-27 deploy.
	uint256 internal constant FORK_BLOCK = 53_380_000;
	/// @dev How many pool-priced tokens the old chain lists at this block (cast, 2026-11-01): 149 of 166 registered.
	uint256 internal constant LISTED = 149;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;

	bool internal forked;
	address internal deployer;
	FundFactory internal factory;
	ValueInterpreter internal vi;
	PoolPriceRegistrarV3 internal oldV3 = PoolPriceRegistrarV3(WindowedPricing.OLD_V3);
	WindowedPricing.Deployed internal d;
	address[] internal listed;
	mapping(address asset => address) internal oldClone;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		string memory genesis = vm.readFile('deployments/base-mainnet.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
		vi = PoolPriceRegistrarWindowed(WindowedPricing.OLD_V1).valueInterpreter();

		address[] memory registered = oldV3.getRegisteredAssets();
		for (uint256 i; i < registered.length; ++i) {
			address adapter = oldV3.poolPricedAdapter(registered[i]);
			if (adapter == address(0) || oldClone[registered[i]] != address(0)) continue;
			oldClone[registered[i]] = adapter;
			listed.push(registered[i]);
			_mirrorB20(registered[i], adapter);
		}

		vm.startPrank(deployer);
		d = WindowedPricing.deploy(
			deployer,
			vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-fund-v6.json'), '.queueV2'),
			vm.parseJsonAddress(genesis, '.verantaFactory'),
			vm.parseJsonAddress(vm.readFile('deployments/base-mainnet-clm-v2.json'), '.strategyFactory')
		);
		vm.stopPrank();
	}

	/// @dev A B20 asset's or quote's decimals and the pool's balance, read from the real chain at the fork block.
	function _mirrorB20(address asset, address adapter) internal {
		IPoolPriceAdapter.Config memory c = IPoolPriceAdapter(adapter).config();
		address[] memory holders = new address[](1);
		holders[0] = c.pool;
		if (_isB20(asset)) _mirror(asset, holders);
		if (_isB20(c.quoteAsset)) _mirror(c.quoteAsset, holders);
	}

	function _rollout() internal {
		vm.startPrank(deployer);
		WindowedPricing.wire(d);
		WindowedPricing.handOverVi(d);
		for (uint256 i; i < listed.length; ++i) {
			WindowedPricing.moveToken(d, listed[i]);
		}
		WindowedPricing.switchNewFunds(d, factory);
		vm.stopPrank();
	}

	/// @dev The implementation a clone delegates to: an EIP-1167 clone's code holds it at bytes 10..30.
	function _implementationOf(address clone) internal view returns (address impl) {
		bytes memory code = clone.code;
		require(code.length >= 45, 'not a clone');
		assembly ('memory-safe') {
			impl := shr(96, mload(add(code, 42)))
		}
	}

	function _answer(address adapter) internal view returns (bool ok, int256 answer) {
		try IPoolPriceAdapter(adapter).latestRoundData() returns (uint80, int256 a, uint256, uint256, uint80) {
			return (true, a);
		} catch {
			return (false, 0);
		}
	}

	function test_fork_everyListedTokenEndsOnAFixedCloneOfItsSamePool() public {
		vm.skip(!forked);
		assertEq(listed.length, LISTED, 'the book this rehearsal was written against');
		_rollout();

		address concentrated = d.base.concentratedAdapter();
		address basic = d.base.basicAdapter();
		address v4 = d.registrarV2.v4Adapter();
		for (uint256 i; i < listed.length; ++i) {
			address asset = listed[i];
			address clone = d.registrar.poolPricedAdapter(asset);
			assertTrue(clone != address(0), 'long-tail on the new chain');
			(address aggregator,,,) = vi.getAssetInfo(asset);
			assertEq(aggregator, clone, 'the VI prices it from the new clone');
			address impl = _implementationOf(clone);
			assertTrue(impl == concentrated || impl == basic || impl == v4, 'a fixed implementation');
			assertEq(oldV3.poolPricedAdapter(asset), address(0), 'off the old chain');

			IPoolPriceAdapter.Config memory before = IPoolPriceAdapter(oldClone[asset]).config();
			IPoolPriceAdapter.Config memory now_ = IPoolPriceAdapter(clone).config();
			assertEq(now_.pool, before.pool, 'same pool');
			assertEq(now_.quoteAsset, before.quoteAsset, 'same quote');
			assertEq(now_.assetIsToken0, before.assetIsToken0, 'same side');
			assertEq(now_.assetDecimals, before.assetDecimals, 'same decimals');
		}
	}

	/// The move changes no price: wherever the old clone read a real price, the new one reads the same. A v4 token keeps
	/// the same implementation code, but its new clone asks the same sampler, so it reads the same too.
	function test_fork_theMoveKeepsThePrice() public {
		vm.skip(!forked);
		_rollout();
		uint256 compared;
		for (uint256 i; i < listed.length; ++i) {
			(bool oldOk, int256 oldAnswer) = _answer(oldClone[listed[i]]);
			(bool newOk, int256 newAnswer) = _answer(d.registrar.poolPricedAdapter(listed[i]));
			assertEq(newOk, oldOk, 'reads where it read');
			// 1 wei on the old clone may be the very bug: its cliff read the pool's balance now
			if (!oldOk || oldAnswer == 1) continue;
			// the new clone reads the slices' median, the old one the window's mean: at this block they differ by 0.18% at most
			// over 126 tokens, 0.05% at the 90th percentile (forge test -vv, 2026-11-01)
			assertApproxEqRel(uint256(newAnswer), uint256(oldAnswer), 5e15, 'the same price, to 0.5%');
			++compared;
		}
		assertGt(compared, 50, 'compared real prices');
	}

	/// How often a live pool makes deposits and the queue wait (review 2026-11-01): a watch that fires on healthy pools would
	/// stop funds for nothing. Counted on the moved clones at the pinned block.
	function test_fork_fewLivePoolsReadUnsettled() public {
		vm.skip(!forked);
		_rollout();
		uint256 read;
		uint256 unsettled;
		uint256 dead;
		for (uint256 i; i < listed.length; ++i) {
			address adapter = d.registrar.poolPricedAdapter(listed[i]);
			(bool ok, int256 answer) = _answer(adapter);
			if (!ok) continue;
			++read;
			if (answer == 1) {
				++dead;
			} else if (IPoolWatch(adapter).poolUnsettled()) {
				console2.log('unsettled', listed[i]);
				++unsettled;
			}
		}
		console2.log('read', read);
		console2.log('dead (1 wei)', dead);
		console2.log('unsettled, not dead', unsettled);
		assertGt(read, 50, 'read real pools');
		assertLt(unsettled * 10, read, 'under a tenth of live pools');
	}

	/// Every old `register` ends in the old V1's call to the VI, and the old V1 no longer owns it.
	function test_fork_everyOldListingPathIsClosed() public {
		vm.skip(!forked);
		_rollout();
		assertEq(Ownable(address(vi)).owner(), address(d.base));
		vm.prank(WindowedPricing.OLD_V1);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, WindowedPricing.OLD_V1));
		vi.addPrimitive(address(0xdead), address(0xbeef), 1 hours);
	}

	/// The replayed config: everything old V2 had approved, the new V2 has too.
	function test_fork_theConfigIsReplayed() public {
		vm.skip(!forked);
		_rollout();
		PoolPriceRegistrarV2 old = PoolPriceRegistrarV2(WindowedPricing.OLD_V2);
		assertEq(d.registrarV2.owner(), address(d.registrar));
		assertEq(d.base.owner(), address(d.registrarV2));
		assertEq(address(d.registrarV2.sampler()), address(old.sampler()), 'the live sampler');
		assertTrue(d.registrarV2.isPoolApprover(WindowedPricing.ADMIN_SAFE));
		assertTrue(d.registrar.isQuote(WindowedPricing.AMZNC));
		assertEq(d.base.uniswapV3Factory(), PoolPriceRegistrarWindowed(WindowedPricing.OLD_V1).uniswapV3Factory());
	}

	/// New funds are v6 on the new chain, with the new policy on every hook the old one held.
	function test_fork_newFundsAreBuiltOnTheNewChain() public {
		vm.skip(!forked);
		FundFactory.PolicyReg[] memory beforeRegs = factory.getMandatoryPolicies();
		_rollout();
		assertEq(address(factory.comptrollerDeployer()), address(d.fundV6Deployer));
		assertTrue(factory.isAdapterRegistered(address(d.v4Adapter)));
		FundFactory.PolicyReg[] memory afterRegs = factory.getMandatoryPolicies();
		assertEq(afterRegs.length, beforeRegs.length + 2, 'the slippage policy on its two hooks');
		for (uint256 i; i < beforeRegs.length; ++i) {
			assertEq(uint8(afterRegs[i].hook), uint8(beforeRegs[i].hook));
			assertEq(afterRegs[i].policy, beforeRegs[i].policy == WindowedPricing.OLD_POLICY ? address(d.policy) : beforeRegs[i].policy);
		}
		assertEq(uint8(afterRegs[beforeRegs.length].hook), uint8(IPolicy.PolicyHook.PostCallOnIntegration));
		assertEq(uint8(afterRegs[beforeRegs.length + 1].hook), uint8(IPolicy.PolicyHook.PostCallOnExternalPosition));
		assertEq(afterRegs[beforeRegs.length].policy, address(d.slippage));
		assertEq(afterRegs[beforeRegs.length + 1].policy, address(d.slippage));
		assertEq(d.slippage.toleranceBps(), WindowedPricing.MANDATORY_SLIPPAGE_BPS);
		address fund = factory.createFund(
			FundFactory.FundConfig({
				name: 'Windowed',
				symbol: 'WIN',
				denominationAsset: IERC20(USDC),
				fundOwner: makeAddr('manager'),
				mgmtScaledPerSecondRate: 0,
				perfFeeBps: 0,
				sharesActionTimelock: 0,
				minRequestDuration: 1 minutes,
				executionWindow: 1 days,
				allowRiskyAssets: false
			})
		);
		assertEq(address(ComptrollerV6(fund).registrar()), address(d.registrar));
		address[] memory onTrades = ComptrollerV6(fund).getPolicies(IPolicy.PolicyHook.PostCallOnIntegration);
		bool slippageOn;
		for (uint256 i; i < onTrades.length; ++i) {
			if (onTrades[i] == address(d.slippage)) slippageOn = true;
		}
		assertTrue(slippageOn, 'a new fund carries the slippage policy');
	}

	/// PRICING-POOL-01 on live pools: with a pool's quote balance gone for the call, a token's new clone keeps its price
	/// while its old clone reads 1 wei.
	function test_fork_aDrainedQuoteBalanceNoLongerZeroesALiveToken() public {
		vm.skip(!forked);
		_rollout();
		uint256 checked;
		for (uint256 i; i < listed.length && checked < 5; ++i) {
			address oldAdapter = oldClone[listed[i]];
			IPoolPriceAdapter.Config memory c = IPoolPriceAdapter(oldAdapter).config();
			address clone = d.registrar.poolPricedAdapter(listed[i]);
			if (_implementationOf(clone) != d.base.concentratedAdapter() || (c.quoteAsset != USDC && c.quoteAsset != WETH)) continue;
			(bool ok, int256 fair) = _answer(clone);
			(bool oldOk, int256 oldFair) = _answer(oldAdapter);
			if (!ok || !oldOk || fair <= 1 || oldFair <= 1) continue;

			uint256 snapshot = vm.snapshotState();
			deal(c.quoteAsset, c.pool, 0);
			(, int256 drained) = _answer(clone);
			(, int256 oldDrained) = _answer(oldAdapter);
			assertEq(drained, fair, 'the fixed clone keeps the window price');
			assertEq(oldDrained, 1, 'the old clone (the control) reads 1 wei');
			assertEq(IPoolPriceAdapter(clone).liquidityUsd(), 0, 'the buy floor still sees the drain');
			vm.revertToState(snapshot);
			++checked;
		}
		assertEq(checked, 5, 'checked five live concentrated pools');
	}

	/// Each step skips what is done, so a run cut short can be sent again.
	function test_fork_theOwnerStepsAreReRunnable() public {
		vm.skip(!forked);
		_rollout();
		_rollout();
		vm.startPrank(deployer);
		(uint256 moved, uint256 left) = WindowedPricing.moveAll(d);
		vm.stopPrank();
		assertEq(moved, 0, 'nothing left to move');
		assertEq(left, 0, 'nothing left for the B20 step');
	}
}

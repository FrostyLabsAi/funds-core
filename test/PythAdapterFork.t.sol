// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PythAggregatorAdapter} from '../src/pricing/PythAggregatorAdapter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IPyth} from '../src/interfaces/external/IPyth.sol';
import {MockERC20} from './utils/Mocks.sol';

/// @notice Adapter vs the REAL Pyth Core deployment on Base mainnet — proves the exponent
///         normalization against live feed data (crypto -8, equity/FX -5), cross-checks
///         Pyth vs Chainlink on ETH, and demonstrates the pull-oracle caveat honestly:
///         unpushed long-tail feeds (TSLA sat ~78 days stale at authoring) must REVERT
///         through the VI heartbeat, not misprice — that's the keeper-pusher requirement.
///         Run: BASE_MAINNET_RPC=<url> forge test --match-path test/PythAdapterFork.t.sol
contract PythAdapterForkTest is Test {
	// Base mainnet (live-read verified 2026-09-18)
	IPyth internal constant PYTH = IPyth(0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a);
	address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
	// Pyth Core ids straight from the Veranta pair catalog (data.veranta.xyz/v2/trading)
	bytes32 internal constant ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
	bytes32 internal constant TSLA_ID = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
	bytes32 internal constant EUR_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;

	address internal admin = makeAddr('admin');
	bool internal forked;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;
	}

	function test_ethAdapter_matchesChainlinkWithinTolerance() public {
		if (!forked) return;
		PythAggregatorAdapter adapter = new PythAggregatorAdapter(PYTH, ETH_ID, 200, 365 days, 'ETH/USD (Pyth)');
		(, int256 pythAnswer,, uint256 pythUpdatedAt,) = adapter.latestRoundData();
		(, int256 clAnswer,,,) = AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData();

		assertEq(adapter.decimals(), 8);
		assertGt(pythUpdatedAt, 0);
		assertLe(pythUpdatedAt, block.timestamp);
		// same 8dp scale, prices from two independent oracles within 2%
		assertApproxEqRel(uint256(pythAnswer), uint256(clAnswer), 0.02e18);
	}

	function test_tslaAdapter_normalizesExpoMinus5_andViGatesUnpushedPrice() public {
		if (!forked) return;
		PythAggregatorAdapter adapter = new PythAggregatorAdapter(PYTH, TSLA_ID, 200, 365 days, 'TSLA/USD (Pyth)');
		(, int256 answer,, uint256 publishTime,) = adapter.latestRoundData();
		// live feed is expo -5: a raw (unscaled) read would sit under $1 in 8dp terms;
		// normalized TSLA must land in a sane equity band
		assertGt(answer, 10e8); // > $10
		assertLt(answer, 10_000e8); // < $10k

		ValueInterpreter interpreter = new ValueInterpreter(admin);
		MockERC20 usdc = new MockERC20('USD Coin', 'USDC', 6);
		MockERC20 tslax = new MockERC20('TSLA Wrapper', 'TSLAx', 18);
		PythAggregatorAdapter usdcStub = new PythAggregatorAdapter(PYTH, ETH_ID, 200, 365 days, 'stub'); // quote via ETH id
		vm.startPrank(admin);
		interpreter.addPrimitive(address(usdc), address(usdcStub), 7 days);
		interpreter.addPrimitive(address(tslax), address(adapter), 4 hours);
		vm.stopPrank();

		if (block.timestamp > publishTime + 4 hours) {
			// the pull-oracle reality: nobody pushes TSLA on Base — GAV must REVERT, not misprice
			vm.expectRevert(
				abi.encodeWithSelector(ValueInterpreter.StalePrice.selector, address(tslax), publishTime)
			);
			interpreter.calcCanonicalAssetValue(address(tslax), 1e18, address(usdc));
		} else {
			// if a pusher ever keeps TSLA fresh, it must price instead
			assertGt(interpreter.calcCanonicalAssetValue(address(tslax), 1e18, address(usdc)), 0);
		}
	}

	function test_eurAdapter_normalizesFxBand() public {
		if (!forked) return;
		PythAggregatorAdapter adapter = new PythAggregatorAdapter(PYTH, EUR_ID, 200, 365 days, 'EUR/USD (Pyth)');
		(, int256 answer,,,) = adapter.latestRoundData();
		assertGt(answer, 0.5e8);
		assertLt(answer, 2e8);
	}
}

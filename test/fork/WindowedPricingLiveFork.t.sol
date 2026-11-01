// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ComptrollerV6} from '../../src/core/ComptrollerV6.sol';
import {ComptrollerV6Lib} from '../../src/core/ComptrollerV6Lib.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {ClmFundsDeploy} from '../../script/mainnet/ClmFundsDeploy.sol';
import {ListingModuleBook, ViAdmin} from '../../script/mainnet/ListingModuleBook.sol';
import {MockAggregator, MockERC20} from '../utils/Mocks.sol';

/// @notice The rollout as it stands on Base (PRICING-POOL-01, finished 2026-11-01), and the listing paths that go through it.
///         WindowedPricingFork rehearsed it from before; this reads what the founder's signatures left.
contract WindowedPricingLiveForkTest is Test {
	uint256 internal constant FORK_BLOCK = 53390931;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

	bool internal forked;
	string internal genesis;
	string internal book;
	address internal deployer;
	ValueInterpreter internal vi;
	FundFactory internal factory;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		genesis = vm.readFile('deployments/base-mainnet.json');
		book = vm.readFile('deployments/base-mainnet-windowed-pricing.json');
		deployer = vm.parseJsonAddress(genesis, '.deployer');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		factory = FundFactory(vm.parseJsonAddress(genesis, '.factory'));
	}

	function _book(string memory key) internal view returns (address) {
		return vm.parseJsonAddress(book, key);
	}

	function test_fork_theViIsOnTheFixedChain() public {
		vm.skip(!forked);
		assertEq(Ownable(address(vi)).owner(), _book('.base'));
		assertEq(Ownable(_book('.base')).owner(), _book('.registrarV2'));
		assertEq(Ownable(_book('.registrarV2')).owner(), _book('.registrar'));
		assertEq(Ownable(_book('.registrar')).owner(), deployer);
	}

	function test_fork_newFundsDeployOnIt_withBothMandatoryPolicies() public {
		vm.skip(!forked);
		assertEq(address(factory.comptrollerDeployer()), _book('.fundV6Deployer'));
		FundFactory.PolicyReg[] memory regs = factory.getMandatoryPolicies();
		uint256 liquidity;
		uint256 slippage;
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy == _book('.policy')) ++liquidity;
			if (regs[i].policy == _book('.slippage')) ++slippage;
			assertTrue(regs[i].policy == _book('.policy') || regs[i].policy == _book('.slippage'), 'nothing else mandatory');
		}
		assertEq(liquidity, 3, 'integration, position created, position called');
		assertEq(slippage, 2, 'integration, position called');
		assertTrue(factory.isAdapterRegistered(_book('.v4Adapter')));
	}

	/// A fund created now carries the fixes: the new registrar, and the write-off that only a dead token can use.
	function test_fork_aNewFundIsAFixedOne() public {
		vm.skip(!forked);
		address manager = makeAddr('manager');
		ComptrollerV6 fund = ComptrollerV6(factory.createFund(FundFactory.FundConfig({
			name: 'Live check',
			symbol: 'LIVE',
			denominationAsset: IERC20(USDC),
			fundOwner: manager,
			mgmtScaledPerSecondRate: 0,
			perfFeeBps: 0,
			sharesActionTimelock: 0,
			minRequestDuration: 1 minutes,
			executionWindow: 1 days,
			allowRiskyAssets: false
		})));
		assertEq(address(fund.registrar()), _book('.registrar'));
		vm.prank(manager);
		vm.expectRevert(abi.encodeWithSelector(ComptrollerV6Lib.NotAtFloor.selector, USDC));
		fund.writeOffAsset(USDC);
	}

	/// The listing scripts' path reaches the VI through the new chain.
	function test_fork_aListingReachesTheVi() public {
		vm.skip(!forked);
		ViAdmin memory admin = ListingModuleBook.admin(vm, genesis);
		assertEq(address(admin.owner), _book('.base'));
		assertEq(address(admin.registrarV2), _book('.registrar'));
		MockERC20 token = new MockERC20('Listing check', 'LIST', 18);
		MockAggregator feed = new MockAggregator(8, 1e8);
		vm.prank(deployer);
		admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (address(token), address(feed), uint32(1 days))));
		assertTrue(vi.isSupportedAsset(address(token)));
	}

	function test_fork_theClmListingReadsTheChain() public {
		vm.skip(!forked);
		assertEq(ClmFundsDeploy.registrarV2(), _book('.registrarV2'));
	}

	/// The old path's end is closed: the old V1 can't reach the VI any more.
	function test_fork_theOldChainCannotReachTheVi() public {
		vm.skip(!forked);
		vm.prank(0x34AcBA229Aeaf7F1c0f442633F35E26Bc94b4e2A);
		vm.expectRevert();
		vi.addPrimitive(address(0xdead), address(0xbeef), 1 hours);
	}
}

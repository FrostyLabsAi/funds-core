// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PriceListingModule} from '../src/pricing/PriceListingModule.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {IUniswapV3PoolFactory, ISlipstreamPoolFactory} from '../src/pricing/TwapListingRegistry.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {MockERC20} from './utils/Mocks.sol';

/// @dev A Chainlink-style feed the VI accepts (8 decimals, fresh).
contract FixedFeed {
	int256 public answer = 1e8;

	function decimals() external pure returns (uint8) {
		return 8;
	}

	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
		return (1, answer, block.timestamp, block.timestamp, 1);
	}
}

contract PriceListingModuleTest is Test {
	ValueInterpreter internal vi;
	TwapListingRegistryV2 internal registry;
	PriceListingModule internal module;
	MockERC20 internal priced;
	address internal stranger = makeAddr('stranger');
	address internal keeper = makeAddr('keeper');

	function setUp() public {
		vi = new ValueInterpreter(address(this));
		registry = new TwapListingRegistryV2(
			IValueInterpreter(address(vi)),
			IUniswapV3PoolFactory(makeAddr('uni')),
			ISlipstreamPoolFactory(makeAddr('s1')),
			ISlipstreamPoolFactory(makeAddr('s2')),
			ISlipstreamPoolFactory(makeAddr('s3'))
		);
		module = new PriceListingModule(vi, registry);
		registry.setLister(address(module), true);
		module.setKeeper(keeper, true);
		priced = new MockERC20('Priced', 'PRC', 18);
		vi.addPrimitive(address(priced), address(new FixedFeed()), 3600);
		// hand the VI to the module (two-step): transfer, then the module's owner accepts through execute
		vi.transferOwnership(address(module));
		module.execute(abi.encodeWithSignature('acceptOwnership()'));
	}

	function test_moduleOwnsTheVi() public view {
		assertEq(vi.owner(), address(module));
	}

	function test_constructorRejectsZeroAddress() public {
		vm.expectRevert(PriceListingModule.ZeroAddress.selector);
		new PriceListingModule(ValueInterpreter(address(0)), registry);
		vm.expectRevert(PriceListingModule.ZeroAddress.selector);
		new PriceListingModule(vi, TwapListingRegistryV2(address(0)));
	}

	function test_constructorRejectsMismatchedVi() public {
		// the module must write primitives into the same VI the registry's isTwapPriced reads
		ValueInterpreter otherVi = new ValueInterpreter(address(this));
		vm.expectRevert(PriceListingModule.ValueInterpreterMismatch.selector);
		new PriceListingModule(otherVi, registry);
	}

	function test_executeOnlyOwner() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		module.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(priced))));
		// governance still administers the VI through the module
		module.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (address(priced))));
		assertFalse(vi.isSupportedAsset(address(priced)));
	}

	function test_executeForwardsRevert() public {
		vm.expectRevert(abi.encodeWithSelector(ValueInterpreter.UnsupportedAsset.selector, stranger));
		module.execute(abi.encodeCall(ValueInterpreter.removePrimitive, (stranger)));
	}

	function test_cannotListOrRepointChainlinkAsset() public {
		// the module refuses on its own: the registry is never asked to list or repoint
		vm.expectCall(address(registry), abi.encodeWithSelector(TwapListingRegistryV2.list.selector), 0);
		vm.expectCall(address(registry), abi.encodeWithSelector(TwapListingRegistryV2.repoint.selector), 0);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, address(priced)));
		module.list(address(priced), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotTwapPriced.selector, address(priced)));
		module.repoint(address(priced), makeAddr('q'), TwapListingRegistryV2.Venue.UniswapV3, 3000);
	}

	function test_listRepointPokeAreKeeperOnly() public {
		address q = makeAddr('q');
		// the keeper gate comes first: a stranger never reaches AlreadyPriced / NotTwapPriced / NotListed
		vm.startPrank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.list(address(priced), q, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.repoint(address(priced), q, TwapListingRegistryV2.Venue.UniswapV3, 3000);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.pokeFloor(address(priced));
		vm.stopPrank();
		// a keeper's poke passes the gate and reaches the registry, which answers for itself
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(TwapListingRegistryV2.NotListed.selector, address(priced)));
		module.pokeFloor(address(priced));
	}

	function test_setKeeperOwnerOnly() public {
		address newKeeper = makeAddr('newKeeper');
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		module.setKeeper(stranger, true);
		assertFalse(module.keepers(stranger));

		vm.expectRevert(PriceListingModule.ZeroAddress.selector);
		module.setKeeper(address(0), true);

		vm.expectEmit(address(module));
		emit PriceListingModule.KeeperSet(newKeeper, true);
		module.setKeeper(newKeeper, true);
		assertTrue(module.keepers(newKeeper));

		// revoking closes the gate again
		vm.expectEmit(address(module));
		emit PriceListingModule.KeeperSet(keeper, false);
		module.setKeeper(keeper, false);
		assertFalse(module.keepers(keeper));
		vm.prank(keeper);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.pokeFloor(address(priced));
	}
}

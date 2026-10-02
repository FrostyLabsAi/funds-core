// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ValueInterpreter} from '../src/core/ValueInterpreter.sol';
import {PriceListingModule} from '../src/pricing/PriceListingModule.sol';
import {TwapListingRegistryV2} from '../src/pricing/TwapListingRegistryV2.sol';
import {IValueInterpreter} from '../src/interfaces/IValueInterpreter.sol';
import {AggregatorV3Interface} from '../src/interfaces/AggregatorV3Interface.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ISlipstreamNonfungiblePositionManager} from
	'../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {CompounderPriceFeed} from '../src/pricing/CompounderPriceFeed.sol';
import {ICompounderRoles} from '../src/yield/FeeCompounderBase.sol';
import {SlipstreamFeeCompounder} from '../src/yield/SlipstreamFeeCompounder.sol';
import {CompounderFactory} from '../src/yield/CompounderFactory.sol';
import {MockERC20, MockAggregator} from './utils/Mocks.sol';
import {TestVenues} from './TwapListingRegistryV2.t.sol';
import {ScriptedPool} from './TwapAggregatorAdapter.t.sol';
import {ScriptedFactory} from './TwapListingRegistry.t.sol';
import {StubVenues, VenuePoolFactoryStub} from './CompounderFactory.t.sol';

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
	/// @dev the registry's Uniswap v3 venue: resolves MEME/USDC 0.3% to a scripted pool for a real TWAP listing
	ScriptedFactory internal twapUni;

	function setUp() public {
		vi = new ValueInterpreter(address(this));
		twapUni = new ScriptedFactory();
		registry = new TwapListingRegistryV2(
			TestVenues.build(
				IValueInterpreter(address(vi)),
				address(twapUni),
				makeAddr('s1'),
				makeAddr('s2'),
				makeAddr('s3'),
				makeAddr('uniV2'),
				makeAddr('aero')
			)
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

	// ─── listCompounder ─────────────────────────────────────────────────────────

	/// @dev Fixed addresses so each pair's token order is known (token0 = the lower address).
	address internal constant LOW = address(0x1000); // Chainlink-style primitive
	address internal constant MEME = address(0x1111); // TWAP-listed through this module
	address internal constant USDC = address(0x2222); // Chainlink-style primitive, the TWAP quote
	address internal constant UNP = address(0x3333); // no price
	address internal constant SIDE = address(0x4444); // zero-priced (side pocket)
	address internal constant HIGH = address(0x5555); // Chainlink-style primitive
	address internal constant DAO_SAFE = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	/// @dev MEME at $2,500 with a band and quote reserve at the registry's floor (as in its own tests)
	int24 internal constant TICK_2500 = -198_080;
	uint128 internal constant L_AT_RESERVE_FLOOR = 5e14;

	CompounderFactory internal cfactory;
	CompounderFactory.Venues internal cvenues;
	VenuePoolFactoryStub internal cpools; // the Slipstream-1 venue every test vault is made on
	CompounderPriceFeed internal cfeed;

	event CompounderListingSet(address indexed factory, address indexed feed);
	event CompounderListed(address indexed vault, address indexed feed, address indexed caller);
	event DerivativeAdded(address indexed asset, address indexed feed);

	function test_setCompounderListingOwnerOnlyOnce() public {
		(CompounderFactory f, CompounderPriceFeed feed) = _factoryAndFeed();
		PriceListingModule m = new PriceListingModule(vi, registry);

		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		m.setCompounderListing(f, address(feed));
		vm.expectRevert(PriceListingModule.ZeroAddress.selector);
		m.setCompounderListing(CompounderFactory(address(0)), address(feed));
		vm.expectRevert(PriceListingModule.ZeroAddress.selector);
		m.setCompounderListing(f, address(0));
		// a feed reading another VI would price the underlyings elsewhere
		CompounderPriceFeed otherFeed = new CompounderPriceFeed(IValueInterpreter(address(new ValueInterpreter(address(this)))));
		vm.expectRevert(PriceListingModule.ValueInterpreterMismatch.selector);
		m.setCompounderListing(f, address(otherFeed));

		vm.expectEmit(address(m));
		emit CompounderListingSet(address(f), address(feed));
		m.setCompounderListing(f, address(feed));
		assertEq(address(m.compounderFactory()), address(f));
		assertEq(m.compounderFeed(), address(feed));

		// settable once
		(CompounderFactory f2, CompounderPriceFeed feed2) = _factoryAndFeed();
		vm.expectRevert(PriceListingModule.CompounderListingAlreadySet.selector);
		m.setCompounderListing(f2, address(feed2));
		assertEq(address(m.compounderFactory()), address(f));
	}

	function test_listCompounderNeedsTheWiring() public {
		vm.prank(keeper);
		vm.expectRevert(PriceListingModule.CompounderListingNotSet.selector);
		module.listCompounder(makeAddr('vault'));
	}

	/// the keeper gate comes first: a stranger or the owner never reaches the factory or the VI
	function test_listCompounderIsKeeperOnly() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		vm.prank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.listCompounder(vault);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.listCompounder(vault);
		// the factory's creator is not a module keeper either
		assertTrue(cfactory.creators(address(this)));
		assertFalse(vi.isSupportedAsset(vault));

		vm.prank(keeper);
		module.listCompounder(vault);
		assertTrue(vi.isSupportedAsset(vault));
	}

	function test_keeperListsAValidVault() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		vm.expectEmit(address(vi));
		emit DerivativeAdded(vault, address(cfeed));
		vm.expectEmit(address(module));
		emit CompounderListed(vault, address(cfeed), keeper);
		vm.prank(keeper);
		module.listCompounder(vault);

		assertTrue(vi.isSupportedAsset(vault));
		(address aggregator,,,) = vi.getAssetInfo(vault);
		assertEq(aggregator, address(0), 'a derivative, not a primitive');
		// the VI prices it through the feed: an empty vault is worth nothing, without reverting
		assertEq(vi.calcUsdRate(vault), 0);
		// a second one on the same pair (another pool) lists too
		cpools.setPool(LOW, USDC, 200, makeAddr('LOW/USDC ts200'));
		address second = cfactory.create(CompounderFactory.Venue.Slipstream, LOW, USDC, 200);
		vm.prank(keeper);
		module.listCompounder(second);
		assertTrue(vi.isSupportedAsset(second));
	}

	/// only the wired factory's vaults: not the same code deployed by hand, not another factory's, not an EOA
	function test_refusesNonFactoryVault() public {
		_wireCompounders();
		address pool = makeAddr('LOW/USDC ts100');
		cpools.setPool(LOW, USDC, 100, pool);
		SlipstreamFeeCompounder imposter = new SlipstreamFeeCompounder(
			'Frosty Compounding LOW-USDC',
			'fcLOWUSDC',
			ISlipstreamNonfungiblePositionManager(cvenues.slipstreamNpm),
			IERC20(LOW),
			IERC20(USDC),
			100,
			1000,
			DAO_SAFE,
			address(this),
			ICompounderRoles(address(cfactory))
		);
		assertEq(imposter.pool(), pool, 'the same canonical pool');
		assertTrue(cfeed.isSupportedAsset(address(imposter)), 'the feed alone would take it');
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotFactoryCompounder.selector, address(imposter)));
		module.listCompounder(address(imposter));

		(CompounderFactory.Venues memory otherVenues, VenuePoolFactoryStub[4] memory otherPools) = StubVenues.build(true);
		otherPools[1].setPool(LOW, USDC, 100, pool);
		CompounderFactory otherFactory = new CompounderFactory(otherVenues);
		otherFactory.setCreator(address(this), true);
		address foreign = otherFactory.create(CompounderFactory.Venue.Slipstream, LOW, USDC, 100);
		assertTrue(otherFactory.isCompounder(foreign));
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotFactoryCompounder.selector, foreign));
		module.listCompounder(foreign);

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.NotFactoryCompounder.selector, stranger));
		module.listCompounder(stranger);
		assertFalse(vi.isSupportedAsset(address(imposter)));
		assertFalse(vi.isSupportedAsset(foreign));
	}

	function test_refusesAlreadyPriced() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		vm.prank(keeper);
		module.listCompounder(vault);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, vault));
		module.listCompounder(vault);

		// priced another way by governance first (here: zero-priced) — the keeper never overrides it
		address other = _vault(LOW, HIGH);
		module.execute(abi.encodeCall(ValueInterpreter.addZeroPricedAsset, (other)));
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.AlreadyPriced.selector, other));
		module.listCompounder(other);
	}

	/// an underlying must be a VI primitive: the VI resolves a derivative only into primitives, so an
	/// unpriced, side-pocket or derivative underlying would leave the share unpriceable
	function test_refusesUnpricedUnderlying() public {
		_wireCompounders();
		_expectUnpriced(_vault(UNP, HIGH), UNP); // token0
		_expectUnpriced(_vault(USDC, UNP), UNP); // token1

		assertTrue(vi.isSupportedAsset(SIDE), 'supported, but valued at zero with no feed');
		_expectUnpriced(_vault(SIDE, HIGH), SIDE);

		// a listed compounder's own share as an underlying (a derivative of a derivative)
		address listed = _vault(LOW, USDC);
		vm.prank(keeper);
		module.listCompounder(listed);
		assertTrue(vi.isSupportedAsset(listed));
		_expectUnpriced(_vault(listed, USDC), listed);
	}

	/// the cap-bypass guard: a TWAP-priced token on either side refuses the vault (the exposure
	/// policy caps TWAP assets but doesn't look through derivatives)
	function test_refusesTwapUnderlying() public {
		_wireCompounders();
		// MEME is a primitive (its adapter is the VI feed): only the TWAP guard can refuse it
		(address aggregator,,,) = vi.getAssetInfo(MEME);
		assertEq(aggregator, registry.adapterOf(MEME));
		assertTrue(registry.isTwapPriced(MEME));

		address asToken0 = _vault(MEME, USDC);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.TwapUnderlying.selector, MEME));
		module.listCompounder(asToken0);

		address asToken1 = _vault(LOW, MEME);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.TwapUnderlying.selector, MEME));
		module.listCompounder(asToken1);

		assertFalse(vi.isSupportedAsset(asToken0));
		assertFalse(vi.isSupportedAsset(asToken1));
	}

	// ─── governance block (ruling C6) ───────────────────────────────────────────

	event CompounderBlockedSet(address indexed vault, bool blocked);

	function test_setCompounderBlockedOwnerOnly() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		module.setCompounderBlocked(vault, true);
		// the keeper lists, it never blocks or unblocks
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
		module.setCompounderBlocked(vault, false);
		assertFalse(module.compounderBlocked(vault));

		vm.expectRevert(PriceListingModule.ZeroAddress.selector);
		module.setCompounderBlocked(address(0), true);

		vm.expectEmit(address(module));
		emit CompounderBlockedSet(vault, true);
		module.setCompounderBlocked(vault, true);
		assertTrue(module.compounderBlocked(vault));
		vm.expectEmit(address(module));
		emit CompounderBlockedSet(vault, false);
		module.setCompounderBlocked(vault, false);
		assertFalse(module.compounderBlocked(vault));
	}

	/// a governance delist (removeDerivative through `execute`, plus the block) sticks: the keeper's
	/// listCompounder can't put the vault back
	function test_governanceDelistSticks() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		vm.prank(keeper);
		module.listCompounder(vault);
		assertTrue(vi.isSupportedAsset(vault));

		module.execute(abi.encodeCall(ValueInterpreter.removeDerivative, (vault)));
		module.setCompounderBlocked(vault, true);
		assertFalse(vi.isSupportedAsset(vault), 'delisted');

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.CompounderBlocked.selector, vault));
		module.listCompounder(vault);
		assertFalse(vi.isSupportedAsset(vault), 'the keeper could not re-list it');

		// a block set before any listing holds the same way
		address other = _vault(LOW, HIGH);
		module.setCompounderBlocked(other, true);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.CompounderBlocked.selector, other));
		module.listCompounder(other);
		assertFalse(vi.isSupportedAsset(other));
	}

	/// without the block, the keeper re-lists a delisted vault (why the block exists); unblocking
	/// lets the keeper list it again
	function test_unblockAllowsRelisting() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		vm.prank(keeper);
		module.listCompounder(vault);

		uint256 snap = vm.snapshotState();
		module.execute(abi.encodeCall(ValueInterpreter.removeDerivative, (vault)));
		vm.prank(keeper);
		module.listCompounder(vault);
		assertTrue(vi.isSupportedAsset(vault), 'removeDerivative alone does not stick');
		vm.revertToState(snap);

		module.execute(abi.encodeCall(ValueInterpreter.removeDerivative, (vault)));
		module.setCompounderBlocked(vault, true);
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.CompounderBlocked.selector, vault));
		module.listCompounder(vault);

		module.setCompounderBlocked(vault, false);
		vm.expectEmit(address(module));
		emit CompounderListed(vault, address(cfeed), keeper);
		vm.prank(keeper);
		module.listCompounder(vault);
		assertTrue(vi.isSupportedAsset(vault), 'unblocked: listed again');
		(address[] memory underlyings,) = cfeed.calcUnderlyingValues(vault, 0);
		assertEq(underlyings[0], LOW);
		assertEq(underlyings[1], USDC);
	}

	/// the block is checked after the keeper gate: a stranger still learns nothing
	function test_blockedVaultStillKeeperGated() public {
		_wireCompounders();
		address vault = _vault(LOW, USDC);
		module.setCompounderBlocked(vault, true);
		vm.prank(stranger);
		vm.expectRevert(PriceListingModule.NotKeeper.selector);
		module.listCompounder(vault);
	}

	// ─── listCompounder helpers ─────────────────────────────────────────────────

	/// @dev A CompounderFactory on stub venues (this contract owns it) and a real CompounderPriceFeed on this VI.
	function _factoryAndFeed() internal returns (CompounderFactory f, CompounderPriceFeed feed) {
		(CompounderFactory.Venues memory v,) = StubVenues.build(true);
		f = new CompounderFactory(v);
		feed = new CompounderPriceFeed(IValueInterpreter(address(vi)));
	}

	/// @dev Wire a factory + feed into the module; price LOW, USDC, HIGH (Chainlink-style), SIDE
	///      (zero-priced) through governance; list MEME on the TWAP tier through the module's `list`.
	function _wireCompounders() internal {
		VenuePoolFactoryStub[4] memory f;
		(cvenues, f) = StubVenues.build(true);
		cpools = f[1];
		cfactory = new CompounderFactory(cvenues);
		cfactory.setCreator(address(this), true);
		cfeed = new CompounderPriceFeed(IValueInterpreter(address(vi)));
		module.setCompounderListing(cfactory, address(cfeed));

		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Low', 'LOW', uint8(18)), LOW);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Meme', 'MEME', uint8(18)), MEME);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('USD Coin', 'USDC', uint8(6)), USDC);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Unpriced', 'UNP', uint8(18)), UNP);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Side', 'SIDE', uint8(18)), SIDE);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('High', 'HIGH', uint8(18)), HIGH);
		address[3] memory primitives = [LOW, USDC, HIGH];
		for (uint256 i; i < 3; ++i) {
			module.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (primitives[i], address(new FixedFeed()), 3600)));
		}
		module.execute(abi.encodeCall(ValueInterpreter.addZeroPricedAsset, (SIDE)));

		// MEME/USDC 0.3% at $2,500 holding the $25k quote-reserve floor, listed by the keeper
		ScriptedPool pool = new ScriptedPool(MEME, USDC);
		pool.set(TICK_2500, TICK_2500, L_AT_RESERVE_FLOOR);
		deal(USDC, address(pool), 25_000e6);
		twapUni.setUni(MEME, USDC, 3000, address(pool));
		registry.setQuote(USDC, AggregatorV3Interface(address(new MockAggregator(8, 1e8))), 1 days);
		vm.prank(keeper);
		module.list(MEME, USDC, TwapListingRegistryV2.Venue.UniswapV3, 3000);
	}

	/// @dev A factory vault on the Slipstream-1 stub for `a`/`b` at spacing 100 (this contract is a creator).
	function _vault(address a, address b) internal returns (address) {
		cpools.setPool(a, b, 100, address(uint160(uint256(keccak256(abi.encode(a, b))))));
		return cfactory.create(CompounderFactory.Venue.Slipstream, a, b, 100);
	}

	function _expectUnpriced(address vault, address token) internal {
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(PriceListingModule.UnpricedUnderlying.selector, token));
		module.listCompounder(vault);
		assertFalse(vi.isSupportedAsset(vault));
	}
}

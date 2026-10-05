// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {FeeCompounderBase} from '../src/yield/FeeCompounderBase.sol';
import {
	CompounderDeployerBase,
	UniswapV3CompounderDeployer,
	SlipstreamCompounderDeployer
} from '../src/yield/CompounderDeployers.sol';
import {CompounderFactory} from '../src/yield/CompounderFactory.sol';
import {FundsMainnet} from '../script/mainnet/FundsMainnet.sol';
import {MockERC20} from './utils/Mocks.sol';

/// @dev A venue's pool factory as the CompounderFactory and the vaults read it: both getPool shapes
///      (Uniswap's uint24 fee, Slipstream's int24 tick spacing) and Uniswap's fee-tier spacing.
contract VenuePoolFactoryStub {
	mapping(bytes32 => address) internal pools;
	mapping(uint24 => int24) public feeAmountTickSpacing;

	function setPool(address a, address b, int256 tier, address pool) external {
		pools[_key(a, b, tier)] = pool;
	}

	function setFeeSpacing(uint24 fee, int24 spacing) external {
		feeAmountTickSpacing[fee] = spacing;
	}

	function getPool(address a, address b, uint24 fee) external view returns (address) {
		return pools[_key(a, b, int256(uint256(fee)))];
	}

	function getPool(address a, address b, int24 spacing) external view returns (address) {
		return pools[_key(a, b, int256(spacing))];
	}

	function _key(address a, address b, int256 tier) internal pure returns (bytes32) {
		(address x, address y) = a < b ? (a, b) : (b, a);
		return keccak256(abi.encode(x, y, tier));
	}
}

/// @dev The only position-manager read a vault's constructor makes: which pool factory it mints into.
contract PositionManagerStub {
	address public immutable factory;

	constructor(address factory_) {
		factory = factory_;
	}
}

/// @dev Approves like an ERC20 but answers symbol() as bytes32 (MKR-style): a string decode of it fails.
contract Bytes32SymbolToken {
	function symbol() external pure returns (bytes32) {
		return 'B32';
	}

	function approve(address, uint256) external pure returns (bool) {
		return true;
	}

	function allowance(address, address) external pure returns (uint256) {
		return 0;
	}
}

/// @dev Approves like an ERC20; symbol() reverts.
contract RevertingSymbolToken {
	function symbol() external pure returns (string memory) {
		revert('NO_SYMBOL');
	}

	function approve(address, uint256) external pure returns (bool) {
		return true;
	}

	function allowance(address, address) external pure returns (uint256) {
		return 0;
	}
}

/// @dev Four stub venues for unit tests: each pool factory with a position manager whose factory()
///      answers it. `withSlipstream3` false leaves venue 3 unset (create reverts VenueNotSupported).
library StubVenues {
	function build(bool withSlipstream3)
		internal
		returns (CompounderFactory.Venues memory v, VenuePoolFactoryStub[4] memory f)
	{
		for (uint256 i; i < 4; ++i) {
			f[i] = new VenuePoolFactoryStub();
		}
		v.uniswapV3Factory = address(f[0]);
		v.uniswapV3Npm = address(new PositionManagerStub(address(f[0])));
		v.slipstreamFactory = address(f[1]);
		v.slipstreamNpm = address(new PositionManagerStub(address(f[1])));
		v.slipstream2Factory = address(f[2]);
		v.slipstream2Npm = address(new PositionManagerStub(address(f[2])));
		v.slipstream3Factory = address(f[3]);
		if (withSlipstream3) v.slipstream3Npm = address(new PositionManagerStub(address(f[3])));
	}
}

interface IVaultVenue {
	function pool() external view returns (address);
	function positionManager() external view returns (address);
	function tickSpacing() external view returns (int24);
	function poolFee() external view returns (uint24);
}

/// @notice CompounderFactory without a fork: the creator and compounder roles, owner-only fee and
///         treasury controls forwarded to REAL vaults (built on stub venues: only the pool lookup a
///         vault's constructor makes is stubbed), paged treasury sync, the AlreadyExists /
///         PoolNotFound / VenueNotSupported paths, naming with its hex fallback, and deployers only
///         the factory can call.
contract CompounderFactoryTest is Test {
	address internal constant DAO_SAFE = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	/// @dev token0 / token1 of every stub pair (fixed addresses so the order is known)
	address internal constant AAA = address(0x1000);
	address internal constant BBB = address(0x2000);

	CompounderFactory internal factory;
	CompounderFactory.Venues internal venues;
	VenuePoolFactoryStub[4] internal pf;

	address internal creator = makeAddr('fundsKeeper');
	address internal workflow = makeAddr('workflowVaultWallet');
	address internal stranger = makeAddr('stranger');
	address internal poolU = makeAddr('poolUni3000');
	address internal poolS1 = makeAddr('poolSlip1ts100');
	address internal poolS2 = makeAddr('poolSlip2ts50');
	address internal poolS3 = makeAddr('poolSlip3ts50');

	event CreatorSet(address indexed account, bool allowed);
	event CompounderSet(address indexed account, bool allowed);
	event DefaultPerfFeeSet(uint16 bps);
	event TreasurySet(address treasury);
	event CompounderCreated(address indexed pool, address indexed vault, CompounderFactory.Venue venue);

	function setUp() public {
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Alpha', 'AAA', uint8(18)), AAA);
		deployCodeTo('Mocks.sol:MockERC20', abi.encode('Beta', 'BBB', uint8(6)), BBB);
		(venues, pf) = StubVenues.build(true);
		pf[0].setFeeSpacing(3000, 60);
		pf[0].setFeeSpacing(500, 10);
		pf[0].setPool(AAA, BBB, 3000, poolU);
		pf[1].setPool(AAA, BBB, 100, poolS1);
		pf[2].setPool(AAA, BBB, 50, poolS2);
		pf[3].setPool(AAA, BBB, 50, poolS3);
		factory = new CompounderFactory(venues);
		factory.setCreator(creator, true);
	}

	// ─── construction ───────────────────────────────────────────────────────────

	function test_initialState() public view {
		assertEq(factory.owner(), address(this));
		assertEq(factory.defaultPerfFeeBps(), 1000, 'starts at 10%');
		assertEq(factory.INITIAL_PERF_FEE_BPS(), 1000);
		assertEq(factory.treasury(), DAO_SAFE, 'fees go to the FrostyDAO Treasury Safe');
		assertEq(factory.DAO_TREASURY(), DAO_SAFE);
		assertEq(factory.uniswapV3Factory(), venues.uniswapV3Factory);
		assertEq(factory.uniswapV3Npm(), venues.uniswapV3Npm);
		assertEq(factory.slipstreamFactory(), venues.slipstreamFactory);
		assertEq(factory.slipstreamNpm(), venues.slipstreamNpm);
		assertEq(factory.slipstream2Factory(), venues.slipstream2Factory);
		assertEq(factory.slipstream2Npm(), venues.slipstream2Npm);
		assertEq(factory.slipstream3Factory(), venues.slipstream3Factory);
		assertEq(factory.slipstream3Npm(), venues.slipstream3Npm);
		assertEq(factory.uniswapV3Deployer().factory(), address(factory), 'the factory made its deployers');
		assertEq(factory.slipstreamDeployer().factory(), address(factory));
		assertEq(factory.compounderCount(), 0);
		// the venue indices match TwapListingRegistryV2.Venue's
		assertEq(uint8(CompounderFactory.Venue.UniswapV3), 0);
		assertEq(uint8(CompounderFactory.Venue.Slipstream), 1);
		assertEq(uint8(CompounderFactory.Venue.Slipstream2), 2);
		assertEq(uint8(CompounderFactory.Venue.Slipstream3), 3);
	}

	/// venues 0–2 need both addresses; venue 3 may be unset (both zero, or a zero manager)
	function test_constructorRejectsMissingVenue() public {
		for (uint256 i; i < 6; ++i) {
			CompounderFactory.Venues memory v = venues;
			if (i == 0) v.uniswapV3Factory = address(0);
			if (i == 1) v.uniswapV3Npm = address(0);
			if (i == 2) v.slipstreamFactory = address(0);
			if (i == 3) v.slipstreamNpm = address(0);
			if (i == 4) v.slipstream2Factory = address(0);
			if (i == 5) v.slipstream2Npm = address(0);
			vm.expectRevert(CompounderFactory.ZeroAddress.selector);
			new CompounderFactory(v);
		}
		CompounderFactory.Venues memory noThird = venues;
		noThird.slipstream3Npm = address(0);
		assertEq(new CompounderFactory(noThird).slipstream3Npm(), address(0));
		noThird.slipstream3Factory = address(0);
		assertEq(new CompounderFactory(noThird).slipstream3Factory(), address(0));
		// a third manager without its pool factory is refused
		CompounderFactory.Venues memory npmOnly = venues;
		npmOnly.slipstream3Factory = address(0);
		vm.expectRevert(CompounderFactory.ZeroAddress.selector);
		new CompounderFactory(npmOnly);
	}

	/// every manager must mint into the pool factory listed beside it, so the factory's pool and the vault's agree
	function test_constructorRejectsMismatchedManager() public {
		for (uint256 i; i < 4; ++i) {
			CompounderFactory.Venues memory v = venues;
			address wrong = address(new PositionManagerStub(makeAddr('otherPoolFactory')));
			if (i == 0) v.uniswapV3Npm = wrong;
			if (i == 1) v.slipstreamNpm = wrong;
			if (i == 2) v.slipstream2Npm = wrong;
			if (i == 3) v.slipstream3Npm = wrong;
			vm.expectRevert(abi.encodeWithSelector(CompounderFactory.NpmFactoryMismatch.selector, wrong));
			new CompounderFactory(v);
		}
		// swapped managers (each real, each another venue's) are refused too
		CompounderFactory.Venues memory swapped = venues;
		(swapped.slipstreamNpm, swapped.slipstream2Npm) = (venues.slipstream2Npm, venues.slipstreamNpm);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.NpmFactoryMismatch.selector, venues.slipstream2Npm));
		new CompounderFactory(swapped);
	}

	// ─── roles ──────────────────────────────────────────────────────────────────

	function test_createIsCreatorOnly() public {
		// the gate comes first: a stranger learns nothing about venues or pools
		vm.prank(stranger);
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		factory.create(CompounderFactory.Venue.Slipstream3, address(1), address(2), -1);
		// the owner is not a creator unless granted
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100);
		// a compounder is not a creator (each wallet gets only its own job)
		factory.setCompounder(workflow, true);
		vm.prank(workflow);
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100);

		vm.prank(creator);
		address vault = factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100);
		assertTrue(factory.isCompounder(vault));

		// revoking closes the gate
		factory.setCreator(creator, false);
		vm.prank(creator);
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		factory.create(CompounderFactory.Venue.Slipstream2, AAA, BBB, 50);
	}

	function test_setCreatorOwnerOnly() public {
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setCreator(stranger, true);
		assertFalse(factory.creators(stranger));
		// a creator cannot grant creators
		vm.prank(creator);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
		factory.setCreator(stranger, true);

		vm.expectRevert(CompounderFactory.ZeroAddress.selector);
		factory.setCreator(address(0), true);

		vm.expectEmit(address(factory));
		emit CreatorSet(stranger, true);
		factory.setCreator(stranger, true);
		assertTrue(factory.creators(stranger));
		vm.expectEmit(address(factory));
		emit CreatorSet(stranger, false);
		factory.setCreator(stranger, false);
		assertFalse(factory.creators(stranger));
	}

	/// the factory IS the vaults' role holder: its compounders mapping alone decides who may compound()
	function test_compounderRoleGatesEveryVault() public {
		vm.prank(creator);
		FeeCompounderBase vault = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100));
		assertEq(address(vault.roles()), address(factory));

		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setCompounder(stranger, true);
		vm.expectRevert(CompounderFactory.ZeroAddress.selector);
		factory.setCompounder(address(0), true);

		// nobody holds the role yet: not the creator, not the owner
		vm.prank(workflow);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();
		vm.prank(creator);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();

		vm.expectEmit(address(factory));
		emit CompounderSet(workflow, true);
		factory.setCompounder(workflow, true);
		assertTrue(factory.compounders(workflow));
		vm.prank(workflow);
		vault.compound(); // passes the gate (no position yet: nothing to harvest)

		vm.expectEmit(address(factory));
		emit CompounderSet(workflow, false);
		factory.setCompounder(workflow, false);
		vm.prank(workflow);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		vault.compound();
	}

	// ─── create ─────────────────────────────────────────────────────────────────

	function test_createOnEachVenue() public {
		address[4] memory pools = [poolU, poolS1, poolS2, poolS3];
		int24[4] memory tiers = [int24(3000), 100, 50, 50];
		for (uint256 i; i < 4; ++i) {
			CompounderFactory.Venue venue = CompounderFactory.Venue(i);
			address deployer =
				i == 0 ? address(factory.uniswapV3Deployer()) : address(factory.slipstreamDeployer());
			address expected = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
			vm.expectEmit(address(factory));
			emit CompounderCreated(pools[i], expected, venue);
			vm.prank(creator);
			// tokens passed in reverse order: the factory sorts them
			address vault = factory.create(venue, BBB, AAA, tiers[i]);
			assertEq(vault, expected);

			FeeCompounderBase c = FeeCompounderBase(vault);
			assertEq(IVaultVenue(vault).pool(), pools[i], 'the canonical pool');
			assertEq(IVaultVenue(vault).positionManager(), _npm(i), "the venue's own manager");
			assertEq(c.owner(), address(factory), 'the factory owns every vault');
			assertEq(address(c.roles()), address(factory), "compound() reads the factory's role");
			assertEq(address(c.token0()), AAA);
			assertEq(address(c.token1()), BBB);
			assertEq(c.perfFeeBps(), 1000);
			assertEq(c.treasury(), DAO_SAFE);
			assertEq(c.name(), 'Frosty Compounding AAA-BBB');
			assertEq(c.symbol(), 'fcAAABBB');
			if (i == 0) {
				assertEq(IVaultVenue(vault).poolFee(), 3000);
				assertEq(c.tickUpper(), 887_220, 'fee 3000 -> spacing 60');
			} else {
				assertEq(IVaultVenue(vault).tickSpacing(), tiers[i]);
				assertEq(c.tickUpper(), i == 1 ? int24(887_200) : int24(887_250));
			}
			assertEq(c.tickLower(), -c.tickUpper());

			assertTrue(factory.isCompounder(vault));
			assertEq(factory.compounderOf(pools[i]), vault);
			assertEq(factory.compounderCount(), i + 1);
			assertEq(factory.allCompounders()[i], vault);
		}
	}

	function test_oneVaultPerPool() public {
		vm.prank(creator);
		address vault = factory.create(CompounderFactory.Venue.Slipstream2, AAA, BBB, 50);
		// the same pool, either token order
		vm.prank(creator);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.AlreadyExists.selector, poolS2, vault));
		factory.create(CompounderFactory.Venue.Slipstream2, AAA, BBB, 50);
		vm.prank(creator);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.AlreadyExists.selector, poolS2, vault));
		factory.create(CompounderFactory.Venue.Slipstream2, BBB, AAA, 50);
		// another pool of the same pair is its own vault
		vm.prank(creator);
		address other = factory.create(CompounderFactory.Venue.Slipstream3, AAA, BBB, 50);
		assertTrue(other != vault);
		assertEq(factory.compounderCount(), 2);
	}

	function test_poolNotFound() public {
		vm.startPrank(creator);
		// a tier the venue has no pool for
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 200);
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.UniswapV3, AAA, BBB, 500);
		// a pool registered on one venue is not found on another
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 50);
		// zero / negative tiers are never asked about (a negative fee must not wrap into a uint24)
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.UniswapV3, AAA, BBB, 0);
		vm.stopPrank();

		pf[0].setPool(AAA, BBB, int256(uint256(type(uint24).max) - 3000 + 1), makeAddr('wrapped'));
		vm.prank(creator);
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.UniswapV3, AAA, BBB, -3000);
		pf[1].setPool(AAA, BBB, -100, makeAddr('negative'));
		vm.prank(creator);
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, -100);
		assertEq(factory.compounderCount(), 0);
	}

	function test_venueNotSupported() public {
		(CompounderFactory.Venues memory v, VenuePoolFactoryStub[4] memory f) = StubVenues.build(false);
		f[3].setPool(AAA, BBB, 50, poolS3); // even with a pool on its factory
		f[2].setPool(AAA, BBB, 50, poolS2);
		CompounderFactory twoSlipstreams = new CompounderFactory(v);
		twoSlipstreams.setCreator(creator, true);
		vm.prank(creator);
		vm.expectRevert(
			abi.encodeWithSelector(CompounderFactory.VenueNotSupported.selector, CompounderFactory.Venue.Slipstream3)
		);
		twoSlipstreams.create(CompounderFactory.Venue.Slipstream3, AAA, BBB, 50);
		// the other venues work
		vm.prank(creator);
		twoSlipstreams.create(CompounderFactory.Venue.Slipstream2, AAA, BBB, 50);
	}

	function test_nameFallsBackToShortHex() public {
		address b32 = address((uint160(0xABCDEF) << 136) | 1);
		address noSym = address((uint160(0xFEDCBA) << 136) | 2);
		deployCodeTo('CompounderFactory.t.sol:Bytes32SymbolToken', b32);
		deployCodeTo('CompounderFactory.t.sol:RevertingSymbolToken', noSym);
		pf[1].setPool(b32, BBB, 100, makeAddr('b32Pool'));
		pf[1].setPool(BBB, noSym, 100, makeAddr('noSymPool'));

		vm.startPrank(creator);
		FeeCompounderBase a = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream, b32, BBB, 100));
		FeeCompounderBase b = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream, noSym, BBB, 100));
		vm.stopPrank();
		// BBB (0x…2000) sorts before both
		assertEq(a.name(), 'Frosty Compounding BBB-0xabcdef');
		assertEq(a.symbol(), 'fcBBB0xabcdef');
		assertEq(b.name(), 'Frosty Compounding BBB-0xfedcba');
		assertEq(b.symbol(), 'fcBBB0xfedcba');
	}

	// ─── deployers ──────────────────────────────────────────────────────────────

	/// nobody but the factory mints a branded vault: not a stranger, the owner, a creator or a deployer's deployer
	function test_deployersOnlyAnswerTheFactory() public {
		UniswapV3CompounderDeployer uni = factory.uniswapV3Deployer();
		SlipstreamCompounderDeployer slip = factory.slipstreamDeployer();
		address[3] memory callers = [stranger, address(this), creator];
		for (uint256 i; i < 3; ++i) {
			// as a direct EOA call: msg.sender == tx.origin
			vm.prank(callers[i], callers[i]);
			vm.expectRevert(CompounderDeployerBase.NotFactory.selector);
			_deployUni(uni);
			vm.prank(callers[i], callers[i]);
			vm.expectRevert(CompounderDeployerBase.NotFactory.selector);
			_deploySlip(slip);
		}
		// the same arguments from the factory deploy: the refusals above are the caller check alone
		vm.startPrank(address(factory));
		FeeCompounderBase u = FeeCompounderBase(_deployUni(uni));
		FeeCompounderBase s = FeeCompounderBase(_deploySlip(slip));
		vm.stopPrank();
		assertEq(u.owner(), address(factory));
		assertEq(address(u.roles()), address(factory));
		assertEq(s.owner(), address(factory));
		assertEq(address(s.roles()), address(factory));
		// and a deployer anyone else creates answers only them, never this factory
		SlipstreamCompounderDeployer foreign = new SlipstreamCompounderDeployer();
		assertEq(foreign.factory(), address(this));
		vm.prank(address(factory));
		vm.expectRevert(CompounderDeployerBase.NotFactory.selector);
		_deploySlip(foreign);
	}

	// ─── owner controls ─────────────────────────────────────────────────────────

	function test_defaultPerfFeeBounds() public {
		// the factory's bounds are the vaults' own
		vm.prank(creator);
		FeeCompounderBase probe = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream3, AAA, BBB, 50));
		assertEq(factory.MIN_PERF_FEE_BPS(), probe.MIN_PERF_FEE_BPS());
		assertEq(factory.MAX_PERF_FEE_BPS(), probe.MAX_PERF_FEE_BPS());
		assertEq(factory.MIN_PERF_FEE_BPS(), 500);
		assertEq(factory.MAX_PERF_FEE_BPS(), 3000);

		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setDefaultPerfFee(2000);

		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.PerfFeeOutOfBounds.selector, uint16(499)));
		factory.setDefaultPerfFee(499);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.PerfFeeOutOfBounds.selector, uint16(3001)));
		factory.setDefaultPerfFee(3001);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.PerfFeeOutOfBounds.selector, uint16(0)));
		factory.setDefaultPerfFee(0);
		assertEq(factory.defaultPerfFeeBps(), 1000);

		vm.expectEmit(address(factory));
		emit DefaultPerfFeeSet(500);
		factory.setDefaultPerfFee(500);
		assertEq(factory.defaultPerfFeeBps(), 500, '5% inclusive');
		vm.prank(creator);
		FeeCompounderBase atMin = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100));
		assertEq(atMin.perfFeeBps(), 500, 'new vaults take the default');

		factory.setDefaultPerfFee(3000);
		assertEq(factory.defaultPerfFeeBps(), 3000, '30% inclusive');
		vm.prank(creator);
		FeeCompounderBase atMax = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream2, AAA, BBB, 50));
		assertEq(atMax.perfFeeBps(), 3000);
		assertEq(atMin.perfFeeBps(), 500, 'existing vaults keep theirs');
	}

	function test_setPerfFeeIsForwardedAndBounded() public {
		vm.prank(creator);
		FeeCompounderBase vault = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100));

		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setPerfFee(address(vault), 2000);
		// the factory's owner holds no power over a vault directly
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
		vault.setPerfFee(2000);
		// only factory vaults are forwarded to
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.UnknownVault.selector, stranger));
		factory.setPerfFee(stranger, 2000);

		vm.expectRevert(abi.encodeWithSelector(FeeCompounderBase.PerfFeeOutOfBounds.selector, uint16(499)));
		factory.setPerfFee(address(vault), 499);
		vm.expectRevert(abi.encodeWithSelector(FeeCompounderBase.PerfFeeOutOfBounds.selector, uint16(3001)));
		factory.setPerfFee(address(vault), 3001);
		assertEq(vault.perfFeeBps(), 1000);

		factory.setPerfFee(address(vault), 3000);
		assertEq(vault.perfFeeBps(), 3000);
		factory.setPerfFee(address(vault), 500);
		assertEq(vault.perfFeeBps(), 500);
	}

	function test_setTreasuryThenPagedSync() public {
		address[] memory made = _createFive();
		address newTreasury = makeAddr('newTreasury');

		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setTreasury(newTreasury);
		vm.expectRevert(CompounderFactory.ZeroAddress.selector);
		factory.setTreasury(address(0));

		vm.expectEmit(address(factory));
		emit TreasurySet(newTreasury);
		factory.setTreasury(newTreasury);
		assertEq(factory.treasury(), newTreasury);
		for (uint256 i; i < 5; ++i) {
			assertEq(FeeCompounderBase(made[i]).treasury(), DAO_SAFE, 'vaults move only when synced');
		}

		// one page at a time: anyone may push the factory's treasury
		vm.prank(stranger);
		assertEq(factory.syncTreasury(0, 2), 2, 'the next offset');
		_assertTreasuries(made, newTreasury, 2);
		vm.prank(stranger);
		assertEq(factory.syncTreasury(2, 2), 4);
		_assertTreasuries(made, newTreasury, 4);
		assertEq(factory.syncTreasury(4, type(uint256).max), 5, 'an unbounded limit never overflows');
		_assertTreasuries(made, newTreasury, 5);
		assertEq(factory.syncTreasury(5, 10), 5, 'past the end: nothing');
		assertEq(factory.syncTreasury(9, 10), 5);
		// a synced vault is skipped: no second TreasurySet
		vm.recordLogs();
		factory.syncTreasury(0, 5);
		assertEq(vm.getRecordedLogs().length, 0);

		// a vault created after the change starts on the new treasury
		vm.prank(creator);
		FeeCompounderBase later = FeeCompounderBase(factory.create(CompounderFactory.Venue.UniswapV3, AAA, BBB, 500));
		assertEq(later.treasury(), newTreasury);
	}

	function test_syncTreasuryLimitBoundsTheWork() public {
		address[] memory made = _createFive();
		factory.setTreasury(makeAddr('newTreasury'));
		// exactly `limit` vaults are written, from `offset`
		for (uint256 i; i < 5; ++i) {
			vm.expectCall(made[i], abi.encodeCall(FeeCompounderBase.setTreasury, (makeAddr('newTreasury'))), i == 1 || i == 2 ? 1 : 0);
		}
		assertEq(factory.syncTreasury(1, 2), 3);
	}

	function test_sweepUntrackedGoesToTheCurrentTreasury() public {
		vm.prank(creator);
		FeeCompounderBase vault = FeeCompounderBase(factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100));
		MockERC20(AAA).mint(address(vault), 7e18); // a donation: untracked
		address stray = address(new MockERC20('Stray', 'STR', 18));
		MockERC20(stray).mint(address(vault), 3e18);

		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.sweepUntracked(address(vault), IERC20(AAA));
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.UnknownVault.selector, stranger));
		factory.sweepUntracked(stranger, IERC20(AAA));

		// the treasury moves but this vault is not synced: the sweep still pays the CURRENT one
		address newTreasury = makeAddr('newTreasury');
		factory.setTreasury(newTreasury);
		assertEq(vault.treasury(), DAO_SAFE);
		assertEq(factory.sweepUntracked(address(vault), IERC20(AAA)), 7e18);
		assertEq(factory.sweepUntracked(address(vault), IERC20(stray)), 3e18);
		assertEq(IERC20(AAA).balanceOf(newTreasury), 7e18);
		assertEq(IERC20(stray).balanceOf(newTreasury), 3e18);
		assertEq(IERC20(AAA).balanceOf(DAO_SAFE), 0);
	}

	function test_compoundersPage() public {
		address[] memory made = _createFive();
		address[] memory page = factory.compoundersPage(0, 2);
		assertEq(page.length, 2);
		assertEq(page[0], made[0]);
		assertEq(page[1], made[1]);
		page = factory.compoundersPage(3, 5);
		assertEq(page.length, 2, 'a page past the end is clipped');
		assertEq(page[0], made[3]);
		assertEq(page[1], made[4]);
		assertEq(factory.compoundersPage(5, 1).length, 0);
		page = factory.compoundersPage(1, type(uint256).max);
		assertEq(page.length, 4, 'an unbounded limit never overflows');
		assertEq(page[3], made[4]);
		assertEq(factory.allCompounders().length, 5);
	}

	// ─── helpers ────────────────────────────────────────────────────────────────

	function _npm(uint256 i) internal view returns (address) {
		if (i == 0) return venues.uniswapV3Npm;
		if (i == 1) return venues.slipstreamNpm;
		if (i == 2) return venues.slipstream2Npm;
		return venues.slipstream3Npm;
	}

	function _createFive() internal returns (address[] memory made) {
		pf[1].setPool(AAA, BBB, 200, makeAddr('poolSlip1ts200'));
		made = new address[](5);
		vm.startPrank(creator);
		made[0] = factory.create(CompounderFactory.Venue.UniswapV3, AAA, BBB, 3000);
		made[1] = factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 100);
		made[2] = factory.create(CompounderFactory.Venue.Slipstream, AAA, BBB, 200);
		made[3] = factory.create(CompounderFactory.Venue.Slipstream2, AAA, BBB, 50);
		made[4] = factory.create(CompounderFactory.Venue.Slipstream3, AAA, BBB, 50);
		vm.stopPrank();
		pf[0].setPool(AAA, BBB, 500, makeAddr('poolUni500'));
	}

	function _assertTreasuries(address[] memory made, address newTreasury, uint256 syncedUpTo) internal view {
		for (uint256 i; i < made.length; ++i) {
			assertEq(FeeCompounderBase(made[i]).treasury(), i < syncedUpTo ? newTreasury : DAO_SAFE);
		}
	}

	function _deployUni(UniswapV3CompounderDeployer d) internal returns (address) {
		return d.deploy(
			CompounderDeployerBase.VaultParams({
				name: 'Frosty Compounding AAA-BBB',
				symbol: 'fcAAABBB',
				positionManager: venues.uniswapV3Npm,
				token0: AAA,
				token1: BBB,
				feeOrTickSpacing: 3000,
				perfFeeBps: 1000,
				treasury: DAO_SAFE
			})
		);
	}

	function _deploySlip(SlipstreamCompounderDeployer d) internal returns (address) {
		return d.deploy(
			CompounderDeployerBase.VaultParams({
				name: 'Frosty Compounding AAA-BBB',
				symbol: 'fcAAABBB',
				positionManager: venues.slipstreamNpm,
				token0: AAA,
				token1: BBB,
				feeOrTickSpacing: 100,
				perfFeeBps: 1000,
				treasury: DAO_SAFE
			})
		);
	}
}

/// @notice The factory on REAL Base venues: each of the four position managers (Slipstream-3's
///         verified on-chain, below) makes a working vault for the venue's WETH/USDC pool — named
///         from the tokens' own symbols, owned by the factory, compound() gated by the factory's
///         role, the fee changed through the factory on a live position, a deposit in and out —
///         and real misses (no pool, a duplicate) are refused.
///         Every address was read with `cast` at block 52014634:
///         - each NPM's factory(): Uniswap 0x03a5…34f1 → 0x3312…FDfD, Slipstream-1 0x8279…5b72 →
///           0x5e7B…809A, Slipstream-2 0xe1f8…8b53 → 0xf8f2…61Ef, Slipstream-3 0xa990…D55F → 0xaDe6…716a;
///         - Slipstream-3's NPM is the "Gauge Caps Deployment" NonfungiblePositionManager in
///           aerodrome-finance/slipstream's README, beside PoolFactory 0xaDe6…716a and SwapRouter
///           0xcbBb…Ce0D (whose factory() also answers 0xaDe6…716a); name() "Slipstream Position NFT v1";
///         - Slipstream-3 getPool(WETH, USDC, 50) = 0xc758…54e0 (0.52 WETH + 4,137 USDC); spacing 100 → 0.
///         Run: BASE_MAINNET_RPC=<url> BASE_FORK_BLOCK=52014634 forge test --match-path test/CompounderFactory.t.sol -j 1 -vv
contract CompounderFactoryForkTest is Test {
	address internal constant WETH = FundsMainnet.WETH;
	address internal constant USDC = FundsMainnet.USDC;
	address internal constant DAO_SAFE = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant CL3_NPM = 0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F;

	address internal constant UNI_WETH_USDC_3000 = 0x6c561B446416E1A00E8E93E221854d6eA4171372;
	address internal constant SLIP1_WETH_USDC_100 = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59;
	address internal constant SLIP2_WETH_USDC_50 = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A;
	address internal constant SLIP3_WETH_USDC_50 = 0xc758d81B9b81A6FCDAd075bD471874A2c46B54e0;

	bool internal forked;
	CompounderFactory internal factory;
	address internal creator = makeAddr('fundsKeeper');
	address internal workflow = makeAddr('workflowVaultWallet');
	address internal alice = makeAddr('alice');
	address internal stranger = makeAddr('stranger');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		uint256 blockNumber = vm.envOr('BASE_FORK_BLOCK', uint256(0));
		if (blockNumber > 0) vm.createSelectFork(rpc, blockNumber);
		else vm.createSelectFork(rpc);
		forked = true;

		factory = new CompounderFactory(_mainnetVenues());
		factory.setCreator(creator, true);
		factory.setCompounder(workflow, true);
	}

	function test_fork_constructorChecksEachManager() public {
		vm.skip(!forked);
		assertEq(factory.slipstream3Npm(), CL3_NPM);
		CompounderFactory.Venues memory v = _mainnetVenues();
		// Slipstream-2's manager listed as Slipstream-3's: it mints into another factory
		v.slipstream3Npm = FundsMainnet.CL2_NPM;
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.NpmFactoryMismatch.selector, FundsMainnet.CL2_NPM));
		new CompounderFactory(v);
		v = _mainnetVenues();
		v.uniswapV3Npm = FundsMainnet.CL_NPM;
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.NpmFactoryMismatch.selector, FundsMainnet.CL_NPM));
		new CompounderFactory(v);
	}

	function test_fork_uniswapV3() public {
		vm.skip(!forked);
		_roundTrip(CompounderFactory.Venue.UniswapV3, 3000, UNI_WETH_USDC_3000, FundsMainnet.UNI_NPM, 887_220);
	}

	function test_fork_slipstream1() public {
		vm.skip(!forked);
		_roundTrip(CompounderFactory.Venue.Slipstream, 100, SLIP1_WETH_USDC_100, FundsMainnet.CL_NPM, 887_200);
	}

	function test_fork_slipstream2() public {
		vm.skip(!forked);
		_roundTrip(CompounderFactory.Venue.Slipstream2, 50, SLIP2_WETH_USDC_50, FundsMainnet.CL2_NPM, 887_250);
	}

	function test_fork_slipstream3() public {
		vm.skip(!forked);
		_roundTrip(CompounderFactory.Venue.Slipstream3, 50, SLIP3_WETH_USDC_50, CL3_NPM, 887_250);
	}

	function test_fork_realMissesRefused() public {
		vm.skip(!forked);
		vm.startPrank(creator);
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.Slipstream3, WETH, USDC, 100);
		vm.expectRevert(CompounderFactory.PoolNotFound.selector);
		factory.create(CompounderFactory.Venue.UniswapV3, WETH, USDC, 3001);
		vm.stopPrank();
		vm.prank(stranger);
		vm.expectRevert(CompounderFactory.NotCreator.selector);
		factory.create(CompounderFactory.Venue.Slipstream, WETH, USDC, 100);
	}

	function _roundTrip(CompounderFactory.Venue venue, int24 tier, address pool, address npm, int24 fullRange) internal {
		vm.prank(creator);
		address vault = factory.create(venue, USDC, WETH, tier);
		FeeCompounderBase c = FeeCompounderBase(vault);

		assertEq(IVaultVenue(vault).pool(), pool, 'the canonical pool');
		assertEq(IVaultVenue(vault).positionManager(), npm);
		assertEq(factory.compounderOf(pool), vault);
		assertEq(c.name(), 'Frosty Compounding WETH-USDC');
		assertEq(c.symbol(), 'fcWETHUSDC');
		assertEq(address(c.token0()), WETH);
		assertEq(address(c.token1()), USDC);
		assertEq(c.tickUpper(), fullRange);
		assertEq(c.tickLower(), -fullRange);
		assertEq(c.owner(), address(factory));
		assertEq(address(c.roles()), address(factory));
		assertEq(c.perfFeeBps(), 1000);
		assertEq(c.treasury(), DAO_SAFE);

		vm.prank(creator);
		vm.expectRevert(abi.encodeWithSelector(CompounderFactory.AlreadyExists.selector, pool, vault));
		factory.create(venue, WETH, USDC, tier);

		// a real position through the venue's manager
		deal(WETH, alice, 0.01 ether);
		deal(USDC, alice, 100e6);
		vm.startPrank(alice);
		IERC20(WETH).approve(vault, 0.01 ether);
		IERC20(USDC).approve(vault, 100e6);
		uint256 shares = c.deposit(0.01 ether, 100e6, 0, 0, 0);
		vm.stopPrank();
		assertGt(shares, 0);
		assertEq(IERC721(npm).ownerOf(c.tokenId()), vault, 'the vault holds its own NFT');
		(uint128 liquidity,,) = c.positionState();
		assertEq(uint256(liquidity), shares + c.MIN_BOOTSTRAP_SHARES());

		// compound(): the factory's compounder role only
		vm.prank(stranger);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		c.compound();
		vm.prank(creator);
		vm.expectRevert(FeeCompounderBase.NotCompounder.selector);
		c.compound();
		vm.prank(workflow);
		c.compound();

		// governance moves the fee through the factory on a live position (harvests first)
		factory.setPerfFee(vault, 2000);
		assertEq(c.perfFeeBps(), 2000);

		vm.prank(alice);
		(uint256 out0, uint256 out1) = c.withdraw(shares, 0, 0);
		assertGt(out0, 0);
		assertGt(out1, 0);
		assertEq(c.balanceOf(alice), 0);
		assertLe(out0, 0.01 ether);
		assertLe(out1, 100e6);
	}

	function _mainnetVenues() internal pure returns (CompounderFactory.Venues memory v) {
		v.uniswapV3Factory = FundsMainnet.UNI_FACTORY;
		v.uniswapV3Npm = FundsMainnet.UNI_NPM;
		v.slipstreamFactory = FundsMainnet.CL_FACTORY;
		v.slipstreamNpm = FundsMainnet.CL_NPM;
		v.slipstream2Factory = FundsMainnet.CL2_FACTORY;
		v.slipstream2Npm = FundsMainnet.CL2_NPM;
		v.slipstream3Factory = FundsMainnet.CL3_FACTORY;
		v.slipstream3Npm = CL3_NPM;
	}
}

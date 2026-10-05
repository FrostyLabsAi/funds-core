// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {Strings} from '@openzeppelin/contracts/utils/Strings.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {IValueInterpreter} from '../../src/interfaces/IValueInterpreter.sol';
import {ISlipstreamNonfungiblePositionManager} from
	'../../src/interfaces/external/ISlipstreamNonfungiblePositionManager.sol';
import {CompounderAdapter} from '../../src/adapters/CompounderAdapter.sol';
import {CompounderPriceFeed} from '../../src/pricing/CompounderPriceFeed.sol';
import {CompounderFactory, IPositionManagerFactory} from '../../src/yield/CompounderFactory.sol';
import {SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @notice The live Veranta Referral's code registry (proxy 0x1A11…E82D, Referral.sol verified on Blockscout).
interface IVerantaReferralCodes {
	function codeOwners(bytes32 code) external view returns (address);
}

/// @title CompoundersMainnet
/// @notice Fee compounders and the fee-taking position types wired into the LIVE Base genesis as
///         code — one library the broadcast script (DeployCompoundersMainnet) and the fork acceptance
///         test (test/fork/CompoundersMainnetFork, retired 2026-10-04 with the TWAP tier it was built on;
///         the vaults, LP V2 and perp V3 keep their own fork suites) both ran, so what was rehearsed shipped.
///         Ran 2026-10-01, after TwapListingV2, as the genesis deployer (owner of the FundFactory). It:
///           1. deploys a CompounderPriceFeed (on the VI) and a CompounderAdapter (existing code, new
///              addresses) and the CompounderFactory over Uniswap v3 and Slipstream 1/2/3 (perf fee
///              10%, treasury = the FrostyDAO Treasury Safe), and grants its creator / compounder
///              roles when given;
///           2. registers the adapter on the FundFactory;
///           3. re-points position types 4 and 7 to SlipstreamLPPositionV2 factories (10% AERO claim
///              fee to the Safe) and type 6 to the VerantaPerpPositionV3 factory over the live V2
///              factory (perp accounts link the DAO's referral code at creation). Only
///              createExternalPosition reads the type table, so existing positions keep their code.
///         It refuses to start unless the founder's referral ops are done (fail closed): the Safe
///         owns the code `frostydao` on Veranta's Referral and the V2 perp factory points at it.
///         {verify} then proves the end state or reverts. The deployer ends as owner of the
///         CompounderFactory and both Slipstream V2 factories; FundsGovernance moves them on, as the
///         last launch step — nothing here transfers ownership.
///         2026-10-04 (pool-pricing switch-over): step 2 also wired the PriceListingModule's keeper
///         listing of new vaults (`setCompounderListing`). The module no longer owns the VI and its
///         source is gone, so that step and its check are removed; a vault is listed in the VI by the
///         VI's owner (the PoolPriceRegistrar's `execute`, YieldListing / ListYieldVaults).
library CompoundersMainnet {
	/// @notice FrostyDAO Treasury Safe (Safe v1.4.1, 2-of-3): every fee lands here and it owns `frostydao`.
	address internal constant DAO_TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	/// @notice The DAO's Veranta referral code (founder 2026-10-01: registered by the Safe).
	bytes32 internal constant REFERRAL_CODE = 'frostydao';
	uint16 internal constant PERF_FEE_BPS = 1000;
	uint16 internal constant AERO_FEE_BPS = 1000;

	struct Config {
		address deployer; // the broadcasting EOA — owns the FundFactory until the handoff
		ValueInterpreter valueInterpreter;
		FundFactory factory;
		VerantaPerpPositionV2Factory verantaFactory; // the live type-6 factory: V3 accounts' config
		address creator; // CompounderFactory creator (the funds-keeper wallet); zero = set later
		address compounder; // CompounderFactory compounder role (the FrostyFi workflow wallet); zero = set later
	}

	struct Deployed {
		CompounderPriceFeed feed;
		CompounderAdapter adapter;
		CompounderFactory compounderFactory;
		SlipstreamLPPositionV2Factory slipstreamLp; // type 4 (Slipstream-1)
		SlipstreamLPPositionV2Factory slipstream2Lp; // type 7 (Slipstream-2)
		VerantaPerpPositionV3Factory perpV3; // type 6
	}

	error BadConfig();
	error ReferralNotReady(string reason);
	error WrongOwner(address target, address owner);
	error StillPending(address target, address pending);
	error AdapterNotRegistered(address adapter);
	error FeedMismatch(address valueInterpreter);
	error VenueMismatch(string venue, address stored, address expected);
	error NpmFactoryMismatch(address npm, address factory);
	error DefaultsMismatch(uint16 perfFeeBps, address treasury);
	error PositionTypeMismatch(uint256 typeId, address stored, address expected);
	error LpFactoryMismatch(address lpFactory, address npm, uint16 aeroFeeBps, address treasury);
	error PerpConfigMismatch(address config);
	error HasOwner(address target);
	error RoleMismatch(address account);
	error DeployerHoldsRole();

	/// @notice Deploy and wire everything (steps 1–3), then {verify}.
	function deploy(Config memory cfg) internal returns (Deployed memory d) {
		_checkPreconditions(cfg);

		d.feed = new CompounderPriceFeed(IValueInterpreter(address(cfg.valueInterpreter)));
		d.adapter = new CompounderAdapter();
		d.compounderFactory = new CompounderFactory(venues());
		cfg.factory.registerAdapter(address(d.adapter));
		if (cfg.creator != address(0)) d.compounderFactory.setCreator(cfg.creator, true);
		if (cfg.compounder != address(0)) d.compounderFactory.setCompounder(cfg.compounder, true);

		d.slipstreamLp = new SlipstreamLPPositionV2Factory(ISlipstreamNonfungiblePositionManager(FundsMainnet.CL_NPM));
		d.slipstream2Lp = new SlipstreamLPPositionV2Factory(ISlipstreamNonfungiblePositionManager(FundsMainnet.CL2_NPM));
		cfg.factory.registerPositionType(FundsMainnet.SLIPSTREAM_LP_TYPE, address(d.slipstreamLp));
		cfg.factory.registerPositionType(FundsMainnet.SLIPSTREAM2_LP_TYPE, address(d.slipstream2Lp));
		d.perpV3 = new VerantaPerpPositionV3Factory(cfg.verantaFactory);
		cfg.factory.registerPositionType(FundsMainnet.VERANTA_PERP_TYPE, address(d.perpV3));

		verify(cfg, d);
	}

	/// @notice The four venues the CompounderFactory serves (Slipstream-3's NPM verified 2026-10-01).
	function venues() internal pure returns (CompounderFactory.Venues memory v) {
		v.uniswapV3Factory = FundsMainnet.UNI_FACTORY;
		v.uniswapV3Npm = FundsMainnet.UNI_NPM;
		v.slipstreamFactory = FundsMainnet.CL_FACTORY;
		v.slipstreamNpm = FundsMainnet.CL_NPM;
		v.slipstream2Factory = FundsMainnet.CL2_FACTORY;
		v.slipstream2Npm = FundsMainnet.CL2_NPM;
		v.slipstream3Factory = FundsMainnet.CL3_FACTORY;
		v.slipstream3Npm = FundsMainnet.CL3_NPM;
	}

	/// @notice Empty when the founder's referral ops are done; otherwise what is missing and which
	///         op fixes it (runbook "Fees + referral", in order).
	function referralProblem(VerantaPerpPositionV2Factory verantaFactory) internal view returns (string memory) {
		address codeOwner = IVerantaReferralCodes(FundsMainnet.VERANTA_REFERRAL).codeOwners(REFERRAL_CODE);
		if (codeOwner != DAO_TREASURY) {
			return string.concat(
				'founder op 1 missing: Veranta Referral 0x1A11...De82D codeOwners("frostydao") = ',
				Strings.toHexString(codeOwner),
				', not the DAO Treasury Safe 0x47b7...fF0A (unregistered: the Treasury Safe sends registerCode("frostydao");',
				' held by another account: it sends setPendingCodeOwnershipTransfer("frostydao", Treasury Safe), then the',
				' Treasury Safe sends acceptCodeOwnership("frostydao"))'
			);
		}
		if (address(verantaFactory.referral()) != FundsMainnet.VERANTA_REFERRAL) {
			return 'founder op 2 missing: the V2 perp factory referral() is not the Veranta Referral 0x1A11...De82D (the deployer sends setReferral(0x1A11...De82D, "frostydao"))';
		}
		if (verantaFactory.referralCode() != REFERRAL_CODE) {
			return 'founder op 2 missing: the V2 perp factory referralCode() is not "frostydao" (the deployer sends setReferral(0x1A11...De82D, "frostydao"))';
		}
		return '';
	}

	/// @notice Revert on the first thing not where the wiring says it must be.
	function verify(Config memory cfg, Deployed memory d) internal view {
		_requireReferralReady(cfg.verantaFactory);
		if (!cfg.factory.isAdapterRegistered(address(d.adapter))) revert AdapterNotRegistered(address(d.adapter));
		address feedVi = address(d.feed.valueInterpreter());
		if (feedVi != address(cfg.valueInterpreter)) revert FeedMismatch(feedVi);
		_checkCompounderFactory(cfg, d.compounderFactory);
		_checkPositionTypes(cfg, d);
		_checkOwned(address(d.compounderFactory), cfg.deployer);
		_checkOwned(address(d.slipstreamLp), cfg.deployer);
		_checkOwned(address(d.slipstream2Lp), cfg.deployer);
		// nothing else this deploy made needs a handoff
		if (_hasOwner(address(d.perpV3))) revert HasOwner(address(d.perpV3));
		if (_hasOwner(address(d.feed))) revert HasOwner(address(d.feed));
		if (_hasOwner(address(d.adapter))) revert HasOwner(address(d.adapter));
	}

	function _checkPreconditions(Config memory cfg) private view {
		if (
			cfg.deployer == address(0) || address(cfg.valueInterpreter) == address(0) || address(cfg.factory) == address(0)
				|| address(cfg.verantaFactory) == address(0)
		) revert BadConfig();
		// the deployer's powers all move to governance; it must not keep a compounder role
		if (cfg.creator == cfg.deployer || cfg.compounder == cfg.deployer) revert BadConfig();
		_requireReferralReady(cfg.verantaFactory);
		// the deployer still owns the factory (before the handoff)
		if (cfg.factory.owner() != cfg.deployer) revert WrongOwner(address(cfg.factory), cfg.factory.owner());
	}

	function _requireReferralReady(VerantaPerpPositionV2Factory verantaFactory) private view {
		string memory problem = referralProblem(verantaFactory);
		if (bytes(problem).length != 0) revert ReferralNotReady(problem);
	}

	/// @dev Venues are the mainnet constants and each NPM mints into its listed pool factory; the
	///      defaults are 10% to the DAO Safe; the roles are exactly the configured ones, never the deployer's.
	function _checkCompounderFactory(Config memory cfg, CompounderFactory f) private view {
		CompounderFactory.Venues memory v = venues();
		_checkVenue('uniswapV3', f.uniswapV3Factory(), f.uniswapV3Npm(), v.uniswapV3Factory, v.uniswapV3Npm);
		_checkVenue('slipstream', f.slipstreamFactory(), f.slipstreamNpm(), v.slipstreamFactory, v.slipstreamNpm);
		_checkVenue('slipstream2', f.slipstream2Factory(), f.slipstream2Npm(), v.slipstream2Factory, v.slipstream2Npm);
		_checkVenue('slipstream3', f.slipstream3Factory(), f.slipstream3Npm(), v.slipstream3Factory, v.slipstream3Npm);
		if (f.defaultPerfFeeBps() != PERF_FEE_BPS || f.treasury() != DAO_TREASURY) {
			revert DefaultsMismatch(f.defaultPerfFeeBps(), f.treasury());
		}
		if (f.creators(cfg.deployer) || f.compounders(cfg.deployer)) revert DeployerHoldsRole();
		if (cfg.creator != address(0) && !f.creators(cfg.creator)) revert RoleMismatch(cfg.creator);
		if (cfg.compounder != address(0) && !f.compounders(cfg.compounder)) revert RoleMismatch(cfg.compounder);
	}

	function _checkVenue(string memory venue, address poolFactory, address npm, address expectedFactory, address expectedNpm)
		private
		view
	{
		if (poolFactory != expectedFactory) revert VenueMismatch(venue, poolFactory, expectedFactory);
		if (npm != expectedNpm) revert VenueMismatch(venue, npm, expectedNpm);
		address minted = IPositionManagerFactory(npm).factory();
		if (minted != poolFactory) revert NpmFactoryMismatch(npm, minted);
	}

	/// @dev Types 4 / 7 / 6 answer the new factories; the LP factories mint through Slipstream-1 / -2
	///      (each NPM into its own pool factory) at 10% to the DAO Safe; V3 reads the live V2 config.
	function _checkPositionTypes(Config memory cfg, Deployed memory d) private view {
		_checkType(cfg.factory, FundsMainnet.SLIPSTREAM_LP_TYPE, address(d.slipstreamLp));
		_checkType(cfg.factory, FundsMainnet.SLIPSTREAM2_LP_TYPE, address(d.slipstream2Lp));
		_checkType(cfg.factory, FundsMainnet.VERANTA_PERP_TYPE, address(d.perpV3));
		_checkLpFactory(d.slipstreamLp, FundsMainnet.CL_NPM, FundsMainnet.CL_FACTORY);
		_checkLpFactory(d.slipstream2Lp, FundsMainnet.CL2_NPM, FundsMainnet.CL2_FACTORY);
		address config = address(d.perpV3.config());
		if (config != address(cfg.verantaFactory)) revert PerpConfigMismatch(config);
	}

	function _checkType(FundFactory factory, uint256 typeId, address expected) private view {
		address stored = factory.positionTypeFactories(typeId);
		if (stored != expected) revert PositionTypeMismatch(typeId, stored, expected);
	}

	function _checkLpFactory(SlipstreamLPPositionV2Factory lp, address npm, address poolFactory) private view {
		address storedNpm = address(lp.positionManager());
		if (storedNpm != npm || lp.aeroFeeBps() != AERO_FEE_BPS || lp.treasury() != DAO_TREASURY) {
			revert LpFactoryMismatch(address(lp), storedNpm, lp.aeroFeeBps(), lp.treasury());
		}
		address minted = IPositionManagerFactory(npm).factory();
		if (minted != poolFactory) revert NpmFactoryMismatch(npm, minted);
	}

	function _checkOwned(address target, address deployer) private view {
		address owner = Ownable2Step(target).owner();
		if (owner != deployer) revert WrongOwner(target, owner);
		address pending = Ownable2Step(target).pendingOwner();
		if (pending != address(0)) revert StillPending(target, pending);
	}

	function _hasOwner(address target) private view returns (bool) {
		(bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature('owner()'));
		return ok && ret.length == 32;
	}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {PoolPriceRegistrar} from '../../src/pricing/PoolPriceRegistrar.sol';
import {MinPoolLiquidityPolicy} from '../../src/policies/MinPoolLiquidityPolicy.sol';
import {CompounderFactory} from '../../src/yield/CompounderFactory.sol';
import {SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {FundsGovernance} from './FundsGovernance.sol';

/// @dev Shared: load the genesis addresses DeployFundsMainnet wrote, the pool-pricing switch-over's
///      (DeployPoolPricing), the fee compounders' (DeployCompoundersMainnet) and the retired TWAP tier's,
///      and the handoff batch. Rebuilt 2026-10-04 for the switch-over (PLAN_GOVERNANCE_HANDOFF_2026-10-04).
abstract contract FundsGovernanceBase is Script {
	/// @dev New salt for the rebuilt batch: the 2026-09-29 one ('frostyfunds-genesis-handoff') was cancelled.
	bytes32 internal constant SALT = keccak256('frostyfunds-handoff-2026-10');
	/// @dev What DeployPoolPricing writes: required — the registrar owns the VI since the switch-over.
	string internal constant POOL_PRICING_FILE = 'deployments/base-mainnet-pool-pricing.json';
	/// @dev What DeployCompoundersMainnet writes; absent = not deployed.
	string internal constant COMPOUNDERS_FILE = 'deployments/base-mainnet-compounders.json';
	/// @dev The retired TWAP listing v2 (module + registry); absent = never deployed.
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';
	/// @dev "Keeper · Lister", the funds-keeper lister's Engine wallet (removed 2026-10-04): it still
	///      holds the CompounderFactory creator role, which {FundsGovernance.start} revokes.
	address internal constant RETIRED_LISTER = 0x9B2C5B835eAeA359A7871e58be857D57277E646F;

	function _file() internal view returns (string memory) {
		return vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json'));
	}

	function _load() internal view returns (FundsMainnet.Deployed memory d, string memory json) {
		json = vm.readFile(_file());
		d.valueInterpreter = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		d.factory = FundFactory(vm.parseJsonAddress(json, '.factory'));
		d.feeReserve = ProtocolFeeReserve(vm.parseJsonAddress(json, '.feeReserve'));
		d.twapRegistry = vm.keyExistsJson(json, '.twapRegistry') ? vm.parseJsonAddress(json, '.twapRegistry') : address(0);
		d.twapPolicy = vm.keyExistsJson(json, '.twapPolicy') ? vm.parseJsonAddress(json, '.twapPolicy') : address(0);
		d.verantaFactory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));
		d.uniAdapter = vm.parseJsonAddress(json, '.uniAdapter');
		d.slipstreamAdapter = vm.parseJsonAddress(json, '.slipstreamAdapter');
		d.slipstream2Adapter = vm.parseJsonAddress(json, '.slipstream2Adapter');
		d.erc4626Adapter = vm.parseJsonAddress(json, '.erc4626Adapter');
		d.exitValueFeed = vm.parseJsonAddress(json, '.exitValueFeed');
	}

	function _loadPoolPricing() internal view returns (FundsGovernance.PoolPricing memory p) {
		string memory file = vm.envOr('POOL_PRICING_FILE', string(POOL_PRICING_FILE));
		require(vm.exists(file), 'pool-pricing book not found: the registrar must own the VI before the handoff');
		string memory json = vm.readFile(file);
		p.registrar = PoolPriceRegistrar(vm.parseJsonAddress(json, '.registrar'));
		p.policy = MinPoolLiquidityPolicy(vm.parseJsonAddress(json, '.policy'));
		p.fundDeployer = vm.parseJsonAddress(json, '.fundDeployer');
		console2.log('pool pricing:', file);
		console2.log('  PoolPriceRegistrar (owns the ValueInterpreter)', address(p.registrar));
		console2.log('  MinPoolLiquidityPolicy (every mandatory entry)', address(p.policy));
		console2.log('  fund v2 deployer (new funds)', p.fundDeployer);
	}

	/// @dev The fee compounders from COMPOUNDERS_FILE when it exists; otherwise the zero struct.
	function _loadCompounders() internal view returns (FundsGovernance.Compounders memory c) {
		if (!vm.exists(COMPOUNDERS_FILE)) {
			console2.log('fee compounders: not found:', COMPOUNDERS_FILE);
			return c;
		}
		string memory json = vm.readFile(COMPOUNDERS_FILE);
		c.factory = CompounderFactory(vm.parseJsonAddress(json, '.compounderFactory'));
		c.slipstreamLp = SlipstreamLPPositionV2Factory(vm.parseJsonAddress(json, '.slipstreamLpFactory'));
		c.slipstream2Lp = SlipstreamLPPositionV2Factory(vm.parseJsonAddress(json, '.slipstream2LpFactory'));
		c.perpV3 = VerantaPerpPositionV3Factory(vm.parseJsonAddress(json, '.perpV3Factory'));
		console2.log('fee compounders:', COMPOUNDERS_FILE);
		console2.log('  CompounderFactory', address(c.factory));
		console2.log('  SlipstreamLPPositionV2Factory (type 4)', address(c.slipstreamLp));
		console2.log('  SlipstreamLPPositionV2Factory (type 7)', address(c.slipstream2Lp));
		console2.log('  VerantaPerpPositionV3Factory (type 6, ownerless)', address(c.perpV3));
	}

	/// @dev The retired TWAP tier: registry v1 from genesis, module + registry v2 from TWAP_V2_FILE.
	function _loadRetired(FundsMainnet.Deployed memory d) internal view returns (FundsGovernance.Retired memory r) {
		r.registryV1 = d.twapRegistry;
		if (vm.exists(TWAP_V2_FILE)) {
			string memory json = vm.readFile(TWAP_V2_FILE);
			r.module = vm.parseJsonAddress(json, '.module');
			r.registryV2 = vm.parseJsonAddress(json, '.registry');
		}
		r.lister = RETIRED_LISTER;
		console2.log('retired TWAP tier (holds nothing, moves anyway):');
		console2.log('  TwapListingRegistry v1', r.registryV1);
		console2.log('  PriceListingModule', r.module);
		console2.log('  TwapListingRegistryV2', r.registryV2);
	}

	function _timelock() internal view returns (TimelockController) {
		return TimelockController(payable(vm.envAddress('TIMELOCK')));
	}

	/// @dev {FundsGovernance.verify} with the roles from the genesis book (its own frame: stack depth).
	function _verify(
		FundsMainnet.Deployed memory d,
		FundsGovernance.PoolPricing memory p,
		FundsGovernance.Compounders memory c,
		FundsGovernance.Retired memory r,
		string memory json,
		address timelock
	) internal view {
		FundsGovernance.verify(
			d,
			p,
			c,
			r,
			timelock,
			vm.parseJsonAddress(json, '.safe'),
			vm.parseJsonAddress(json, '.deployer'),
			vm.parseJsonAddress(json, '.autopilotKeeper')
		);
	}
}

/// @notice Step 1 (deployer EOA): the retired lister's compounder roles revoked, two-step transfers
///         begun. Then writes the Safe Transaction Builder batch that SCHEDULES the timelock's
///         acceptOwnership calls (import it in the Safe app, sign 2-of-3, execute).
///         The LAST launch step (founder rule 2026-10-01): only after every feature is tested.
///         Run: TIMELOCK=<governance timelock (DeployFundsTimelock)> forge script script/mainnet/TransferFundsGovernance.s.sol:StartFundsGovernance \
///              --rpc-url <base> --account frosty-main --sender <deployer> --broadcast --slow
contract StartFundsGovernance is FundsGovernanceBase {
	function run() external {
		(FundsMainnet.Deployed memory d, string memory json) = _load();
		FundsGovernance.PoolPricing memory p = _loadPoolPricing();
		FundsGovernance.Compounders memory c = _loadCompounders();
		FundsGovernance.Retired memory r = _loadRetired(d);
		TimelockController timelock = _timelock();
		address safe = vm.parseJsonAddress(json, '.safe');
		require(timelock.hasRole(timelock.PROPOSER_ROLE(), safe), 'the Safe must be a proposer of this timelock');
		require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), 'timelock execution must be open');

		vm.startBroadcast();
		FundsGovernance.start(d, p, c, r, address(timelock));
		vm.stopBroadcast();

		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, p, c, r);
		bytes memory schedule =
			abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), SALT, timelock.getMinDelay()));
		string memory out = string.concat(
			'{"version":"1.0","chainId":"', vm.toString(block.chainid),
			'","meta":{"name":"FrostyFunds governance handoff - schedule acceptOwnership","description":"Timelock accepts ownership of ',
			'PoolPriceRegistrar (owns the ValueInterpreter), FundFactory, VerantaPerpPositionV2Factory',
			address(c.factory) != address(0) ? ', CompounderFactory, SlipstreamLPPositionV2Factory x2 (types 4, 7)' : '',
			address(d.feeReserve) != address(0) ? ', ProtocolFeeReserve' : '',
			' and the retired TWAP tier (TwapListingRegistry, PriceListingModule, TwapListingRegistryV2). ',
			'Execute after the delay with FinishFundsGovernance (anyone).","createdFromSafeAddress":"',
			vm.toString(safe),
			'"},"transactions":[{"to":"', vm.toString(address(timelock)), '","value":"0","data":"', vm.toString(schedule),
			'","contractMethod":null,"contractInputsValues":null}]}'
		);
		string memory safeFile = 'deployments/safe-schedule-frostyfunds-handoff.json';
		vm.writeFile(safeFile, out);
		console2.log('Safe batch written to', safeFile);
		console2.log('then after the delay (seconds):', timelock.getMinDelay());
	}
}

/// @notice Step 2 (anyone, after the timelock delay): execute the scheduled accept batch, then verify.
///         Run: TIMELOCK=<…> forge script script/mainnet/TransferFundsGovernance.s.sol:FinishFundsGovernance \
///              --rpc-url <base> --broadcast --private-key <any funded key>
contract FinishFundsGovernance is FundsGovernanceBase {
	function run() external {
		(FundsMainnet.Deployed memory d, string memory json) = _load();
		FundsGovernance.PoolPricing memory p = _loadPoolPricing();
		FundsGovernance.Compounders memory c = _loadCompounders();
		FundsGovernance.Retired memory r = _loadRetired(d);
		TimelockController timelock = _timelock();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, p, c, r);
		vm.startBroadcast();
		timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);
		vm.stopBroadcast();
		_verify(d, p, c, r, json, address(timelock));
		console2.log('handoff complete and verified: the deployer holds nothing');
	}
}

/// @notice Read-only proof, any time: owners, pending owners, guardian, keeper, pricing wiring, fund version.
///         Run: TIMELOCK=<…> forge script script/mainnet/TransferFundsGovernance.s.sol:VerifyFundsGovernance --rpc-url <base>
contract VerifyFundsGovernance is FundsGovernanceBase {
	function run() external view {
		(FundsMainnet.Deployed memory d, string memory json) = _load();
		_verify(d, _loadPoolPricing(), _loadCompounders(), _loadRetired(d), json, address(_timelock()));
		console2.log('verified: every owner is the timelock, the Safe is guardian, the deployer holds nothing');
	}
}

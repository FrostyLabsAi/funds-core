// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {TimelockController} from '@openzeppelin/contracts/governance/TimelockController.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {ProtocolFeeReserve} from '../../src/core/ProtocolFeeReserve.sol';
import {TwapListingRegistry} from '../../src/pricing/TwapListingRegistry.sol';
import {TwapExposurePolicy} from '../../src/policies/TwapExposurePolicy.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {CompounderFactory} from '../../src/yield/CompounderFactory.sol';
import {SlipstreamLPPositionV2Factory} from '../../src/positions/SlipstreamLPPositionV2.sol';
import {VerantaPerpPositionV3Factory} from '../../src/positions/VerantaPerpPositionV3.sol';
import {FundsMainnet} from './FundsMainnet.sol';
import {FundsGovernance} from './FundsGovernance.sol';

/// @dev Shared: load the genesis addresses DeployFundsMainnet wrote (and TWAP listing v2's and the fee
///      compounders', when DeployTwapListingV2 / DeployCompoundersMainnet have run), and the handoff batch.
abstract contract FundsGovernanceBase is Script {
	bytes32 internal constant SALT = keccak256('frostyfunds-genesis-handoff');
	/// @dev What DeployTwapListingV2 writes; absent = v2 not deployed, the VI moves directly.
	string internal constant TWAP_V2_FILE = 'deployments/base-mainnet-twap-v2.json';
	/// @dev What DeployCompoundersMainnet writes; absent = not deployed.
	string internal constant COMPOUNDERS_FILE = 'deployments/base-mainnet-compounders.json';

	function _file() internal view returns (string memory) {
		return vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json'));
	}

	function _load() internal view returns (FundsMainnet.Deployed memory d, string memory json) {
		json = vm.readFile(_file());
		d.valueInterpreter = ValueInterpreter(vm.parseJsonAddress(json, '.valueInterpreter'));
		d.factory = FundFactory(vm.parseJsonAddress(json, '.factory'));
		d.feeReserve = ProtocolFeeReserve(vm.parseJsonAddress(json, '.feeReserve'));
		d.twapRegistry = TwapListingRegistry(vm.parseJsonAddress(json, '.twapRegistry'));
		d.twapPolicy = TwapExposurePolicy(vm.parseJsonAddress(json, '.twapPolicy'));
		d.verantaFactory = VerantaPerpPositionV2Factory(vm.parseJsonAddress(json, '.verantaFactory'));
		d.uniAdapter = vm.parseJsonAddress(json, '.uniAdapter');
		d.slipstreamAdapter = vm.parseJsonAddress(json, '.slipstreamAdapter');
		d.slipstream2Adapter = vm.parseJsonAddress(json, '.slipstream2Adapter');
		d.erc4626Adapter = vm.parseJsonAddress(json, '.erc4626Adapter');
		d.exitValueFeed = vm.parseJsonAddress(json, '.exitValueFeed');
	}

	/// @dev TWAP listing v2 from TWAP_V2_FILE when it exists; otherwise the zero struct (no v2).
	function _loadV2() internal view returns (FundsGovernance.TwapV2 memory v2) {
		if (!vm.exists(TWAP_V2_FILE)) {
			console2.log('TWAP v2: not found, the ValueInterpreter is handed off directly:', TWAP_V2_FILE);
			return v2;
		}
		string memory json = vm.readFile(TWAP_V2_FILE);
		v2.module = PriceListingModule(vm.parseJsonAddress(json, '.module'));
		v2.registry = TwapListingRegistryV2(vm.parseJsonAddress(json, '.registry'));
		v2.policy = vm.parseJsonAddress(json, '.policy');
		console2.log('TWAP v2: found', TWAP_V2_FILE);
		console2.log('  PriceListingModule (owns the ValueInterpreter)', address(v2.module));
		console2.log('  TwapListingRegistryV2', address(v2.registry));
		console2.log('  TwapExposurePolicyV2', v2.policy);
	}

	/// @dev The fee compounders from COMPOUNDERS_FILE when it exists; otherwise the zero struct
	///      (FundsGovernance refuses that once the module's compounder listing is wired).
	function _loadCompounders() internal view returns (FundsGovernance.Compounders memory c) {
		if (!vm.exists(COMPOUNDERS_FILE)) {
			console2.log('fee compounders: not found:', COMPOUNDERS_FILE);
			return c;
		}
		string memory json = vm.readFile(COMPOUNDERS_FILE);
		c.factory = CompounderFactory(vm.parseJsonAddress(json, '.compounderFactory'));
		c.feed = vm.parseJsonAddress(json, '.feed');
		c.slipstreamLp = SlipstreamLPPositionV2Factory(vm.parseJsonAddress(json, '.slipstreamLpFactory'));
		c.slipstream2Lp = SlipstreamLPPositionV2Factory(vm.parseJsonAddress(json, '.slipstream2LpFactory'));
		c.perpV3 = VerantaPerpPositionV3Factory(vm.parseJsonAddress(json, '.perpV3Factory'));
		console2.log('fee compounders: found', COMPOUNDERS_FILE);
		console2.log('  CompounderFactory', address(c.factory));
		console2.log('  SlipstreamLPPositionV2Factory (type 4)', address(c.slipstreamLp));
		console2.log('  SlipstreamLPPositionV2Factory (type 7)', address(c.slipstream2Lp));
		console2.log('  VerantaPerpPositionV3Factory (type 6, ownerless)', address(c.perpV3));
	}

	function _timelock() internal view returns (TimelockController) {
		return TimelockController(payable(vm.envAddress('TIMELOCK')));
	}
}

/// @notice Step 1 (deployer EOA): listing role → timelock, deployer's dropped, two-step transfers
///         begun. Then writes the Safe Transaction Builder batch that SCHEDULES the timelock's
///         acceptOwnership calls (import it in the Safe app, sign 2-of-3, execute).
///         Run AFTER DeployTwapListingV2 when v2 ships: with its file present the batch moves the
///         PriceListingModule (owner of the VI) and TwapListingRegistryV2 instead of the VI. Run AFTER
///         DeployCompoundersMainnet too: its file adds the CompounderFactory and both
///         SlipstreamLPPositionV2 factories.
///         Run: TIMELOCK=<governance timelock (DeployFundsTimelock)> forge script script/mainnet/TransferFundsGovernance.s.sol:StartFundsGovernance \
///              --rpc-url <base> --broadcast --private-key <deployer>
contract StartFundsGovernance is FundsGovernanceBase {
	function run() external {
		(FundsMainnet.Deployed memory d, string memory json) = _load();
		FundsGovernance.TwapV2 memory v2 = _loadV2();
		FundsGovernance.Compounders memory c = _loadCompounders();
		TimelockController timelock = _timelock();
		address safe = vm.parseJsonAddress(json, '.safe');
		require(timelock.hasRole(timelock.PROPOSER_ROLE(), safe), 'the Safe must be a proposer of this timelock');
		require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), 'timelock execution must be open');

		vm.startBroadcast();
		FundsGovernance.start(d, v2, c, address(timelock), msg.sender);
		vm.stopBroadcast();

		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, v2, c);
		bytes memory schedule =
			abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), SALT, timelock.getMinDelay()));
		string memory accepted = address(v2.module) != address(0)
			? 'PriceListingModule (owns the ValueInterpreter), TwapListingRegistryV2'
			: 'ValueInterpreter';
		if (address(c.factory) != address(0)) {
			accepted = string.concat(accepted, ', CompounderFactory, SlipstreamLPPositionV2Factory x2 (types 4, 7)');
		}
		string memory out = string.concat(
			'{"version":"1.0","chainId":"', vm.toString(block.chainid),
			'","meta":{"name":"FrostyFunds governance handoff - schedule acceptOwnership","description":"Timelock accepts ownership of ',
			accepted,
			', FundFactory, TwapListingRegistry, VerantaPerpPositionV2Factory (+ ProtocolFeeReserve when genesis had FROST). Execute after the delay with FinishFundsGovernance (anyone).","createdFromSafeAddress":"',
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
		FundsGovernance.TwapV2 memory v2 = _loadV2();
		FundsGovernance.Compounders memory c = _loadCompounders();
		TimelockController timelock = _timelock();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d, v2, c);
		vm.startBroadcast();
		timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);
		vm.stopBroadcast();
		FundsGovernance.verify(
			d,
			v2,
			c,
			address(timelock),
			vm.parseJsonAddress(json, '.safe'),
			vm.parseJsonAddress(json, '.deployer'),
			vm.parseJsonAddress(json, '.autopilotKeeper')
		);
		console2.log('handoff complete and verified: the deployer holds nothing');
	}
}

/// @notice Read-only proof, any time: owners, pending owners, guardian, listers, wiring.
///         Run: TIMELOCK=<…> forge script script/mainnet/TransferFundsGovernance.s.sol:VerifyFundsGovernance --rpc-url <base>
contract VerifyFundsGovernance is FundsGovernanceBase {
	function run() external view {
		(FundsMainnet.Deployed memory d, string memory json) = _load();
		FundsGovernance.verify(
			d,
			_loadV2(),
			_loadCompounders(),
			address(_timelock()),
			vm.parseJsonAddress(json, '.safe'),
			vm.parseJsonAddress(json, '.deployer'),
			vm.parseJsonAddress(json, '.autopilotKeeper')
		);
		console2.log('verified: every owner is the timelock, the Safe is guardian, the deployer holds nothing');
	}
}

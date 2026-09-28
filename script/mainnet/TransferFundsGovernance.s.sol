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
import {FundsMainnet} from './FundsMainnet.sol';
import {FundsGovernance} from './FundsGovernance.sol';

/// @dev Shared: load the genesis addresses DeployFundsMainnet wrote, and the handoff batch.
abstract contract FundsGovernanceBase is Script {
	bytes32 internal constant SALT = keccak256('frostyfunds-genesis-handoff');

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

	function _timelock() internal view returns (TimelockController) {
		return TimelockController(payable(vm.envAddress('TIMELOCK')));
	}
}

/// @notice Step 1 (deployer EOA): listing role → timelock, deployer's dropped, two-step transfers
///         begun. Then writes the Safe Transaction Builder batch that SCHEDULES the timelock's
///         acceptOwnership calls (import it in the Safe app, sign 2-of-3, execute).
///         Run: TIMELOCK=<governance timelock (DeployFundsTimelock)> forge script script/mainnet/TransferFundsGovernance.s.sol:StartFundsGovernance \
///              --rpc-url <base> --broadcast --private-key <deployer>
contract StartFundsGovernance is FundsGovernanceBase {
	function run() external {
		(FundsMainnet.Deployed memory d, string memory json) = _load();
		TimelockController timelock = _timelock();
		address safe = vm.parseJsonAddress(json, '.safe');
		require(timelock.hasRole(timelock.PROPOSER_ROLE(), safe), 'the Safe must be a proposer of this timelock');
		require(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), 'timelock execution must be open');

		vm.startBroadcast();
		FundsGovernance.start(d, address(timelock), msg.sender);
		vm.stopBroadcast();

		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d);
		bytes memory schedule =
			abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), SALT, timelock.getMinDelay()));
		string memory out = string.concat(
			'{"version":"1.0","chainId":"', vm.toString(block.chainid),
			'","meta":{"name":"FrostyFunds governance handoff - schedule acceptOwnership","description":"Timelock accepts ownership of ValueInterpreter, FundFactory, TwapListingRegistry, VerantaPerpPositionV2Factory (+ ProtocolFeeReserve when genesis had FROST). Execute after the delay with FinishFundsGovernance (anyone).","createdFromSafeAddress":"',
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
		TimelockController timelock = _timelock();
		(address[] memory targets, uint256[] memory values, bytes[] memory payloads) = FundsGovernance.acceptBatch(d);
		vm.startBroadcast();
		timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);
		vm.stopBroadcast();
		FundsGovernance.verify(
			d,
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
			address(_timelock()),
			vm.parseJsonAddress(json, '.safe'),
			vm.parseJsonAddress(json, '.deployer'),
			vm.parseJsonAddress(json, '.autopilotKeeper')
		);
		console2.log('verified: every owner is the timelock, the Safe is guardian, the deployer holds nothing');
	}
}

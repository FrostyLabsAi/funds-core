// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {FundsMainnet} from './FundsMainnet.sol';

/// @notice FrostyFunds genesis on Base — what test/fork/FundsMainnetGenesisFork rehearses.
///         Afterwards the deployer owns everything (run the listing batches — list-coinbase-stocks.sh,
///         ListVerantaPairs, ListYieldVaults — now), then TransferFundsGovernance hands off.
///         Writes every address to deployments/base-mainnet.json for the governance scripts.
///         Run: forge script script/mainnet/DeployFundsMainnet.s.sol --rpc-url <base> --broadcast \
///              --private-key <deployer> [--verify]
///         Env: AUTOPILOT_KEEPER (Vault server wallet), [SAFE] (default: the live 2-of-3 on Base),
///              [FROST] + [PROTOCOL_FEE_BPS] (≤ 100) — leave BOTH unset to launch before FROST:
///              no fee reserve, protocol fee off (FundsMainnet explains turning it on later),
///              [DEPLOYMENTS_FILE] (default deployments/base-mainnet.json)
contract DeployFundsMainnet is Script {
	address internal constant BASE_SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		FundsMainnet.Config memory cfg = FundsMainnet.Config({
			deployer: msg.sender,
			safe: vm.envOr('SAFE', BASE_SAFE),
			frost: vm.envOr('FROST', address(0)),
			autopilotKeeper: vm.envAddress('AUTOPILOT_KEEPER'),
			protocolFeeBps: uint16(vm.envOr('PROTOCOL_FEE_BPS', uint256(0)))
		});
		require(cfg.frost == address(0) || cfg.frost.code.length > 0, 'FROST has no code on this chain');
		require(cfg.frost != address(0) || cfg.protocolFeeBps == 0, 'a protocol fee needs FROST (its reserve burns FROST)');

		vm.startBroadcast();
		FundsMainnet.Deployed memory d = FundsMainnet.deploy(cfg);
		vm.stopBroadcast();

		string memory k = 'funds';
		vm.serializeAddress(k, 'deployer', cfg.deployer);
		vm.serializeAddress(k, 'safe', cfg.safe);
		vm.serializeAddress(k, 'frost', cfg.frost);
		vm.serializeAddress(k, 'autopilotKeeper', cfg.autopilotKeeper);
		vm.serializeAddress(k, 'valueInterpreter', address(d.valueInterpreter));
		vm.serializeAddress(k, 'factory', address(d.factory));
		vm.serializeAddress(k, 'feeReserve', address(d.feeReserve));
		vm.serializeAddress(k, 'twapRegistry', address(d.twapRegistry));
		vm.serializeAddress(k, 'twapPolicy', address(d.twapPolicy));
		vm.serializeAddress(k, 'verantaFactory', address(d.verantaFactory));
		vm.serializeAddress(k, 'uniAdapter', d.uniAdapter);
		vm.serializeAddress(k, 'slipstreamAdapter', d.slipstreamAdapter);
		vm.serializeAddress(k, 'slipstream2Adapter', d.slipstream2Adapter);
		vm.serializeAddress(k, 'erc4626Adapter', d.erc4626Adapter);
		string memory out = vm.serializeAddress(k, 'exitValueFeed', d.exitValueFeed);
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet.json'));
		vm.writeJson(out, file);

		console2.log('FrostyFunds genesis written to', file);
		console2.log('factory', address(d.factory));
		console2.log('valueInterpreter', address(d.valueInterpreter));
	}
}

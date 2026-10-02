// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Script, console2} from 'forge-std/Script.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {FundFactory} from '../../src/core/FundFactory.sol';
import {PriceListingModule} from '../../src/pricing/PriceListingModule.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {CompoundersMainnet} from './CompoundersMainnet.sol';

/// @notice Fee compounders + the fee-taking position types on the LIVE Base genesis — what
///         test/fork/CompoundersMainnetFork rehearses. Run by the genesis deployer AFTER
///         DeployTwapListingV2 (the module it wires must own the VI) and BEFORE the governance handoff
///         (it still owns the FundFactory and the module). CompoundersMainnet lists the steps.
///         Fails closed: it sends nothing unless the founder's referral ops are done — the DAO
///         Treasury Safe owns `frostydao` on Veranta's Referral and the V2 perp factory points at it.
///         Reads deployments/base-mainnet.json (deployer, valueInterpreter, factory, verantaFactory)
///         and the TWAP v2 book (module).
///         Writes deployments/base-mainnet-compounders.json: feed, adapter, compounderFactory (and its
///         two vault deployers, made in its constructor), slipstreamLpFactory (type 4),
///         slipstream2LpFactory (type 7), perpV3Factory (type 6), creator / compounder (zero when
///         unset) and startBlock (a lower bound of the deploy block). Plans B (keeper) and C (terminal)
///         read it. It never hands anything off: StartFundsGovernance moves its ownables to the timelock,
///         and only as the LAST launch step (founder rule 2026-10-01; runbook "Launch gate").
///         Run: forge script script/mainnet/DeployCompoundersMainnet.s.sol --rpc-url <base> --account <keystore> \
///              --sender <deployer> --broadcast --slow [--verify]
///         Env: [COMPOUNDER_CREATOR] (the funds-keeper wallet: may create vaults; unset = setCreator later),
///              [COMPOUNDER_HARVESTER] (the FrostyFi workflow wallet: may call compound(); unset = setCompounder later),
///              [TWAP_V2_FILE] (default deployments/base-mainnet-twap-v2.json),
///              [DEPLOYMENTS_FILE] (default deployments/base-mainnet-compounders.json)
contract DeployCompoundersMainnet is Script {
	string internal constant GENESIS_FILE = 'deployments/base-mainnet.json';

	function run() external {
		require(block.chainid == 8453, 'Base (8453) only');
		string memory file = vm.envOr('DEPLOYMENTS_FILE', string('deployments/base-mainnet-compounders.json'));
		// never write over the genesis or the TWAP v2 address book
		if (vm.exists(file)) {
			string memory existing = vm.readFile(file);
			require(
				!vm.keyExistsJson(existing, '.valueInterpreter') && !vm.keyExistsJson(existing, '.module'),
				'DEPLOYMENTS_FILE is another address book'
			);
		}
		string memory twapFile = vm.envOr('TWAP_V2_FILE', string('deployments/base-mainnet-twap-v2.json'));
		require(vm.exists(twapFile), 'TWAP v2 book not found: run DeployTwapListingV2 first');

		string memory genesis = vm.readFile(GENESIS_FILE);
		CompoundersMainnet.Config memory cfg = CompoundersMainnet.Config({
			deployer: vm.parseJsonAddress(genesis, '.deployer'),
			valueInterpreter: ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter')),
			factory: FundFactory(vm.parseJsonAddress(genesis, '.factory')),
			module: PriceListingModule(vm.parseJsonAddress(vm.readFile(twapFile), '.module')),
			verantaFactory: VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory')),
			creator: vm.envOr('COMPOUNDER_CREATOR', address(0)),
			compounder: vm.envOr('COMPOUNDER_HARVESTER', address(0))
		});
		require(msg.sender == cfg.deployer, 'run as the genesis deployer (it owns the FundFactory and the module)');
		// fail closed before anything is sent: the founder's referral ops come first (runbook "Fees + referral")
		string memory problem = CompoundersMainnet.referralProblem(cfg.verantaFactory);
		require(bytes(problem).length == 0, problem);
		if (cfg.creator == address(0)) console2.log('COMPOUNDER_CREATOR unset: no creator yet (compounderFactory.setCreator later)');
		else console2.log('COMPOUNDER_CREATOR', cfg.creator);
		if (cfg.compounder == address(0)) {
			console2.log('COMPOUNDER_HARVESTER unset: no compounder yet (compounderFactory.setCompounder later)');
		} else {
			console2.log('COMPOUNDER_HARVESTER', cfg.compounder);
		}
		// the head before broadcasting: the deploy lands at or after it
		uint256 startBlock = block.number;

		vm.startBroadcast();
		CompoundersMainnet.Deployed memory d = CompoundersMainnet.deploy(cfg);
		vm.stopBroadcast();

		string memory k = 'compounders';
		vm.serializeAddress(k, 'feed', address(d.feed));
		vm.serializeAddress(k, 'adapter', address(d.adapter));
		vm.serializeAddress(k, 'compounderFactory', address(d.compounderFactory));
		vm.serializeAddress(k, 'uniswapV3Deployer', address(d.compounderFactory.uniswapV3Deployer()));
		vm.serializeAddress(k, 'slipstreamDeployer', address(d.compounderFactory.slipstreamDeployer()));
		vm.serializeAddress(k, 'slipstreamLpFactory', address(d.slipstreamLp));
		vm.serializeAddress(k, 'slipstream2LpFactory', address(d.slipstream2Lp));
		vm.serializeAddress(k, 'perpV3Factory', address(d.perpV3));
		vm.serializeAddress(k, 'creator', cfg.creator);
		vm.serializeAddress(k, 'compounder', cfg.compounder);
		string memory out = vm.serializeUint(k, 'startBlock', startBlock);
		vm.writeJson(out, file);

		console2.log('fee compounders written to', file);
		console2.log('CompounderPriceFeed', address(d.feed));
		console2.log('CompounderAdapter (registered)', address(d.adapter));
		console2.log('CompounderFactory', address(d.compounderFactory));
		console2.log('  UniswapV3CompounderDeployer', address(d.compounderFactory.uniswapV3Deployer()));
		console2.log('  SlipstreamCompounderDeployer', address(d.compounderFactory.slipstreamDeployer()));
		console2.log('SlipstreamLPPositionV2Factory (type 4)', address(d.slipstreamLp));
		console2.log('SlipstreamLPPositionV2Factory (type 7)', address(d.slipstream2Lp));
		console2.log('VerantaPerpPositionV3Factory (type 6)', address(d.perpV3));
		console2.log('startBlock', startBlock);
	}
}

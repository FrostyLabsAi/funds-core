// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ValueInterpreter} from '../../src/core/ValueInterpreter.sol';
import {VerantaPerpPositionV2Factory} from '../../src/positions/VerantaPerpPositionV2.sol';
import {
	IRegistrarV2Passthrough, IValueInterpreterAdmin, ListingModuleBook, ViAdmin
} from '../../script/mainnet/ListingModuleBook.sol';

/// @notice Since registrar V2 took over today's registrar (2026-10-09), the deployer can't call that registrar's
///         `execute` itself: the listing scripts (list-assets.sh veranta and the rest) reverted
///         `OwnableUnauthorizedAccount(deployer)` until ListingModuleBook routed their VI admin calls through
///         registrar V2's `callOldRegistrar` (health line 8, 2026-10-14). Opt-in: BASE_MAINNET_RPC (an archive RPC).
contract ListingViaRegistrarV2Fork is Test {
	uint256 internal constant FORK_BLOCK = 52_385_115; // registrar V2 owns today's registrar (the CLM rehearsal block)
	address internal constant DEPLOYER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a;
	address internal constant REGISTRAR_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F;
	uint256 internal constant PAIR = 2; // a store-priced Veranta pair

	bool internal forked;
	string internal genesis;
	ValueInterpreter internal vi;
	address internal asset;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		forked = true;
		genesis = vm.readFile('deployments/base-mainnet.json');
		vi = ValueInterpreter(vm.parseJsonAddress(genesis, '.valueInterpreter'));
		asset = VerantaPerpPositionV2Factory(vm.parseJsonAddress(genesis, '.verantaFactory')).pairAsset(PAIR);
	}

	function test_fork_theBookRoutesThroughRegistrarV2() public {
		vm.skip(!forked);
		ViAdmin memory admin = ListingModuleBook.admin(vm, genesis);
		assertEq(address(admin.owner), vi.owner(), 'the VI owner');
		assertEq(address(admin.registrarV2), REGISTRAR_V2, 'through registrar V2');
		assertEq(Ownable(REGISTRAR_V2).owner(), DEPLOYER, 'which the deployer owns');
	}

	function test_fork_aViAdminCallLandsThroughRegistrarV2() public {
		vm.skip(!forked);
		ViAdmin memory admin = ListingModuleBook.admin(vm, genesis);
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(asset);
		vm.prank(DEPLOYER);
		admin.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (asset, aggregator, heartbeat + 1)));
		(address after_, uint32 newHeartbeat,,) = vi.getAssetInfo(asset);
		assertEq(after_, aggregator, 'same feed');
		assertEq(newHeartbeat, heartbeat + 1, 'the call reached the VI');
	}

	function test_fork_theDirectCallTheScriptsMadeIsRefused() public {
		vm.skip(!forked);
		ViAdmin memory direct = ViAdmin(IValueInterpreterAdmin(vi.owner()), IRegistrarV2Passthrough(address(0)));
		(address aggregator, uint32 heartbeat,,) = vi.getAssetInfo(asset);
		vm.prank(DEPLOYER);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, DEPLOYER));
		direct.execute(abi.encodeCall(ValueInterpreter.addPrimitive, (asset, aggregator, heartbeat)));
	}
}

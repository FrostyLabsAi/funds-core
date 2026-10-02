// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {FundFactory} from '../../src/core/FundFactory.sol';
import {IPolicy} from '../../src/interfaces/IPolicy.sol';
import {TwapListingRegistryV2} from '../../src/pricing/TwapListingRegistryV2.sol';
import {TwapExposurePolicyV2} from '../../src/policies/TwapExposurePolicyV2.sol';
import {TwapExposurePolicyV3} from '../../src/policies/TwapExposurePolicyV3.sol';

/// @title TwapPolicyV3
/// @notice TwapExposurePolicyV3 wired into the LIVE Base factory as code — one library the broadcast
///         script (DeployTwapPolicyV3) and the fork test (test/fork/TwapPolicyV3Fork) both run, so
///         what is tested is exactly what ships. The caller is the genesis deployer, which still
///         owns the FundFactory:
///           1. TwapExposurePolicyV3 over the live TwapListingRegistryV2;
///           2. the mandatory list: every TwapExposurePolicyV2 entry becomes V3, hooks kept — new
///              funds run V3 even when a manager names V2 in its own ruleset (a replacement alone
///              would let V2 count as present, FundFactory.sol:367);
///           3. V3 approved as the replacement of V1 and of V2 — an existing fund opts in by
///              reconfiguring (2-day window; its external positions closed first).
///         {verify} proves the end state or reverts. V3 has no owner: nothing joins the handoff.
library TwapPolicyV3 {
	/// @notice Mainnet's mandatory list: TwapExposurePolicyV2 on hooks 4, 0, 5, 6 (cast, block 52066028).
	uint256 internal constant MANDATORY_TWAP_ENTRIES = 4;

	struct Config {
		address deployer; // owns the FundFactory until the governance handoff
		FundFactory factory;
		TwapListingRegistryV2 registry; // deployments/base-mainnet-twap-v2.json `registry`
		address policyV1; // genesis TwapExposurePolicy (deployments/base-mainnet.json `twapPolicy`)
		address policyV2; // TwapExposurePolicyV2 (deployments/base-mainnet-twap-v2.json `policy`)
	}

	error BadConfig();
	error WrongOwner(address owner);
	error WrongRegistry(address registry);
	error MandatoryPoliciesMismatch(uint256 count);
	error MandatoryPolicyMismatch(uint256 index, uint8 hook, address policy);
	error ReplacementMismatch(address policy, address replacement);

	/// @notice Deploy and wire (steps 1–3), then {verify}.
	function deploy(Config memory cfg) internal returns (TwapExposurePolicyV3 policy) {
		_checkConfig(cfg);
		// a second run finds V3 here and stops before sending anything
		_requireAll(cfg.factory.getMandatoryPolicies(), cfg.policyV2);

		policy = new TwapExposurePolicyV3(cfg.registry);
		FundFactory.PolicyReg[] memory next = new FundFactory.PolicyReg[](MANDATORY_TWAP_ENTRIES);
		for (uint256 i; i < MANDATORY_TWAP_ENTRIES; ++i) {
			next[i] = FundFactory.PolicyReg({hook: _hook(i), policy: address(policy)});
		}
		cfg.factory.setMandatoryPolicies(next);
		cfg.factory.setPolicyReplacement(cfg.policyV1, address(policy));
		cfg.factory.setPolicyReplacement(cfg.policyV2, address(policy));
		verify(cfg, policy);
	}

	/// @notice Revert unless `policy` reads the v2 registry, is every mandatory entry on the genesis
	///         hooks, and is the approved replacement of V1 and of V2.
	function verify(Config memory cfg, TwapExposurePolicyV3 policy) internal view {
		if (address(policy.registry()) != address(cfg.registry)) revert WrongRegistry(address(policy.registry()));
		_requireAll(cfg.factory.getMandatoryPolicies(), address(policy));
		_requireReplacement(cfg.factory, cfg.policyV1, address(policy));
		_requireReplacement(cfg.factory, cfg.policyV2, address(policy));
	}

	function _checkConfig(Config memory cfg) private view {
		if (
			cfg.deployer == address(0) || address(cfg.factory) == address(0) || address(cfg.registry) == address(0)
				|| cfg.policyV1 == address(0) || cfg.policyV2 == address(0)
		) revert BadConfig();
		address owner = cfg.factory.owner();
		if (owner != cfg.deployer) revert WrongOwner(owner);
		address v2Registry = address(TwapExposurePolicyV2(cfg.policyV2).registry());
		if (v2Registry != address(cfg.registry)) revert WrongRegistry(v2Registry);
	}

	/// @dev Exactly MANDATORY_TWAP_ENTRIES entries, each `policy` on the genesis hook order.
	function _requireAll(FundFactory.PolicyReg[] memory regs, address policy) private pure {
		if (regs.length != MANDATORY_TWAP_ENTRIES) revert MandatoryPoliciesMismatch(regs.length);
		for (uint256 i; i < regs.length; ++i) {
			if (regs[i].policy != policy || regs[i].hook != _hook(i)) {
				revert MandatoryPolicyMismatch(i, uint8(regs[i].hook), regs[i].policy);
			}
		}
	}

	/// @dev The genesis order (FundsMainnet.sol:214-217; cast at block 52066028: 4, 0, 5, 6).
	function _hook(uint256 i) private pure returns (IPolicy.PolicyHook) {
		if (i == 0) return IPolicy.PolicyHook.PostCallOnIntegration;
		if (i == 1) return IPolicy.PolicyHook.PostDepositRequest;
		if (i == 2) return IPolicy.PolicyHook.CreateExternalPosition;
		return IPolicy.PolicyHook.PostCallOnExternalPosition;
	}

	function _requireReplacement(FundFactory factory, address policy, address expected) private view {
		address stored = factory.policyReplacements(policy);
		if (stored != expected) revert ReplacementMismatch(policy, stored);
	}
}

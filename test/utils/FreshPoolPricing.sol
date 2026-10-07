// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {FundsMainnet} from '../../script/mainnet/FundsMainnet.sol';
import {FundsGovernance} from '../../script/mainnet/FundsGovernance.sol';
import {PoolPricing} from '../../script/mainnet/PoolPricing.sol';

/// @notice A rehearsal genesis (FundsMainnet.deploy) brought to mainnet's state since the 2026-10-04
///         pool-pricing switch-over. On mainnet the retired PriceListingModule handed the VI over; here
///         the genesis deployer does. Call while pranking as the deployer (owner of the VI and factory).
library FreshPoolPricing {
	/// @notice A PoolPriceRegistrar owns the VI; listing batches go through its `execute`.
	function takeOverVi(FundsMainnet.Deployed memory d, address owner) internal returns (PoolPricing.Deployment memory p) {
		p = PoolPricing.deploy(d.valueInterpreter, owner);
		d.valueInterpreter.transferOwnership(address(p.registrar));
		p.registrar.execute(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
	}

	/// @notice Everything MigratePoolPricing changed on mainnet: the registrar owns the VI, the
	///         long-tail policy is the only mandatory one, and new funds are fund v2.
	function install(FundsMainnet.Deployed memory d, address owner) internal returns (FundsGovernance.PoolPricing memory g) {
		PoolPricing.Deployment memory p = takeOverVi(d, owner);
		PoolPricing.setMandatoryPolicy(d.factory, p.policy);
		PoolPricing.setFundVersion(d.factory, p.fundDeployer);
		g = FundsGovernance.PoolPricing({
			registrar: p.registrar, policy: p.policy, fundDeployer: address(p.fundDeployer), fundV3Deployer: address(0), redemptionQueue: address(0)
		});
	}
}

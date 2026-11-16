// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @title BaseMainnet
/// @notice Every outside address and protocol constant the clean release is wired with on Base (chain 8453). Copied from
///         the scripts the live system was deployed with (git tag deployed-2026-11-15: script/mainnet/FundsMainnet.sol,
///         V4Pricing.sol, AeroRegistrar.sol, DeployAeroAdapters.s.sol, DeployVerantaStocks.s.sol, WindowedPricing.sol);
///         each was verified on Base when first used there.
library BaseMainnet {
	// ─── tokens ──────────────────────────────────────────────────────────────────
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

	// ─── Chainlink ───────────────────────────────────────────────────────────────
	address internal constant CL_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
	address internal constant CL_ETH_USD = 0x50015f8b17fb2C290Dde41fDc246ed0dcEE93a8b;
	address internal constant CL_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
	address internal constant CL_SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

	// ─── Uniswap ─────────────────────────────────────────────────────────────────
	address internal constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
	address internal constant UNI_SWAP_ROUTER02 = 0x2626664c2603336E57B271c5C0b26F421741e481;
	address internal constant UNI_V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
	address internal constant UNI_V4_STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;

	// ─── Aerodrome / Aero ────────────────────────────────────────────────────────
	address internal constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant CL_SWAP_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
	address internal constant CL2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address internal constant CL2_SWAP_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
	address internal constant CL3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	address internal constant CL3_SWAP_ROUTER = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D;
	/// @dev Aerodrome basic PoolFactory = Router (0xcF77…4E43).defaultFactory().
	address internal constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	address internal constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
	/// @dev Aero's CL factory after the Aerodrome/Velodrome merger (2026-10-22): getPool(token0, token1, tickSpacing).
	address internal constant AERO_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
	/// @dev Aero's SwapRouter: Slipstream's exactInputSingle / exactInput shapes.
	address internal constant AERO_SWAP_ROUTER = 0x9Ee35Bf1bd69a03c6F0393582030fCe8Bb93D418;

	// ─── Veranta and Pyth Lazer ──────────────────────────────────────────────────
	address internal constant VERANTA_ROUTER = 0x44914408af82bC9983bbb330e3578E1105e11d4e;
	address internal constant VERANTA_STORAGE = 0x8a311D7048c35985aa31C131B9A13e03a5f7422d;
	address internal constant VERANTA_MULTICALL = 0xA7cFc43872F4D7B0E6141ee8c36f1F7FEe5d099e;
	address internal constant VERANTA_PAIR_STORAGE = 0x5db3772136e5557EFE028Db05EE95C84D76faEC4;
	address internal constant VERANTA_REFERRAL = 0x1A110bBA13A1f16cCa4b79758BD39290f29De82D;
	/// @dev bytes32('frostydao'), the code today's perp config links: codeOwners() answers the Treasury Safe, and every
	///      live perp account's referrer is the Treasury Safe (getTraderReferralInfo, read 2026-11-16).
	bytes32 internal constant VERANTA_REFERRAL_CODE = 'frostydao';
	address internal constant PYTH_LAZER_VERIFIER = 0xACeA761c27A909d4D3895128EBe6370FDE2dF481;

	// ─── FrostyFi CLM (funds-yield deployments/base-mainnet-clm-v2.json) ─────────
	address internal constant CLM_STRATEGY_FACTORY = 0x99c49323e589136BD4F9937b6ae226fD25A267aa;

	// ─── FrostyLabs ──────────────────────────────────────────────────────────────
	/// @dev The Treasury Safe: protocol swap fees and the o1 referrer share.
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	/// @dev The Admin Safe: the guardian and the v4 pool approver.
	address internal constant ADMIN_SAFE = 0xB0f37bE90a8BD82D991Bf694F960C67198778B8B;
	/// @dev The keeper's thirdweb Engine wallet: autopilot, the v4 sampler and the redemption queue.
	address internal constant KEEPER = 0x659fb4AD2e3BD86Df7e9B364a8a5aEb281A96C1c;

	// ─── protocol constants ──────────────────────────────────────────────────────
	uint32 internal constant SEQUENCER_GRACE = 1 hours;
	/// @dev The live VI's heartbeats for the three quotes (read 2026-11-15): USDC 90,000 s, ETH and cbBTC 3,600 s.
	uint32 internal constant USDC_HEARTBEAT = 90_000;
	uint32 internal constant ETH_HEARTBEAT = 3_600;
	uint32 internal constant CBBTC_HEARTBEAT = 3_600;
	/// @dev The protocol fee on every spot swap (founder 2026-10-08: 0–10 bps, 5 at deployment).
	uint16 internal constant SWAP_FEE_BPS = 5;
	/// @dev The most value every new fund's trades may lose against the oracle, in bps of GAV, replenishing over 7 days
	///      (red-team ADAPTERS-02, 2026-10-27; set at 5% on 2026-11-01).
	uint256 internal constant MANDATORY_SLIPPAGE_BPS = 500;
	/// @dev The perp account's position type id (unchanged from genesis, so the terminal and keeper keep it).
	uint256 internal constant VERANTA_PERP_TYPE = 6;
	/// @dev Veranta-priced feeds (DeployVerantaStocks.s.sol): a confirmation under 2 minutes old, a last trade under 5 days.
	uint32 internal constant VERANTA_MAX_PUSH_AGE = 120;
	uint32 internal constant VERANTA_MAX_FEED_AGE = 432_000;
}

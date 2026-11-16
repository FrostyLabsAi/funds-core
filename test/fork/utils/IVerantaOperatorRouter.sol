// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Veranta TradingRouter's operator entry (field order per ITradingStorage.offChainSpreadParams): the fill a fork
///         test plays for Veranta's off-chain operator, which doesn't run on a fork.
interface IVerantaOperatorRouter {
	struct OffChainSpreadParams {
		int256 spreadP;
		uint256 bookDepth;
		int256 impactParam;
		bool byPass;
		int256 maxSpreadP;
		bool slot1;
		int256 slot3;
	}

	function executeMarketOrder(
		uint256 orderId,
		bytes[] calldata priceUpdateData,
		uint8 priceSourcing,
		OffChainSpreadParams calldata spreadParams
	) external payable;
}

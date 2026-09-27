// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

/// @notice Pyth Lazer's on-chain verifier (Base 0xACeA761c27A909d4D3895128EBe6370FDE2dF481):
///         checks the packet's signature against Pyth's trusted signers and returns the payload.
interface IPythLazerVerifier {
	function verifyUpdate(bytes calldata update) external payable returns (bytes memory payload, address signer);

	function verification_fee() external view returns (uint256);
}

/// @notice Veranta's PairStorage (Base 0x5db3772136e5557EFE028Db05EE95C84D76faEC4): the Lazer feed
///         each Veranta pair is priced from — the mapping Veranta's own PriceAggregator uses.
interface IVerantaLazerPairs {
	function getLazerFeedId(uint256 pairIndex) external view returns (uint256);
}

/// @title VerantaPriceStore
/// @notice Every Veranta perp valued at the price Veranta itself settles it at. Veranta prices
///         every pair from Pyth Lazer: its keeper's routine `updateFundingAccumulators` batches
///         put one Pyth-signed packet per active pair into public calldata (~every 5 minutes).
///         Anyone may relay those packets here; each one is re-verified by Pyth's own Lazer
///         verifier and matched to its pair through Veranta's own pair→feed mapping, so a relayer
///         can choose WHEN to relay but never WHAT price is stored. Newer-only per pair.
///         The packet format accepted is exactly Veranta's (PriceAggregator._parsePythLazerPrice):
///         price, confidence, exponent and the feed's own update timestamp — nothing else.
/// @dev Read through one VerantaPriceAdapter per pair (Chainlink AggregatorV3 shape) registered
///      as a VI primitive on a PriceMarker, then `setPairAsset(pair, marker)`.
contract VerantaPriceStore {
	/// @notice Veranta PairInfos' funding-accumulator update — the calldata `relayFunding` takes.
	bytes4 public constant FUNDING_SELECTOR = bytes4(keccak256('updateFundingAccumulators(uint256[],bytes[][],uint8[])'));

	uint8 internal constant PYTH_LAZER = 1; // Veranta PriceSourcing.PYTH_LAZER
	uint32 internal constant PAYLOAD_MAGIC = 2479346549; // Pyth Lazer payload header
	// Pyth Lazer PriceFeedProperty ids
	uint8 internal constant PROP_PRICE = 0;
	uint8 internal constant PROP_EXPONENT = 4;
	uint8 internal constant PROP_CONFIDENCE = 5;
	uint8 internal constant PROP_FEED_UPDATE_TIMESTAMP = 12;

	struct Latest {
		int64 price;
		int16 exponent;
		uint64 timestampUs; // the feed's own update time, microseconds
	}

	/// @dev One feed's properties while the payload is walked (memory, not stack)
	struct Feed {
		int64 price;
		int16 exponent;
		uint64 timestampUs;
		bool hasPrice;
		bool hasConfidence;
		bool hasExponent;
		bool hasTimestamp;
	}

	IPythLazerVerifier public immutable lazer;
	IVerantaLazerPairs public immutable pairs;

	mapping(uint256 pairIndex => Latest) private latestOf;

	event PriceStored(uint256 indexed pairIndex, int64 price, int16 exponent, uint64 timestampUs);

	error ZeroAddress();
	error NotFundingCalldata();
	error LengthMismatch();
	error BadPayloadMagic();
	error PayloadTooShort();
	error FeedNotFound(uint256 pairIndex, uint32 lazerFeedId);
	error UnknownProperty(uint8 property);
	error DuplicateProperty(uint8 property);
	error IncompleteFeed(uint256 pairIndex);
	error NonPositivePrice(uint256 pairIndex);
	error FeedUpdateAfterHeader(uint64 feedTimestampUs, uint64 headerTimestampUs);
	error FeedFromFuture(uint64 timestampUs);
	error NothingNewer();

	constructor(IPythLazerVerifier lazer_, IVerantaLazerPairs pairs_) {
		if (address(lazer_) == address(0) || address(pairs_) == address(0)) revert ZeroAddress();
		lazer = lazer_;
		pairs = pairs_;
	}

	/// @notice Relay a whole Veranta funding batch: the raw `updateFundingAccumulators` calldata of
	///         any of Veranta's transactions. Each Lazer packet is verified and stored on its own;
	///         one that fails (tampered, stale, unmapped) is skipped, never the batch.
	///         Send `verification_fee()` × packets as value (1 wei each on Base today).
	///         Reverts when no pair got a newer price, so a keeper's pre-send simulation turns a
	///         repeat of an already-relayed batch into a free no-op.
	/// @return stored how many pairs got a newer price
	function relayFunding(bytes calldata fundingCalldata) external payable returns (uint256 stored) {
		if (fundingCalldata.length < 4 || bytes4(fundingCalldata[:4]) != FUNDING_SELECTOR) revert NotFundingCalldata();
		(uint256[] memory pairIndexes, bytes[][] memory updates, uint8[] memory sourcing) =
			abi.decode(fundingCalldata[4:], (uint256[], bytes[][], uint8[]));
		if (pairIndexes.length != updates.length || pairIndexes.length != sourcing.length) revert LengthMismatch();

		uint256 fee = lazer.verification_fee();
		for (uint256 i; i < pairIndexes.length; ++i) {
			if (sourcing[i] != PYTH_LAZER || updates[i].length == 0) continue;
			try this.submit{value: fee}(pairIndexes[i], updates[i][0]) returns (bool ok) {
				if (ok) ++stored;
			} catch {}
		}
		if (stored == 0) revert NothingNewer();
	}

	/// @notice Verify one Pyth Lazer packet for `pairIndex` and store its price if newer.
	/// @return stored false when the packet is valid but no newer than the stored price
	function submit(uint256 pairIndex, bytes calldata update) external payable returns (bool stored) {
		(bytes memory payload,) = lazer.verifyUpdate{value: lazer.verification_fee()}(update);
		Feed memory feed = _parse(payload, pairIndex, uint32(pairs.getLazerFeedId(pairIndex)));
		if (feed.timestampUs / 1e6 > block.timestamp) revert FeedFromFuture(feed.timestampUs);
		if (feed.timestampUs <= latestOf[pairIndex].timestampUs) return false;

		latestOf[pairIndex] = Latest(feed.price, feed.exponent, feed.timestampUs);
		emit PriceStored(pairIndex, feed.price, feed.exponent, feed.timestampUs);
		return true;
	}

	/// @notice The newest stored price for `pairIndex` (timestampUs 0 = never stored).
	function latest(uint256 pairIndex) external view returns (int64 price, int16 exponent, uint64 timestampUs) {
		Latest memory l = latestOf[pairIndex];
		return (l.price, l.exponent, l.timestampUs);
	}

	// ─── Lazer payload ───────────────────────────────────────────────────────────
	// header: magic u32 · timestamp u64 (µs) · channel u8 · feedsLen u8
	// feed:   id u32 · numProperties u8 · properties (id u8 + value), all big-endian

	function _parse(bytes memory payload, uint256 pairIndex, uint32 feedId) internal pure returns (Feed memory feed) {
		if (_read(payload, 0, 4) != PAYLOAD_MAGIC) revert BadPayloadMagic();
		uint64 headerTimestampUs = uint64(_read(payload, 4, 8));
		uint256 feedsLen = _read(payload, 13, 1);
		uint256 pos = 14;
		bool found;
		for (uint256 i; i < feedsLen; ++i) {
			uint32 id = uint32(_read(payload, pos, 4));
			uint256 properties = _read(payload, pos + 4, 1);
			feed = Feed(0, 0, 0, false, false, false, false);
			pos = _parseProperties(payload, pos + 5, properties, feed);
			if (id == feedId) {
				found = true;
				break;
			}
		}
		if (!found) revert FeedNotFound(pairIndex, feedId);
		if (!feed.hasPrice || !feed.hasConfidence || !feed.hasExponent || !feed.hasTimestamp) revert IncompleteFeed(pairIndex);
		if (feed.price <= 0) revert NonPositivePrice(pairIndex);
		if (feed.timestampUs > headerTimestampUs) revert FeedUpdateAfterHeader(feed.timestampUs, headerTimestampUs);
	}

	function _parseProperties(bytes memory payload, uint256 pos, uint256 count, Feed memory feed)
		internal
		pure
		returns (uint256)
	{
		for (uint256 j; j < count; ++j) {
			uint8 property = uint8(_read(payload, pos, 1));
			pos += 1;
			if (property == PROP_PRICE) {
				if (feed.hasPrice) revert DuplicateProperty(property);
				feed.price = int64(uint64(_read(payload, pos, 8)));
				feed.hasPrice = true;
				pos += 8;
			} else if (property == PROP_CONFIDENCE) {
				if (feed.hasConfidence) revert DuplicateProperty(property);
				feed.hasConfidence = true;
				pos += 8;
			} else if (property == PROP_EXPONENT) {
				if (feed.hasExponent) revert DuplicateProperty(property);
				feed.exponent = int16(uint16(_read(payload, pos, 2)));
				feed.hasExponent = true;
				pos += 2;
			} else if (property == PROP_FEED_UPDATE_TIMESTAMP) {
				if (feed.hasTimestamp) revert DuplicateProperty(property);
				bool exists = _read(payload, pos, 1) != 0;
				pos += 1;
				if (exists) {
					feed.timestampUs = uint64(_read(payload, pos, 8));
					feed.hasTimestamp = true;
					pos += 8;
				}
			} else {
				revert UnknownProperty(property);
			}
		}
		return pos;
	}

	/// @dev Big-endian unsigned read of `size` bytes (1..8) at `pos`, bounds-checked
	function _read(bytes memory data, uint256 pos, uint256 size) internal pure returns (uint256 value) {
		if (pos + size > data.length) revert PayloadTooShort();
		assembly ('memory-safe') {
			value := shr(sub(256, mul(8, size)), mload(add(add(data, 0x20), pos)))
		}
	}
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {IPythLazerVerifier} from '../interfaces/external/IPythLazerVerifier.sol';
import {IVerantaPairStorage} from '../interfaces/external/IVeranta.sol';
import {IVerantaPriceStore} from '../interfaces/IVerantaPriceStore.sol';

/// @title VerantaPriceStore
/// @notice Veranta's Pyth-signed prices for SPOT stock tokens (Coinbase B20), weekends included (founder 2026-10-25,
///         option b). Veranta's equity feeds stop when the market closes (Fri 20:00 ET), but every packet Pyth signs
///         keeps a fresh header time: on Sun 2026-10-25 23:55 UTC MU's packet was signed then and still carried
///         Friday 23:59:59 UTC as its last trade. Keeping only the feed's own update time would make a closed market
///         read as a days-old price, so this store keeps both, per pair:
///         - `timestampUs`: when Pyth last signed this price as current (the packet header), "confirmed";
///         - `feedUs`: when the stock last traded (the feed's own update time).
///         An adapter then asks for a recent confirmation (no price picking, security review 2026-09-22 H-3) and a
///         trade no older than a long weekend (a halted or delisted stock stops pricing).
///         A packet must also be FRESH when relayed (MAX_RELAY_AGE, review 2026-10-25): a v6 fund holding these stocks
///         pays instant USDC exits at the stored price, so a relayer able to pick any packet from the adapter's whole
///         lifetime could redeem at, say, Friday's close a few minutes into Monday's open. Veranta itself refuses
///         packets over 30 s old.
///         Ownerless: anyone relays, Pyth's verifier checks every signature and Veranta's own pair→feed
///         mapping picks the feed, so a relayer chooses WHEN a price is confirmed, never WHAT it is.
/// @dev On demand only (founder 2026-10-05): no `relayFunding`, packets come from Veranta's feed app.
///      Storage slot 0 is `latestOf` (the terminal injects prices into it for free NAV reads): one word per pair,
///      price bits 0-63, exponent 64-79, timestampUs 80-143, feedUs 144-207.
contract VerantaPriceStore is IVerantaPriceStore {
	uint32 internal constant PAYLOAD_MAGIC = 2479346549; // Pyth Lazer payload header
	// Pyth Lazer PriceFeedProperty ids
	uint8 internal constant PROP_PRICE = 0;
	uint8 internal constant PROP_EXPONENT = 4;
	uint8 internal constant PROP_CONFIDENCE = 5;
	uint8 internal constant PROP_FEED_UPDATE_TIMESTAMP = 12;
	/// @notice A packet signed more than this long before the block is refused: a relayer picks WHEN, from the last
	///         minute only.
	uint256 public constant MAX_RELAY_AGE = 60;

	struct Latest {
		int64 price;
		int16 exponent;
		uint64 timestampUs; // when Pyth signed it as current (packet header), microseconds
		uint64 feedUs; // the feed's own update time (last trade), microseconds
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
	IVerantaPairStorage public immutable pairs;

	mapping(uint256 pairIndex => Latest) private latestOf;

	event PriceStored(uint256 indexed pairIndex, int64 price, int16 exponent, uint64 timestampUs, uint64 feedUs);

	error ZeroAddress();
	error BadPayloadMagic();
	error PayloadTooShort();
	error FeedNotFound(uint256 pairIndex, uint32 lazerFeedId);
	error UnknownProperty(uint8 property);
	error DuplicateProperty(uint8 property);
	error IncompleteFeed(uint256 pairIndex);
	error NonPositivePrice(uint256 pairIndex);
	error FeedUpdateAfterHeader(uint64 feedTimestampUs, uint64 headerTimestampUs);
	error FeedFromFuture(uint64 timestampUs);
	error PacketTooOld(uint64 headerTimestampUs);

	constructor(IPythLazerVerifier lazer_, IVerantaPairStorage pairs_) {
		if (address(lazer_) == address(0) || address(pairs_) == address(0)) revert ZeroAddress();
		lazer = lazer_;
		pairs = pairs_;
	}

	/// @notice Verify one Pyth Lazer packet for `pairIndex`, signed within the last MAX_RELAY_AGE seconds, and store
	///         it when Pyth signed it later than the stored one, without ever going back to an older trade.
	/// @return stored false when the packet is valid but signed no later than the stored one, or carries an older
	///         trade than it (an out-of-order relay)
	function submit(uint256 pairIndex, bytes calldata update) external payable returns (bool stored) {
		(bytes memory payload,) = lazer.verifyUpdate{value: lazer.verification_fee()}(update);
		(Feed memory feed, uint64 headerUs) = _parse(payload, pairIndex, uint32(pairs.getLazerFeedId(pairIndex)));
		if (headerUs / 1e6 > block.timestamp) revert FeedFromFuture(headerUs);
		if (headerUs / 1e6 + MAX_RELAY_AGE < block.timestamp) revert PacketTooOld(headerUs);
		Latest memory current = latestOf[pairIndex];
		if (headerUs <= current.timestampUs || feed.timestampUs < current.feedUs) return false;

		latestOf[pairIndex] = Latest(feed.price, feed.exponent, headerUs, feed.timestampUs);
		emit PriceStored(pairIndex, feed.price, feed.exponent, headerUs, feed.timestampUs);
		return true;
	}

	/// @notice The newest stored price for `pairIndex` and when Pyth last confirmed it (timestampUs 0 = never stored).
	function latest(uint256 pairIndex) external view returns (int64 price, int16 exponent, uint64 timestampUs) {
		Latest memory l = latestOf[pairIndex];
		return (l.price, l.exponent, l.timestampUs);
	}

	/// @notice When the stored price last changed on its own market (the feed's update time, microseconds).
	function feedUpdatedUs(uint256 pairIndex) external view returns (uint64) {
		return latestOf[pairIndex].feedUs;
	}

	// ─── Lazer payload (VerantaPriceStore's parser, unchanged, also returning the header time) ───────────────────
	// header: magic u32 · timestamp u64 (µs) · channel u8 · feedsLen u8
	// feed:   id u32 · numProperties u8 · properties (id u8 + value), all big-endian

	function _parse(bytes memory payload, uint256 pairIndex, uint32 feedId)
		internal
		pure
		returns (Feed memory feed, uint64 headerTimestampUs)
	{
		if (_read(payload, 0, 4) != PAYLOAD_MAGIC) revert BadPayloadMagic();
		headerTimestampUs = uint64(_read(payload, 4, 8));
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

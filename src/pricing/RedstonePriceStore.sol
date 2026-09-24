// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/// @title RedstonePriceStore
/// @notice On-chain store for RedStone signed price packages (pull oracle, like Pyth Core):
///         anyone may submit a feed's packages; the store verifies each signature against
///         the data service's fixed signer set, requires `threshold` distinct signers on one
///         shared timestamp, and stores the MEDIAN. RedstoneAggregatorAdapter exposes a
///         stored feed as an AggregatorV3 for the ValueInterpreter.
/// @dev Our own implementation of the published package format — no RedStone code. The
///      format was verified 2026-09-24 by recovering the signer of every one of 4,794 live
///      redstone-primary-prod price packages (gateway JSON):
///        signed bytes = feedId (bytes32, utf8 right-padded) ‖ value (uint256, 8 decimals)
///                       ‖ timestampMs (6 bytes) ‖ valueByteSize = 32 (4 bytes) ‖ count = 1 (3 bytes)
///        signer = ecrecover(keccak256(signed bytes), sig) — raw hash, no EIP-191 prefix.
///      Signer set + threshold are CONSTRUCTOR-FIXED (config is attack surface): if the data
///      service rotates signers, deploy a new store and re-point the adapters.
///      Anti-cherry-pick (security review 2026-09-22, H-3 — same lesson as the Pyth adapter):
///      a submission must be NEWER than what is stored (no rewinding) and at most
///      MAX_PACKAGE_AGE old on arrival (no reaching back into gateway history); the adapter's
///      maxPushAge then bounds how long a stored print may be read.
contract RedstonePriceStore {
	/// @dev RedStone's own consumer defaults (RedstoneDefaultsLib): 3 min delay, 1 min ahead
	uint256 public constant MAX_PACKAGE_AGE = 3 minutes;
	uint256 public constant MAX_PACKAGE_AHEAD = 1 minutes;
	uint256 private constant MAX_SIGNERS = 32;

	struct Latest {
		uint192 value; // 8 decimals
		uint64 timestampMs; // package timestamp (milliseconds)
	}

	/// @notice e.g. "redstone-primary-prod" — which service the signer set belongs to
	string public dataServiceId;
	uint8 public immutable threshold;
	uint8 public immutable signerCount;
	/// @dev signer → index + 1 (0 = not authorised)
	mapping(address signer => uint256) private signerSlot;
	mapping(bytes32 feedId => Latest) private latestOf;

	event PriceUpdated(bytes32 indexed feedId, uint256 value, uint64 timestampMs, uint256 signers);

	error BadSignerConfig();
	error LengthMismatch();
	error NotNewer(bytes32 feedId, uint64 timestampMs, uint64 storedTimestampMs);
	error PackageTooOld(uint64 timestampMs);
	error PackageFromFuture(uint64 timestampMs);
	error SignerNotAuthorised(address signer);
	error DuplicateSigner(address signer);
	error NotEnoughSigners(uint256 got, uint256 needed);
	error ValueOutOfRange(uint256 value);

	constructor(string memory dataServiceId_, address[] memory signers, uint8 threshold_) {
		if (signers.length == 0 || signers.length > MAX_SIGNERS) revert BadSignerConfig();
		if (threshold_ == 0 || threshold_ > signers.length) revert BadSignerConfig();
		for (uint256 i; i < signers.length; ++i) {
			if (signers[i] == address(0) || signerSlot[signers[i]] != 0) revert BadSignerConfig();
			signerSlot[signers[i]] = i + 1;
		}
		dataServiceId = dataServiceId_;
		threshold = threshold_;
		signerCount = uint8(signers.length);
	}

	/// @notice Store one feed's price from its signed packages (one value + signature per signer,
	///         all on the same timestamp — the gateway serves them that way).
	function update(bytes32 feedId, uint64 timestampMs, uint256[] calldata values, bytes[] calldata signatures) public {
		if (values.length != signatures.length) revert LengthMismatch();
		if (values.length < threshold) revert NotEnoughSigners(values.length, threshold);

		uint64 stored = latestOf[feedId].timestampMs;
		if (timestampMs <= stored) revert NotNewer(feedId, timestampMs, stored);
		uint256 ts = timestampMs / 1000;
		if (ts > block.timestamp + MAX_PACKAGE_AHEAD) revert PackageFromFuture(timestampMs);
		if (ts + MAX_PACKAGE_AGE < block.timestamp) revert PackageTooOld(timestampMs);

		uint256 seen; // bitmap of signer indexes
		uint256[] memory accepted = new uint256[](values.length);
		for (uint256 i; i < values.length; ++i) {
			address signer = ECDSA.recoverCalldata(_digest(feedId, values[i], timestampMs), signatures[i]);
			uint256 slot = signerSlot[signer];
			if (slot == 0) revert SignerNotAuthorised(signer);
			uint256 bit = 1 << (slot - 1);
			if (seen & bit != 0) revert DuplicateSigner(signer);
			seen |= bit;
			accepted[i] = values[i];
		}

		uint256 median = _median(accepted);
		if (median == 0 || median > type(uint192).max) revert ValueOutOfRange(median);
		latestOf[feedId] = Latest({value: uint192(median), timestampMs: timestampMs});
		emit PriceUpdated(feedId, median, timestampMs, values.length);
	}

	struct FeedUpdate {
		bytes32 feedId;
		uint64 timestampMs;
		uint256[] values;
		bytes[] signatures;
	}

	/// @notice Batch of `update`s — all-or-nothing (the keeper simulates first).
	function updateMany(FeedUpdate[] calldata updates) external {
		for (uint256 i; i < updates.length; ++i) {
			update(updates[i].feedId, updates[i].timestampMs, updates[i].values, updates[i].signatures);
		}
	}

	/// @notice Last stored median (8 decimals) and its package timestamp in ms; (0, 0) if never set.
	function latest(bytes32 feedId) external view returns (uint256 value, uint64 timestampMs) {
		Latest memory l = latestOf[feedId];
		return (l.value, l.timestampMs);
	}

	function isAuthorisedSigner(address signer) external view returns (bool) {
		return signerSlot[signer] != 0;
	}

	/// @dev keccak256 of the single-data-point package as RedStone nodes sign it
	function _digest(bytes32 feedId, uint256 value, uint64 timestampMs) internal pure returns (bytes32) {
		return keccak256(abi.encodePacked(feedId, value, uint48(timestampMs), uint32(32), uint24(1)));
	}

	/// @dev median of a small array (insertion sort); even count averages the middle two,
	///      matching RedStone's own aggregation
	function _median(uint256[] memory a) internal pure returns (uint256) {
		for (uint256 i = 1; i < a.length; ++i) {
			uint256 key = a[i];
			uint256 j = i;
			while (j > 0 && a[j - 1] > key) {
				a[j] = a[j - 1];
				--j;
			}
			a[j] = key;
		}
		uint256 mid = a.length / 2;
		return a.length % 2 == 1 ? a[mid] : (a[mid - 1] + a[mid]) / 2;
	}
}

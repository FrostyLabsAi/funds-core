// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IRedemptionQueue} from '../interfaces/IRedemptionQueue.sol';
import {ComptrollerV3} from '../core/ComptrollerV3.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {RedemptionMath} from './RedemptionMath.sol';
import {IRedemptionUnwinder} from '../interfaces/IRedemptionUnwinder.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

interface IFundRegistry {
	function funds(address comptroller)
		external
		view
		returns (address comptroller_, address vault, address shares, address fundOwner, uint64 createdAt);
	function guardian() external view returns (address);
}

/// @title RedemptionQueue
/// @notice Redemptions of V3 funds that hold external positions (perps, LPs), which the vault
///         can't pay on demand (founder 2026-10-06; spec docs/superpowers/specs/
///         2026-10-06-redemption-queue-design.md). An investor requests, their shares wait here in
///         escrow, the manager raises the cash, and anyone settles once the vault can pay, oldest
///         first, at that moment's NAV, in cash or in kind as the investor chose. Past a 4-day
///         deadline the fund is overdue and its manager's fees stop. A fallback that unwinds
///         overdue requests' share of the fund's perps is built in, switched off: governance
///         approves an unwinder, the guardian or governance switches it on, only governance
///         switches it off. One queue serves every V3 fund; each fund fixes its address at creation.
contract RedemptionQueue is IRedemptionQueue, Ownable2Step, ReentrancyGuard {
	using SafeERC20 for IERC20;

	enum Mode {
		Cash,
		InKind
	}

	struct Request {
		address investor;
		uint64 requestedAt;
		Mode mode;
		bool open;
		bool unwound; // the fallback closed this request's share of the perps: no more cancel
		uint256 shares;
	}

	/// @dev Open requests form a doubly linked list in request order, so a cancel or a payment
	///      unlinks in O(1) and nothing walks closed requests (final review 2026-10-06, C1: a
	///      request/cancel spam of dead entries otherwise priced the oldest request out of a block).
	struct Book {
		Request[] requests;
		uint256 firstPlusOne; // oldest open request's id + 1 (0 = none open)
		uint256 lastPlusOne; // newest open request's id + 1
		mapping(uint256 id => uint256) nextPlusOne;
		mapping(uint256 id => uint256) prevPlusOne;
		mapping(address investor => uint256) openIdPlusOne;
		uint64 unwoundAt; // when the batch still to be settled was unwound (its fill timeout)
	}

	/// @notice A request older than this makes the fund overdue: its manager's fees stop. Covers a
	///         three-day US market holiday weekend (~89 h to the next open).
	uint256 public constant DEADLINE = 4 days;
	/// @notice The deadline in force (DEADLINE; a test-only subclass shortens it for fork tests).
	function deadline() public view virtual returns (uint256) {
		return DEADLINE;
	}

	/// @notice How long settlement waits for the venue to fill an unwind's closes.
	uint256 public constant UNWIND_FILL_TIMEOUT = 1 hours;

	/// @notice The gas each call whose failure the queue acts on gets. A failure is acted on (a
	///         request bounced, a close skipped) only when the call had all of it; otherwise the
	///         caller may have starved it, and the transaction reverts (Gnosis Safe's safeTxGas
	///         pattern). A call that succeeds needs no headroom. Measured on a Base fork 2026-10-06:
	///         a Veranta close 313k, a collect 14k, a one-asset payout 41k (20 assets, the cap, ~1.1M).
	uint256 public constant PAYOUT_GAS = 3_000_000;
	uint256 public constant FORWARD_GAS = 2_000_000;
	uint256 public constant VIEW_GAS = 1_000_000;
	/// @notice A cancel's fee settlement: one fund valuation (~2.24M gas per perp account at 175
	///         Veranta pairs, 2026-10-07; funds keep ≤ 5 perp accounts). A wallet's gas estimate is
	///         the least gas that succeeds, so a merely tried settlement was starved by it (final
	///         review 2026-10-07): it now fails only with this much gas, or the cancel reverts.
	uint256 public constant FEE_GAS = 15_000_000;
	/// @dev Left after a failed call: enough to bounce a request and go on.
	uint256 internal constant GAS_RESERVE = 200_000;

	IFundRegistry public factory;

	mapping(address comptroller => Book) internal books;
	address[] internal unwinderList;
	mapping(address unwinder => bool) public isUnwinderApproved;
	mapping(address unwinder => bool) public isUnwinderOn;

	event RedemptionRequested(
		address indexed comptroller, address indexed investor, uint256 indexed id, uint256 shares, Mode mode
	);
	event RedemptionCancelled(address indexed comptroller, address indexed investor, uint256 indexed id);
	event RedemptionSettled(
		address indexed comptroller,
		address indexed investor,
		uint256 indexed id,
		uint256 shares,
		address[] assets,
		uint256[] amounts
	);
	event RedemptionBounced(address indexed comptroller, address indexed investor, uint256 indexed id, bytes reason);
	event RedemptionsUnwound(address indexed comptroller, uint256 requests, uint256 fractionWad);
	event UnwindCloseFailed(address indexed comptroller, address indexed position, bytes reason);
	event UnwindReleased(address indexed comptroller);
	event UnwinderApproved(address indexed unwinder, bool approved);
	event UnwinderSwitched(address indexed unwinder, bool on);
	event FactorySet(address indexed factory);

	error FactoryAlreadySet();
	error NotOurFund(address comptroller);
	error NoExternalPositions(address comptroller);
	error RequestExists();
	error NoRequest();
	error ZeroShares();
	error Unwound();
	error UnwinderNotApproved(address unwinder);
	error NotGovernanceOrGuardian();
	error OnlyOwnerSwitchesOff();
	error NothingSettled();
	error UnwinderOff();
	error UnwinderStillOn();
	error NotOverdue();
	error UnwindPending();
	error NothingUnwound();
	error CallStarved();

	constructor(address owner_) Ownable(owner_) {}

	/// @notice One-time wiring: the factory is created with this queue's address in its V3
	///         blueprint, so the queue learns the factory after both exist.
	function setFactory(address factory_) external onlyOwner {
		if (address(factory) != address(0)) revert FactoryAlreadySet();
		factory = IFundRegistry(factory_);
		emit FactorySet(factory_);
	}

	// ─── Requests ────────────────────────────────────────────────────────────────

	/// @notice Queue a redemption of `shares`, paid in `mode` at settlement. The shares move here
	///         (approve this queue first); the fund's shares-action timelock still applies.
	function requestRedeem(address comptroller, uint256 shares, Mode mode) external nonReentrant returns (uint256 id) {
		ComptrollerV3 fund = _ourFund(comptroller);
		if (fund.getExternalPositions().length == 0) revert NoExternalPositions(comptroller);
		if (shares == 0) revert ZeroShares();
		Book storage book = books[comptroller];
		if (book.openIdPlusOne[msg.sender] != 0) revert RequestExists();

		id = book.requests.length;
		book.requests.push(
			Request({investor: msg.sender, requestedAt: uint64(block.timestamp), mode: mode, open: true, unwound: false, shares: shares})
		);
		book.openIdPlusOne[msg.sender] = id + 1;
		_link(book, id);
		IERC20(address(fund.shares())).safeTransferFrom(msg.sender, address(this), shares);

		emit RedemptionRequested(comptroller, msg.sender, id, shares, mode);
	}

	/// @notice Take the shares back. Allowed until the fallback unwind has closed the request's share.
	///         Settles the fund's fees first while it is overdue.
	function cancel(address comptroller) external nonReentrant {
		Book storage book = books[comptroller];
		uint256 idPlusOne = book.openIdPlusOne[msg.sender];
		if (idPlusOne == 0) revert NoRequest();
		Request storage request = book.requests[idPlusOne - 1];
		if (request.unwound) revert Unwound();
		// fees settle while the fund is still overdue, so giving up doesn't hand the manager the
		// overdue period (final review 2026-10-06, I3); tried, never required: a price that can't
		// be read must not keep anyone from cancelling
		if (isOverdue(comptroller)) _trySettleFees(ComptrollerV3(comptroller));

		_close(book, idPlusOne - 1);
		IERC20(address(ComptrollerV3(comptroller).shares())).safeTransfer(msg.sender, request.shares);

		emit RedemptionCancelled(comptroller, msg.sender, idPlusOne - 1);
	}

	// ─── Settlement ──────────────────────────────────────────────────────────────

	/// @notice Pay up to `maxRequests` queued redemptions, oldest first, at this moment's NAV (fees
	///         settle first when the fund can be valued, so escrowed shares bear them like
	///         everyone's). Stops at the first request the vault's USDC can't cover in full, so
	///         nobody is paid ahead of an older request. Anyone may call it (normally the keeper,
	///         once the manager raised the cash; perp prices stored in the same transaction). A
	///         request whose payout reverts (a token refuses its investor) gets its shares back and
	///         the queue moves on; `settled` counts it. Reverts when nothing could be settled.
	function settle(address comptroller, uint256 maxRequests) external nonReentrant returns (uint256 settled) {
		ComptrollerV3 fund = _ourFund(comptroller);
		Book storage book = books[comptroller];
		// an unwound batch settles first, by the fallback's rules, while an unwinder can still collect
		// (switched off since: releaseUnwound makes them ordinary requests again)
		if (_batchPending(book) && _anyUnwinderOn()) return _settleUnwound(fund, book, maxRequests);
		RedemptionMath.Snapshot memory snap = _settleAndSnapshot(fund);
		uint256 usdcLeft = IERC20(snap.denom).balanceOf(address(fund.vault()));

		for (uint256 idPlusOne = book.firstPlusOne; idPlusOne != 0 && settled < maxRequests;) {
			uint256 id = idPlusOne - 1;
			idPlusOne = book.nextPlusOne[id];
			Request storage request = book.requests[id];
			uint256[] memory amounts = request.mode == Mode.Cash
				? RedemptionMath.cashPayout(snap, request.shares)
				: RedemptionMath.inKindPayout(snap, request.shares);
			uint256 need = RedemptionMath.usdcNeeded(snap, amounts);
			if (need > usdcLeft) break;
			if (_pay(fund, book, id, request.shares, snap.assets, amounts)) usdcLeft -= need;
			++settled;
		}
		if (settled == 0) revert NothingSettled();
	}

	// ─── The fallback unwind (switched off until governance approves and switches on) ──

	/// @notice Once an approved unwinder is switched on, anyone may close the share of the fund's
	///         perps that its overdue requests own. Those requests can no longer be cancelled;
	///         settle pays them once the closes filled (or after UNWIND_FILL_TIMEOUT). The caller
	///         stores fresh perp prices in the same transaction (the unwinder refuses old ones).
	///         An unwinder that can't describe the closes (a price too old) reverts the whole
	///         unwind: nothing is marked and the requests stay cancellable. A close the venue
	///         refuses is reported; settlement covers its share from the vault's tokens and what
	///         they can't cover stays queued. At most `maxRequests` overdue requests, oldest
	///         first, make one batch.
	function unwindOverdue(address comptroller, uint256 maxRequests) external nonReentrant {
		ComptrollerV3 fund = _ourFund(comptroller);
		if (!_anyUnwinderOn()) revert UnwinderOff();
		Book storage book = books[comptroller];
		if (_batchPending(book)) revert UnwindPending();

		uint256 overdueShares;
		uint256 count;
		for (uint256 idPlusOne = book.firstPlusOne; idPlusOne != 0 && count < maxRequests;) {
			Request storage request = book.requests[idPlusOne - 1];
			idPlusOne = book.nextPlusOne[idPlusOne - 1];
			if (block.timestamp <= request.requestedAt + deadline()) break;
			request.unwound = true;
			overdueShares += request.shares;
			++count;
		}
		if (count == 0) revert NotOverdue();
		book.unwoundAt = uint64(block.timestamp);
		uint256 fraction = Math.mulDiv(overdueShares, 1e18, fund.shares().totalSupply());

		address[] memory positions = fund.getExternalPositions();
		for (uint256 i; i < positions.length; ++i) {
			IRedemptionUnwinder unwinder = _unwinderFor(positions[i]);
			if (address(unwinder) == address(0)) continue;
			// never caught (final review 2026-10-06, C2): a batch marked unwound with nothing closed
			// would be paid only what the vault holds
			bytes[] memory actions = unwinder.closeActions(positions[i], fraction);
			for (uint256 j; j < actions.length; ++j) {
				_forward(fund, positions[i], actions[j]);
			}
		}
		emit RedemptionsUnwound(comptroller, count, fraction);
	}

	/// @notice With every unwinder switched off, an unwound batch can't be collected: its requests
	///         become ordinary ones again (cancel works; they wait for the manager). Anyone may call it.
	function releaseUnwound(address comptroller) external nonReentrant {
		if (_anyUnwinderOn()) revert UnwinderStillOn();
		Book storage book = books[comptroller];
		if (!_batchPending(book)) revert NothingUnwound();
		_endBatch(book);
		emit UnwindReleased(comptroller);
	}

	/// @dev Collect the unwind's USDC into the vault, then pay the unwound requests by the
	///      fallback's rules from one snapshot. Newer requests wait for the next settle (covering a
	///      shortfall from the vault's tokens shifts the mix their snapshot would assume). Once the
	///      vault runs out, the batch ends: what is unpaid stays queued as ordinary requests.
	function _settleUnwound(ComptrollerV3 fund, Book storage book, uint256 maxRequests) internal returns (uint256 settled) {
		address[] memory positions = fund.getExternalPositions();
		bool waiting = block.timestamp < book.unwoundAt + UNWIND_FILL_TIMEOUT;
		for (uint256 i; i < positions.length; ++i) {
			IRedemptionUnwinder unwinder = _unwinderFor(positions[i]);
			if (address(unwinder) == address(0)) continue;
			if (waiting && _pending(unwinder, positions[i])) revert UnwindPending();
			uint256 gasBefore = gasleft();
			try unwinder.collectAction{gas: VIEW_GAS}(positions[i]) returns (bytes memory action) {
				if (action.length != 0) _forward(fund, positions[i], action);
			} catch (bytes memory reason) {
				_hadAllowance(gasBefore, VIEW_GAS);
				emit UnwindCloseFailed(address(fund), positions[i], reason);
			}
		}

		bool batchLeft;
		(settled, batchLeft) = _payUnwound(fund, book, _settleAndSnapshot(fund), maxRequests);
		if (!batchLeft) _endBatch(book);
		else if (settled == 0) revert NothingSettled();
	}

	/// @dev Pays the unwound requests, oldest first, by the fallback's rules from one snapshot, and
	///      stops where the vault runs out; `batchLeft` when `maxRequests` stopped it first.
	function _payUnwound(ComptrollerV3 fund, Book storage book, RedemptionMath.Snapshot memory snap, uint256 maxRequests)
		internal
		returns (uint256 settled, bool batchLeft)
	{
		uint256[] memory remaining = new uint256[](snap.balances.length);
		for (uint256 i; i < remaining.length; ++i) {
			remaining[i] = snap.balances[i];
		}
		for (uint256 idPlusOne = book.firstPlusOne; idPlusOne != 0;) {
			uint256 id = idPlusOne - 1;
			idPlusOne = book.nextPlusOne[id];
			if (!book.requests[id].unwound) break;
			if (settled == maxRequests) return (settled, true);
			(bool paid, bool whole) = _payOneUnwound(fund, book, id, snap, remaining);
			if (!paid) break;
			++settled;
			if (!whole) break;
		}
	}

	/// @dev Pays what the vault can cover of unwound request `id`; `whole` when that is all of it.
	function _payOneUnwound(
		ComptrollerV3 fund,
		Book storage book,
		uint256 id,
		RedemptionMath.Snapshot memory snap,
		uint256[] memory remaining
	) internal returns (bool paid, bool whole) {
		Request storage request = book.requests[id];
		uint256 d = _indexOf(snap.assets, snap.denom);
		(uint256[] memory amounts, uint256 paidShares) =
			RedemptionMath.fallbackPayout(snap, request.shares, remaining[d], remaining);
		if (paidShares == 0) return (false, false);
		// a partly paid request keeps its flag until _endBatch releases it with the rest of the batch
		whole = paidShares == request.shares;
		if (!_pay(fund, book, id, paidShares, snap.assets, amounts)) return (true, true); // bounced
		for (uint256 i; i < amounts.length; ++i) {
			remaining[i] -= amounts[i];
		}
		return (true, whole);
	}

	/// @dev An unwound batch is still to be settled: unwound requests are always the oldest open
	///      ones, so the oldest open request says it. Derived, never stored (final review
	///      2026-10-06, I1: a stored marker outlived a batch the ordinary path had paid).
	function _batchPending(Book storage book) internal view returns (bool) {
		uint256 first = book.firstPlusOne;
		return first != 0 && book.requests[first - 1].unwound;
	}

	/// @dev Ends the unwound batch: what is still open of it becomes ordinary requests again.
	function _endBatch(Book storage book) internal {
		for (uint256 idPlusOne = book.firstPlusOne; idPlusOne != 0;) {
			Request storage request = book.requests[idPlusOne - 1];
			if (!request.unwound) break;
			request.unwound = false;
			idPlusOne = book.nextPlusOne[idPlusOne - 1];
		}
		book.unwoundAt = 0;
	}

	/// @dev Tried, never required: a price that can't be read now (a stale feed) must not keep
	///      anyone from cancelling (final review 2026-10-06, I4; README rule 6) — but a failure counts
	///      only with the whole FEE_GAS, so the caller's gas can't skip it.
	function _trySettleFees(ComptrollerV3 fund) internal {
		uint256 gasBefore = gasleft();
		try fund.settleFees{gas: FEE_GAS}() {}
		catch {
			_hadAllowance(gasBefore, FEE_GAS);
		}
	}

	function _forward(ComptrollerV3 fund, address position, bytes memory action) internal {
		uint256 gasBefore = gasleft();
		try fund.forwardUnwind{gas: FORWARD_GAS}(position, action) {}
		catch (bytes memory reason) {
			_hadAllowance(gasBefore, FORWARD_GAS);
			emit UnwindCloseFailed(address(fund), position, reason);
		}
	}

	/// @dev A call that failed with `gasBefore` left before it had its whole `allowance` (EIP-150
	///      forwards at most 63/64 of what is left), with room after it to act on the failure;
	///      otherwise the caller may have starved it, and nothing is acted on.
	function _hadAllowance(uint256 gasBefore, uint256 allowance) internal pure {
		if (gasBefore < allowance + allowance / 63 + GAS_RESERVE) revert CallStarved();
	}

	/// @dev The first switched-on unwinder that can unwind `position`, or none.
	function _unwinderFor(address position) internal view returns (IRedemptionUnwinder) {
		for (uint256 i; i < unwinderList.length; ++i) {
			address unwinder = unwinderList[i];
			if (!isUnwinderOn[unwinder]) continue;
			uint256 gasBefore = gasleft();
			try IRedemptionUnwinder(unwinder).canUnwind{gas: VIEW_GAS}(position) returns (bool ok) {
				if (ok) return IRedemptionUnwinder(unwinder);
			} catch {
				_hadAllowance(gasBefore, VIEW_GAS);
			}
		}
		return IRedemptionUnwinder(address(0));
	}

	function _pending(IRedemptionUnwinder unwinder, address position) internal view returns (bool) {
		uint256 gasBefore = gasleft();
		try unwinder.hasPending{gas: VIEW_GAS}(position) returns (bool pending) {
			return pending;
		} catch {
			_hadAllowance(gasBefore, VIEW_GAS);
			return false;
		}
	}

	function _anyUnwinderOn() internal view returns (bool) {
		for (uint256 i; i < unwinderList.length; ++i) {
			if (isUnwinderOn[unwinderList[i]]) return true;
		}
		return false;
	}

	function _indexOf(address[] memory assets, address asset) internal pure returns (uint256) {
		for (uint256 i; i < assets.length; ++i) {
			if (assets[i] == asset) return i;
		}
		revert RedemptionMath.DenominationNotTracked();
	}

	/// @dev Pays `shares` of request `id` (all of it, or the part the fallback could cover; the rest
	///      stays queued). When the payout reverts, the request bounces instead: closed, its whole
	///      escrow back to the investor, `paid` false (final review 2026-10-06, I2: one investor a
	///      token refuses, e.g. a blacklisted address, must not block every request behind it).
	function _pay(
		ComptrollerV3 fund,
		Book storage book,
		uint256 id,
		uint256 shares,
		address[] memory assets,
		uint256[] memory amounts
	) internal returns (bool paid) {
		Request storage request = book.requests[id];
		address investor = request.investor;
		uint256 escrow = request.shares;
		if (shares == escrow) _close(book, id);
		else request.shares = escrow - shares;
		uint256 gasBefore = gasleft();
		try fund.payOutRedemption{gas: PAYOUT_GAS}(investor, shares, assets, amounts) {
			emit RedemptionSettled(address(fund), investor, id, shares, assets, amounts);
			return true;
		} catch (bytes memory reason) {
			_hadAllowance(gasBefore, PAYOUT_GAS);
			if (shares != escrow) _close(book, id);
			IERC20(address(fund.shares())).safeTransfer(investor, escrow);
			emit RedemptionBounced(address(fund), investor, id, reason);
		}
	}

	/// @dev Fees settle and the fund is valued once, in the comptroller (2026-10-07: valuing it here
	///      again cost ~1.5M gas more per perp account). The valuation is tolerant: a token whose
	///      price can't be read now (a stale feed), or that is pool-priced, is paid in kind (final
	///      review 2026-10-06, I4; README rule 6); positions revert if unreadable.
	function _settleAndSnapshot(ComptrollerV3 fund) internal returns (RedemptionMath.Snapshot memory snap) {
		(snap.assets, snap.balances, snap.values, snap.inKind, snap.positionsValue) =
			abi.decode(fund.settleFeesForRedemption(), (address[], uint256[], uint256[], bool[], uint256));
		snap.denom = address(fund.denominationAsset());
		snap.supply = fund.shares().totalSupply();
	}

	// ─── Views ───────────────────────────────────────────────────────────────────

	/// @inheritdoc IRedemptionQueue
	function isOverdue(address comptroller) public view returns (bool) {
		Book storage book = books[comptroller];
		uint256 first = book.firstPlusOne;
		return first != 0 && block.timestamp > book.requests[first - 1].requestedAt + deadline();
	}

	function requestOf(address comptroller, address investor)
		external
		view
		returns (bool exists, uint256 id, Request memory request)
	{
		uint256 idPlusOne = books[comptroller].openIdPlusOne[investor];
		if (idPlusOne == 0) return (false, 0, request);
		return (true, idPlusOne - 1, books[comptroller].requests[idPlusOne - 1]);
	}

	function requestAt(address comptroller, uint256 id) external view returns (Request memory) {
		return books[comptroller].requests[id];
	}

	/// @notice The oldest open request (`length` when none is open) and the number of requests ever made.
	function queueBounds(address comptroller) external view returns (uint256 head, uint256 length) {
		Book storage book = books[comptroller];
		length = book.requests.length;
		head = book.firstPlusOne == 0 ? length : book.firstPlusOne - 1;
	}

	/// @notice The next open request after `id` in queue order (`exists` false at the end).
	function nextOpen(address comptroller, uint256 id) external view returns (bool exists, uint256 nextId) {
		uint256 nextPlusOne = books[comptroller].nextPlusOne[id];
		return (nextPlusOne != 0, nextPlusOne == 0 ? 0 : nextPlusOne - 1);
	}

	// ─── The unwinder switch ─────────────────────────────────────────────────────

	/// @notice Governance approves (or withdraws) an unwinder contract. Withdrawing switches it off.
	function approveUnwinder(address unwinder, bool approved) external onlyOwner {
		if (approved && !isUnwinderApproved[unwinder]) {
			bool listed;
			for (uint256 i; i < unwinderList.length; ++i) {
				if (unwinderList[i] == unwinder) listed = true;
			}
			if (!listed) unwinderList.push(unwinder);
		}
		isUnwinderApproved[unwinder] = approved;
		if (!approved && isUnwinderOn[unwinder]) {
			isUnwinderOn[unwinder] = false;
			emit UnwinderSwitched(unwinder, false);
		}
		emit UnwinderApproved(unwinder, approved);
	}

	/// @notice Switch an approved unwinder on (governance or the factory's guardian) or off
	///         (governance only), so a fast response to an absent manager never waits on a
	///         timelock and a compromised guardian can't plug in its own unwinder.
	function setUnwinderOn(address unwinder, bool on) external {
		if (on) {
			if (msg.sender != owner() && msg.sender != factory.guardian()) revert NotGovernanceOrGuardian();
			if (!isUnwinderApproved[unwinder]) revert UnwinderNotApproved(unwinder);
		} else if (msg.sender != owner()) {
			revert OnlyOwnerSwitchesOff();
		}
		isUnwinderOn[unwinder] = on;
		emit UnwinderSwitched(unwinder, on);
	}

	function unwinders() external view returns (address[] memory) {
		return unwinderList;
	}

	// ─── Internals ───────────────────────────────────────────────────────────────

	/// @dev A fund our factory created whose comptroller is bound to this queue.
	function _ourFund(address comptroller) internal view returns (ComptrollerV3 fund) {
		(address registered,,,,) = factory.funds(comptroller);
		if (registered != comptroller || comptroller == address(0)) revert NotOurFund(comptroller);
		fund = ComptrollerV3(comptroller);
		if (address(fund.redemptionQueue()) != address(this)) revert NotOurFund(comptroller);
	}

	/// @dev Appends request `id` to the open list.
	function _link(Book storage book, uint256 id) internal {
		uint256 last = book.lastPlusOne;
		if (last == 0) book.firstPlusOne = id + 1;
		else book.nextPlusOne[last - 1] = id + 1;
		book.prevPlusOne[id] = last;
		book.lastPlusOne = id + 1;
	}

	/// @dev Closes request `id`: off the open list, and its investor may request again.
	function _close(Book storage book, uint256 id) internal {
		Request storage request = book.requests[id];
		request.open = false;
		delete book.openIdPlusOne[request.investor];
		uint256 prev = book.prevPlusOne[id];
		uint256 next = book.nextPlusOne[id];
		if (prev == 0) book.firstPlusOne = next;
		else book.nextPlusOne[prev - 1] = next;
		if (next == 0) book.lastPlusOne = prev;
		else book.prevPlusOne[next - 1] = prev;
		delete book.prevPlusOne[id];
		delete book.nextPlusOne[id];
	}
}

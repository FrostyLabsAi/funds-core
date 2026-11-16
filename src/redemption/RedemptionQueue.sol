// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {IRedemptionQueue} from '../interfaces/IRedemptionQueue.sol';
import {IComptroller} from '../interfaces/IComptroller.sol';
import {IFundRegistry} from '../interfaces/IFundRegistry.sol';
import {IIntegrationAdapter} from '../interfaces/IIntegrationAdapter.sol';

/// @title RedemptionQueue
/// @notice Fund redemptions, all in USDC (founder 2026-10-11, PLAN_CASH_ONLY_EXIT_2026-10-11.md). An
///         investor requests and their shares wait here in escrow; the manager sees the request and decides what to
///         sell; the manager or the keeper settles once the vault's USDC covers it, oldest first, at that moment's NAV.
///         Past a 4-day deadline the fund is overdue: the manager's fees stop, the manager can't spend the vault's
///         USDC, and the keeper may liquidate the fund into USDC (ComptrollerLib). Only the manager or the keeper
///         settles, so nobody picks the moment a 30-minute pool price is wrong (D1); only the keeper liquidates (D3).
///         One queue serves every fund; each fund fixes its address at creation.
contract RedemptionQueue is IRedemptionQueue, Ownable2Step, ReentrancyGuard {
	using SafeERC20 for IERC20;

	struct Request {
		address investor;
		uint64 requestedAt;
		bool open;
		uint256 shares; // still escrowed: a part-paid request keeps the rest
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
		uint64 liquidatedAt; // the keeper's last liquidation of this fund
	}

	/// @notice A request older than this makes the fund overdue: its manager's fees stop. Covers a
	///         three-day US market holiday weekend (~89 h to the next open).
	uint256 public constant DEADLINE = 4 days;
	/// @notice The deadline in force (DEADLINE; a test-only subclass shortens it for fork tests).
	function deadline() public view virtual returns (uint256) {
		return DEADLINE;
	}

	/// @notice The gas a payout gets (a share burn and one USDC transfer, ~60k). A payout that fails is acted on (its
	///         request bounced) only when it had all of it; otherwise the caller may have starved it, and the
	///         transaction reverts (Gnosis Safe's safeTxGas pattern).
	uint256 public constant PAYOUT_GAS = 1_000_000;
	/// @notice A cancel's fee settlement: one fund valuation (~2.24M gas per perp account at 175 Veranta pairs,
	///         2026-10-07). It fails only with this much gas, or the cancel reverts (final review 2026-10-07).
	uint256 public constant FEE_GAS = 15_000_000;
	/// @dev Left after a failed call: enough to bounce a request and go on.
	uint256 internal constant GAS_RESERVE = 200_000;

	IFundRegistry public factory;

	mapping(address comptroller => Book) internal books;
	/// @notice Governance's keepers: they settle any fund and liquidate an overdue one.
	mapping(address keeper => bool) public isKeeper;

	event RedemptionRequested(address indexed comptroller, address indexed investor, uint256 indexed id, uint256 shares);
	event RedemptionCancelled(address indexed comptroller, address indexed investor, uint256 indexed id);
	event RedemptionSettled(
		address indexed comptroller, address indexed investor, uint256 indexed id, uint256 shares, uint256 amount
	);
	event RedemptionBounced(address indexed comptroller, address indexed investor, uint256 indexed id, bytes reason);
	event FundLiquidated(address indexed comptroller, address indexed keeper);
	event KeeperSet(address indexed keeper, bool isKeeper);
	event FactorySet(address indexed factory);

	error FactoryAlreadySet();
	error NotOurFund(address comptroller);
	error RequestExists();
	error NoRequest();
	error ZeroShares();
	error BeingLiquidated();
	error NotManagerOrKeeper();
	error NotKeeper();
	error PriceUnreadable();
	error NothingSettled();
	error NotOverdue();
	error CallStarved();

	constructor(address owner_) Ownable(owner_) {}

	/// @notice One-time wiring: the factory is created after this queue, whose address the comptroller blueprint holds.
	function setFactory(address factory_) external onlyOwner {
		if (address(factory) != address(0)) revert FactoryAlreadySet();
		factory = IFundRegistry(factory_);
		emit FactorySet(factory_);
	}

	/// @notice Governance adds or removes a keeper.
	function setKeeper(address keeper, bool on) external onlyOwner {
		isKeeper[keeper] = on;
		emit KeeperSet(keeper, on);
	}

	// ─── Requests ────────────────────────────────────────────────────────────────

	/// @notice Queue a redemption of `shares`, paid in USDC at settlement. The shares move here (approve this queue
	///         first); the fund's shares-action timelock still applies.
	function requestRedeem(address comptroller, uint256 shares) external nonReentrant returns (uint256 id) {
		IComptroller fund = _ourFund(comptroller);
		if (shares == 0) revert ZeroShares();
		Book storage book = books[comptroller];
		if (book.openIdPlusOne[msg.sender] != 0) revert RequestExists();

		id = book.requests.length;
		book.requests.push(Request({investor: msg.sender, requestedAt: uint64(block.timestamp), open: true, shares: shares}));
		book.openIdPlusOne[msg.sender] = id + 1;
		_link(book, id);
		IERC20(address(fund.shares())).safeTransferFrom(msg.sender, address(this), shares);

		emit RedemptionRequested(comptroller, msg.sender, id, shares);
	}

	/// @notice Take the shares back, unless the keeper has liquidated the fund since this request was overdue (the
	///         fund was sold for it). Settles the fund's fees first while it is overdue.
	function cancel(address comptroller) external nonReentrant {
		Book storage book = books[comptroller];
		uint256 idPlusOne = book.openIdPlusOne[msg.sender];
		if (idPlusOne == 0) revert NoRequest();
		Request storage request = book.requests[idPlusOne - 1];
		if (request.requestedAt + deadline() < book.liquidatedAt) revert BeingLiquidated();
		// fees settle while the fund is still overdue, so giving up doesn't hand the manager the
		// overdue period (final review 2026-10-06, I3); tried, never required: a price that can't
		// be read must not keep anyone from cancelling
		if (isOverdue(comptroller)) _trySettleFees(IComptroller(comptroller));

		uint256 escrow = request.shares;
		_close(book, idPlusOne - 1);
		IERC20(address(IComptroller(comptroller).shares())).safeTransfer(msg.sender, escrow);

		emit RedemptionCancelled(comptroller, msg.sender, idPlusOne - 1);
	}

	// ─── Settlement ──────────────────────────────────────────────────────────────

	/// @notice Pay up to `maxRequests` queued redemptions in USDC, oldest first, at this moment's NAV (fees settle
	///         first, so escrowed shares bear them like everyone's). Needs every price to read: a price that can't be
	///         read now holds settlement until it can, so nobody is paid for a holding at $0. The oldest request the
	///         vault's USDC can't cover in full is paid in part, and nothing newer is paid ahead of it. Only the fund's
	///         manager or a keeper calls it (D1). A request whose payout reverts (USDC refuses its investor) gets its
	///         shares back and the queue moves on; `settled` counts it. Reverts when nothing could be settled.
	function settle(address comptroller, uint256 maxRequests) external nonReentrant returns (uint256 settled) {
		IComptroller fund = _ourFund(comptroller);
		if (msg.sender != fund.fundOwner() && !isKeeper[msg.sender]) revert NotManagerOrKeeper();
		Book storage book = books[comptroller];
		(uint256 gav, bool complete) = fund.settleFeesForRedemption();
		if (!complete) revert PriceUnreadable();
		uint256 supply = fund.shares().totalSupply();
		uint256 usdcLeft = fund.denominationAsset().balanceOf(address(fund.vault()));

		for (uint256 idPlusOne = book.firstPlusOne; idPlusOne != 0 && settled < maxRequests;) {
			uint256 id = idPlusOne - 1;
			idPlusOne = book.nextPlusOne[id];
			uint256 shares = book.requests[id].shares;
			uint256 owed = Math.mulDiv(gav, shares, supply);
			if (owed > usdcLeft) {
				// the most of it the USDC left covers; the rest stays queued, still the oldest
				shares = Math.mulDiv(usdcLeft, supply, gav);
				if (shares == 0) break;
				owed = Math.mulDiv(gav, shares, supply);
				idPlusOne = 0;
			}
			if (_pay(fund, book, id, shares, owed)) usdcLeft -= owed;
			++settled;
		}
		if (settled == 0) revert NothingSettled();
	}

	// ─── Liquidation (the keeper, once the fund is overdue) ──────────────────────

	/// @notice Sell tracked tokens into USDC (ComptrollerLib.liquidateTrade: at most a 3% loss to the oracle, plus the
	///         tax recorded for the pool it sells through). Returns how much of the sale's one incoming asset reached the
	///         vault, so the keeper can simulate a sale and send it with that, less a slack, as its minimum (founder
	///         2026-11-15: a minimum of 0 left a front-runner the whole cap).
	function liquidate(address comptroller, address adapter, bytes calldata integrationData)
		external
		nonReentrant
		returns (uint256 received)
	{
		IComptroller fund = _ourOverdueFund(comptroller);
		(,, address[] memory incoming,) = IIntegrationAdapter(adapter).parseAssetsForAction(integrationData);
		// not one incoming asset is not a sale: liquidateTrade reverts NotASale
		address asset = incoming.length == 1 ? incoming[0] : address(0);
		address vault = address(fund.vault());
		uint256 before = asset == address(0) ? 0 : IERC20(asset).balanceOf(vault);
		fund.liquidateTrade(adapter, integrationData);
		if (asset != address(0)) received = IERC20(asset).balanceOf(vault) - before;
	}

	/// @notice Close, cancel or pull back what a position holds (ComptrollerLib.liquidatePosition).
	function liquidatePosition(
		address comptroller,
		address position,
		address[] calldata assetsToReceive,
		bytes[] calldata actions
	) external nonReentrant {
		_ourOverdueFund(comptroller).liquidatePosition(position, assetsToReceive, actions);
	}

	/// @dev A keeper's liquidation of an overdue fund: marks the time, so the requests overdue now can't be cancelled.
	function _ourOverdueFund(address comptroller) internal returns (IComptroller fund) {
		if (!isKeeper[msg.sender]) revert NotKeeper();
		fund = _ourFund(comptroller);
		if (!isOverdue(comptroller)) revert NotOverdue();
		books[comptroller].liquidatedAt = uint64(block.timestamp);
		emit FundLiquidated(comptroller, msg.sender);
	}

	/// @dev Tried, never required: a price that can't be read now (a stale feed) must not keep
	///      anyone from cancelling (final review 2026-10-06, I4; README rule 6) — but a failure counts
	///      only with the whole FEE_GAS, so the caller's gas can't skip it.
	function _trySettleFees(IComptroller fund) internal {
		uint256 gasBefore = gasleft();
		try fund.settleFees{gas: FEE_GAS}() {}
		catch {
			_hadAllowance(gasBefore, FEE_GAS);
		}
	}

	/// @dev A call that failed with `gasBefore` left before it had its whole `allowance` (EIP-150
	///      forwards at most 63/64 of what is left), with room after it to act on the failure;
	///      otherwise the caller may have starved it, and nothing is acted on.
	function _hadAllowance(uint256 gasBefore, uint256 allowance) internal pure {
		if (gasBefore < allowance + allowance / 63 + GAS_RESERVE) revert CallStarved();
	}

	/// @dev Pays `shares` of request `id` with `amount` of USDC (all of it, or the part the USDC covers; the rest
	///      stays queued). When the payout reverts, the request bounces instead: closed, its whole escrow back to
	///      the investor, `paid` false (final review 2026-10-06, I2: one investor USDC refuses, e.g. a
	///      blacklisted address, must not block every request behind it).
	function _pay(IComptroller fund, Book storage book, uint256 id, uint256 shares, uint256 amount)
		internal
		returns (bool paid)
	{
		Request storage request = book.requests[id];
		address investor = request.investor;
		uint256 escrow = request.shares;
		if (shares == escrow) _close(book, id);
		else request.shares = escrow - shares;
		uint256 gasBefore = gasleft();
		try fund.payOutRedemption{gas: PAYOUT_GAS}(investor, shares, amount) {
			emit RedemptionSettled(address(fund), investor, id, shares, amount);
			return true;
		} catch (bytes memory reason) {
			_hadAllowance(gasBefore, PAYOUT_GAS);
			if (shares != escrow) _close(book, id);
			IERC20(address(fund.shares())).safeTransfer(investor, escrow);
			emit RedemptionBounced(address(fund), investor, id, reason);
		}
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

	/// @notice When the keeper last liquidated `comptroller` (0 = never): requests overdue then can't be cancelled.
	function liquidatedAt(address comptroller) external view returns (uint64) {
		return books[comptroller].liquidatedAt;
	}

	// ─── Internals ───────────────────────────────────────────────────────────────

	/// @dev A fund our factory created whose comptroller is bound to this queue.
	function _ourFund(address comptroller) internal view returns (IComptroller fund) {
		(address registered,,,,) = factory.funds(comptroller);
		if (registered != comptroller || comptroller == address(0)) revert NotOurFund(comptroller);
		fund = IComptroller(comptroller);
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

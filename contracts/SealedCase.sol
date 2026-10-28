// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SealedCase
 * @notice Sealed-bid auctions on BOT Chain, settled at the second price.
 *
 * Nobody sees a bid until the reveal window opens. Bidders commit a hash,
 * post an identical deposit, and reveal afterwards. The highest revealed bid
 * wins but pays the *second* highest — or the reserve, whichever is larger —
 * so there is nothing to gain from shading your number.
 *
 * Three rules keep the envelope honest:
 *
 *  1. The deposit is identical for every bidder, so the amount staked leaks
 *     nothing about the bid inside the envelope.
 *  2. A commitment is bound to the bidder's address, so an envelope copied
 *     off the mempool cannot be reused by somebody else.
 *  3. Commit and fail to reveal and your deposit goes to the seller. A bidder
 *     who only reveals when the number suits them pays for the privilege.
 */
contract SealedCase is Ownable, Pausable, ReentrancyGuard {
    enum Outcome {
        Open,
        Sold,
        Unsold,
        Defaulted
    }

    struct Auction {
        address seller;
        uint256 reservePrice;
        uint256 deposit;
        uint64 commitEndsAt;
        uint64 revealEndsAt;
        uint64 payEndsAt;
        address highBidder;
        uint256 highBid;
        uint256 secondBid;
        uint256 clearingPrice;
        uint32 bidCount;
        uint32 revealCount;
        bool settled;
        bool paid;
        Outcome outcome;
        string item;
    }

    uint64 public constant MIN_WINDOW = 1 hours;
    uint64 public constant MAX_WINDOW = 30 days;
    uint64 public constant PAY_WINDOW = 24 hours;
    uint256 public constant MIN_DEPOSIT = 0.001 ether;
    uint256 public constant MAX_ITEM = 72;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Taken from the sale price when the winner pays.
    uint16 public feeBps = 250;

    uint256 public accumulatedFees;
    /// @notice Deposits and sale proceeds not yet withdrawn.
    uint256 public lockedTotal;

    Auction[] private _auctions;
    mapping(uint256 => mapping(address => bytes32)) private _commitment;
    mapping(uint256 => mapping(address => bool)) private _revealed;
    mapping(uint256 => mapping(address => bool)) private _depositSettled;
    mapping(uint256 => address[]) private _bidders;
    mapping(address => uint256) private _withdrawable;
    mapping(address => uint256[]) private _auctionsBySeller;

    event AuctionCreated(uint256 indexed id, address indexed seller, string item, uint256 reservePrice, uint256 deposit, uint64 commitEndsAt, uint64 revealEndsAt);
    event BidCommitted(uint256 indexed id, address indexed bidder);
    event BidRevealed(uint256 indexed id, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed id, address indexed winner, uint256 clearingPrice, uint32 revealed, uint32 noShows);
    event WinnerPaid(uint256 indexed id, address indexed winner, uint256 price, uint256 fee);
    event WinnerDefaulted(uint256 indexed id, address indexed winner, uint256 forfeited);
    event Withdrawn(address indexed who, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------ creating

    function createAuction(
        string calldata item,
        uint256 reservePrice,
        uint256 deposit,
        uint64 commitSecs,
        uint64 revealSecs
    ) external whenNotPaused returns (uint256 id) {
        require(bytes(item).length > 0 && bytes(item).length <= MAX_ITEM, "bad item");
        require(deposit >= MIN_DEPOSIT, "deposit too small");
        require(commitSecs >= MIN_WINDOW && commitSecs <= MAX_WINDOW, "bad commit window");
        require(revealSecs >= MIN_WINDOW && revealSecs <= MAX_WINDOW, "bad reveal window");

        uint64 commitEnds = uint64(block.timestamp) + commitSecs;
        uint64 revealEnds = commitEnds + revealSecs;

        id = _auctions.length;
        _auctions.push(
            Auction({
                seller: msg.sender,
                reservePrice: reservePrice,
                deposit: deposit,
                commitEndsAt: commitEnds,
                revealEndsAt: revealEnds,
                payEndsAt: 0,
                highBidder: address(0),
                highBid: 0,
                secondBid: 0,
                clearingPrice: 0,
                bidCount: 0,
                revealCount: 0,
                settled: false,
                paid: false,
                outcome: Outcome.Open,
                item: item
            })
        );
        _auctionsBySeller[msg.sender].push(id);
        emit AuctionCreated(id, msg.sender, item, reservePrice, deposit, commitEnds, revealEnds);
    }

    // ------------------------------------------------------------- bidding

    /**
     * @param commitment keccak256(abi.encodePacked(auctionId, amount, salt, msg.sender)).
     *        Binding it to the sender means an envelope seen in the mempool
     *        cannot be replayed by anyone else.
     */
    function commitBid(uint256 id, bytes32 commitment) external payable whenNotPaused {
        Auction storage a = _auction(id);
        require(block.timestamp < a.commitEndsAt, "commit closed");
        require(msg.sender != a.seller, "seller cannot bid");
        require(_commitment[id][msg.sender] == bytes32(0), "already committed");
        require(commitment != bytes32(0), "empty commitment");
        require(msg.value == a.deposit, "wrong deposit");

        _commitment[id][msg.sender] = commitment;
        _bidders[id].push(msg.sender);
        unchecked {
            a.bidCount += 1;
        }
        lockedTotal += msg.value;
        emit BidCommitted(id, msg.sender);
    }

    /// @dev Allowed while paused: a bidder must always be able to open their envelope.
    function revealBid(uint256 id, uint256 amount, bytes32 salt) external {
        Auction storage a = _auction(id);
        require(block.timestamp >= a.commitEndsAt, "reveal not open");
        require(block.timestamp < a.revealEndsAt, "reveal closed");
        require(_commitment[id][msg.sender] != bytes32(0), "no commitment");
        require(!_revealed[id][msg.sender], "already revealed");
        require(
            keccak256(abi.encodePacked(id, amount, salt, msg.sender)) == _commitment[id][msg.sender],
            "does not match"
        );

        _revealed[id][msg.sender] = true;
        unchecked {
            a.revealCount += 1;
        }

        if (amount > a.highBid) {
            a.secondBid = a.highBid;
            a.highBid = amount;
            a.highBidder = msg.sender;
        } else if (amount > a.secondBid) {
            a.secondBid = amount;
        }
        emit BidRevealed(id, msg.sender, amount);
    }

    // ---------------------------------------------------------- settlement

    /**
     * @notice Close an auction. Anyone may call it once the reveal window ends.
     * @dev Revealed bidders get their deposit back. Bidders who never revealed
     *      forfeit theirs to the seller.
     */
    function settleAuction(uint256 id) external nonReentrant {
        Auction storage a = _auction(id);
        require(block.timestamp >= a.revealEndsAt, "reveal still open");
        require(!a.settled, "already settled");

        a.settled = true;

        uint256 forfeited;
        address[] storage bidders = _bidders[id];
        for (uint256 i = 0; i < bidders.length; i++) {
            address b = bidders[i];
            if (_depositSettled[id][b]) continue;
            _depositSettled[id][b] = true;
            if (_revealed[id][b]) {
                // The winner's deposit is held until they pay.
                if (b == a.highBidder && a.highBid >= a.reservePrice) continue;
                _withdrawable[b] += a.deposit;
            } else {
                forfeited += a.deposit;
            }
        }
        if (forfeited > 0) _withdrawable[a.seller] += forfeited;

        uint32 noShows = a.bidCount - a.revealCount;

        if (a.highBidder == address(0) || a.highBid < a.reservePrice) {
            a.outcome = Outcome.Unsold;
            emit AuctionSettled(id, address(0), 0, a.revealCount, noShows);
            return;
        }

        // Second price, floored at the reserve.
        uint256 price = a.secondBid >= a.reservePrice ? a.secondBid : a.reservePrice;
        a.clearingPrice = price;
        a.payEndsAt = uint64(block.timestamp) + PAY_WINDOW;
        emit AuctionSettled(id, a.highBidder, price, a.revealCount, noShows);
    }

    /// @notice The winner completes the purchase. Their deposit counts toward the price.
    function payWinningBid(uint256 id) external payable nonReentrant {
        Auction storage a = _auction(id);
        require(a.settled, "not settled");
        require(a.outcome == Outcome.Open, "closed");
        require(msg.sender == a.highBidder, "not the winner");
        require(block.timestamp <= a.payEndsAt, "payment window closed");

        uint256 price = a.clearingPrice;
        uint256 owed = price > a.deposit ? price - a.deposit : 0;
        require(msg.value == owed, "wrong amount");

        a.paid = true;
        a.outcome = Outcome.Sold;

        uint256 fee = (price * feeBps) / 10_000;
        _withdrawable[a.seller] += price - fee;
        accumulatedFees += fee;

        // The deposit was already locked; only the top-up is new money.
        lockedTotal += msg.value;
        lockedTotal -= fee;

        // Anything the deposit overpaid comes back to the winner.
        if (a.deposit > price) _withdrawable[msg.sender] += a.deposit - price;

        emit WinnerPaid(id, msg.sender, price, fee);
    }

    /**
     * @notice After the payment window, a winner who never paid forfeits their
     *         deposit to the seller. Anyone may call this.
     */
    function claimDefault(uint256 id) external nonReentrant {
        Auction storage a = _auction(id);
        require(a.settled, "not settled");
        require(a.outcome == Outcome.Open, "closed");
        require(a.payEndsAt != 0 && block.timestamp > a.payEndsAt, "window still open");

        a.outcome = Outcome.Defaulted;
        _withdrawable[a.seller] += a.deposit;
        emit WinnerDefaulted(id, a.highBidder, a.deposit);
    }

    // ------------------------------------------------------------ payouts

    /// @dev Allowed while paused. Money owed to someone is never held hostage.
    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        require(amount > 0, "nothing to withdraw");
        _withdrawable[msg.sender] = 0;
        lockedTotal -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // --------------------------------------------------------------- views

    function auctionCount() external view returns (uint256) {
        return _auctions.length;
    }

    function getAuction(uint256 id) external view returns (Auction memory) {
        return _auction(id);
    }

    function balanceOf(address who) external view returns (uint256) {
        return _withdrawable[who];
    }

    function hasCommitted(uint256 id, address who) external view returns (bool) {
        return _commitment[id][who] != bytes32(0);
    }

    function hasRevealed(uint256 id, address who) external view returns (bool) {
        return _revealed[id][who];
    }

    function getBidders(uint256 id) external view returns (address[] memory) {
        return _bidders[id];
    }

    function getAuctionsBySeller(address seller) external view returns (uint256[] memory) {
        return _auctionsBySeller[seller];
    }

    /// @notice Phase as a number: 0 commit, 1 reveal, 2 awaiting settle, 3 closed.
    function phaseOf(uint256 id) external view returns (uint8) {
        Auction storage a = _auction(id);
        if (a.settled && a.outcome != Outcome.Open) return 3;
        if (a.settled) return 3;
        if (block.timestamp < a.commitEndsAt) return 0;
        if (block.timestamp < a.revealEndsAt) return 1;
        return 2;
    }

    /// @notice Newest-first page of auction ids.
    function getRecent(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _auctions.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    /// @notice Helper mirroring the envelope formula, for sealing a bid off-chain.
    function commitmentFor(uint256 id, uint256 amount, bytes32 salt, address bidder)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(id, amount, salt, bidder));
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`. Deposits and proceeds are unreachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _auction(uint256 id) private view returns (Auction storage) {
        require(id < _auctions.length, "no such auction");
        return _auctions[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}

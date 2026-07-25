// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  StreakVault — stake your discipline
 * @author Secure-Sentinel
 * @notice A commitment device on Arc Testnet (chain ID 5042002).
 *
 *         Lock USDC against a personal streak (e.g. 21 study days). Check in
 *         on-chain once per UTC day, every day. Finish the streak and you get
 *         your stake back plus a bonus paid from the bounty pool — a pool
 *         funded entirely by the penalties of broken and abandoned streaks.
 *         Miss a day or quit, and your chosen penalty share is slashed into
 *         that pool for future finishers.
 *
 *         The graveyard of broken streaks pays the disciplined.
 *
 *         Rules:
 *           - startStreak() counts as day 1's check-in.
 *           - A "day" is a UTC calendar day (block.timestamp / 1 days).
 *           - checkIn() must happen on the day right after your last one.
 *             Same day again  -> AlreadyCheckedInToday.
 *             Skipped a day   -> streak is broken; settleBroken() to slash
 *                                and reclaim the remainder.
 *           - quitStreak() exits voluntarily at the same penalty. Leaving
 *             always costs what you promised it would.
 *           - Completing pays stake + min(10% of pool, stake) as bonus.
 *
 * @dev    One active streak per address; past results survive in per-user
 *         counters. No owner, no admin keys, no upgradeability: funds move
 *         only along the defined paths. All value moves through the official
 *         USDC ERC-20 interface (0x3600000000000000000000000000000000000000
 *         on Arc Testnet, 6 decimals) — deliberately no payable functions,
 *         since Arc's native-gas USDC uses 18 decimals and mixing the two
 *         representations is a known footgun.
 */

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

contract StreakVault {
    // ------------------------------------------------------------------ types

    enum Status {
        None,      // never staked (struct default)
        Active,    // streak running
        Completed, // target hit, paid out
        Broken,    // missed a day, settled
        Quit       // left voluntarily, settled
    }

    struct Streak {
        uint96  stake;       // USDC, 6 decimals
        uint32  startDay;    // UTC day index of day 1
        uint32  lastDay;     // UTC day index of last check-in
        uint16  targetDays;
        uint16  daysDone;
        uint16  penaltyBps;  // slashed to the pool on break/quit
        Status  status;
    }

    // ----------------------------------------------------------------- errors

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge();
    error TargetOutOfRange();
    error PenaltyOutOfRange();
    error ActiveStreakExists();
    error NoActiveStreak();
    error AlreadyCheckedInToday();
    error StreakIsBroken();
    error StreakNotBroken();
    error TransferFailed();
    error Reentrancy();

    // ----------------------------------------------------------------- events

    event StreakStarted(
        address indexed user,
        uint256 stake,
        uint16  targetDays,
        uint16  penaltyBps,
        uint32  startDay
    );
    event CheckedIn(address indexed user, uint32 day, uint16 daysDone);
    event StreakCompleted(address indexed user, uint256 stakeReturned, uint256 bonus);
    event StreakEnded(
        address indexed user,
        bool    wasBroken,   // false = voluntary quit
        uint256 refund,
        uint256 penaltyToPool
    );

    // ---------------------------------------------------------------- storage

    uint16 public constant BONUS_BPS       = 1_000;  // finisher bonus: 10% of pool
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MIN_TARGET_DAYS = 2;
    uint16 public constant MAX_TARGET_DAYS = 365;

    /// @notice Settlement token. On Arc Testnet pass the official USDC
    ///         ERC-20 interface: 0x3600000000000000000000000000000000000000
    IERC20 public immutable token;

    /// @notice Bounty pool funded by slashed penalties, paid out as bonuses.
    uint256 public bountyPool;

    mapping(address => Streak) public streaks;

    // lifetime records per user
    mapping(address => uint16) public bestStreak;
    mapping(address => uint32) public completedCount;
    mapping(address => uint32) public failedCount; // broken + quit

    // global stats
    uint32 public totalCompleted;
    uint32 public totalFailed;
    uint256 public totalStakedEver;

    uint256 private _lock = 1;

    // -------------------------------------------------------------- modifiers

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------ constructor

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
    }

    // --------------------------------------------------------------- actions

    /**
     * @notice Start a streak. Pulls `stake` USDC (approve first) and counts
     *         as day 1's check-in — starting IS your first rep.
     * @param stake       Locked amount in USDC 6-decimal units (5 USDC = 5_000_000).
     * @param targetDays  Streak length, 2–365.
     * @param penaltyBps  Share slashed to the pool if you break or quit
     *                    (10000 = 100%). Choose teeth you respect.
     */
    function startStreak(
        uint256 stake,
        uint16  targetDays,
        uint16  penaltyBps
    ) external nonReentrant {
        Streak storage s = streaks[msg.sender];
        if (s.status == Status.Active) revert ActiveStreakExists();
        if (stake == 0) revert ZeroAmount();
        if (stake > type(uint96).max) revert AmountTooLarge();
        if (targetDays < MIN_TARGET_DAYS || targetDays > MAX_TARGET_DAYS) {
            revert TargetOutOfRange();
        }
        if (penaltyBps > BPS_DENOMINATOR) revert PenaltyOutOfRange();

        uint32 today = _today();
        streaks[msg.sender] = Streak({
            stake:      uint96(stake),
            startDay:   today,
            lastDay:    today,
            targetDays: targetDays,
            daysDone:   1,
            penaltyBps: penaltyBps,
            status:     Status.Active
        });
        totalStakedEver += stake;
        if (bestStreak[msg.sender] < 1) bestStreak[msg.sender] = 1;

        _pull(msg.sender, stake);

        emit StreakStarted(msg.sender, stake, targetDays, penaltyBps, today);
        emit CheckedIn(msg.sender, today, 1);
    }

    /**
     * @notice Daily check-in. Valid only on the UTC day right after your
     *         last check-in. Completing the target settles and pays
     *         immediately: stake + min(10% of pool, stake).
     */
    function checkIn() external nonReentrant {
        Streak storage s = streaks[msg.sender];
        if (s.status != Status.Active) revert NoActiveStreak();

        uint32 today = _today();
        if (today == s.lastDay) revert AlreadyCheckedInToday();
        if (today > s.lastDay + 1) revert StreakIsBroken();

        s.lastDay = today;
        s.daysDone += 1;
        if (bestStreak[msg.sender] < s.daysDone) bestStreak[msg.sender] = s.daysDone;

        emit CheckedIn(msg.sender, today, s.daysDone);

        if (s.daysDone >= s.targetDays) {
            s.status = Status.Completed;
            completedCount[msg.sender] += 1;
            totalCompleted += 1;

            uint256 bonus = (bountyPool * BONUS_BPS) / BPS_DENOMINATOR;
            if (bonus > s.stake) bonus = s.stake;
            bountyPool -= bonus;

            _pay(msg.sender, uint256(s.stake) + bonus);
            emit StreakCompleted(msg.sender, s.stake, bonus);
        }
    }

    /**
     * @notice Settle a streak you've already broken (missed at least one
     *         full UTC day). Penalty goes to the pool, remainder comes back.
     */
    function settleBroken() external nonReentrant {
        Streak storage s = streaks[msg.sender];
        if (s.status != Status.Active) revert NoActiveStreak();
        if (_today() <= s.lastDay + 1) revert StreakNotBroken();
        _slash(s, true);
    }

    /**
     * @notice Quit voluntarily. Same penalty as breaking — leaving always
     *         costs what you said it would.
     */
    function quitStreak() external nonReentrant {
        Streak storage s = streaks[msg.sender];
        if (s.status != Status.Active) revert NoActiveStreak();
        _slash(s, false);
    }

    // ------------------------------------------------------------------ views

    function getStreak(address user) external view returns (Streak memory) {
        return streaks[user];
    }

    /// @notice Current UTC day index (block.timestamp / 1 days).
    function todayIndex() external view returns (uint32) {
        return _today();
    }

    /// @notice Bonus a finisher would receive from the pool right now,
    ///         given their stake.
    function previewBonus(address user) external view returns (uint256 bonus) {
        bonus = (bountyPool * BONUS_BPS) / BPS_DENOMINATOR;
        uint256 stake = streaks[user].stake;
        if (bonus > stake) bonus = stake;
    }

    // -------------------------------------------------------------- internals

    function _today() private view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function _slash(Streak storage s, bool wasBroken) private {
        uint256 penalty = (uint256(s.stake) * s.penaltyBps) / BPS_DENOMINATOR;
        uint256 refund  = uint256(s.stake) - penalty;

        s.status = wasBroken ? Status.Broken : Status.Quit;
        failedCount[msg.sender] += 1;
        totalFailed += 1;
        bountyPool += penalty;

        if (refund > 0) _pay(msg.sender, refund);
        emit StreakEnded(msg.sender, wasBroken, refund, penalty);
    }

    function _pull(address from, uint256 value) private {
        if (!token.transferFrom(from, address(this), value)) revert TransferFailed();
    }

    function _pay(address to, uint256 value) private {
        if (!token.transfer(to, value)) revert TransferFailed();
    }
}

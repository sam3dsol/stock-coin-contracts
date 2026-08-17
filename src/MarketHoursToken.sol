// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Market Hours Token
/// @notice An ERC-20 that keeps stock-market hours. Transfers clear only
///         Monday-Friday, 9:30 AM - 4:00 PM America/New_York (the NYSE regular
///         session), DST-aware, computed on-chain from block.timestamp.
///         Outside the session every transfer reverts with the timestamp of the
///         next opening bell. No pause switch, no fee, no allowlist, no upgrade
///         path: nobody can freeze, block, tax or seize anything, ever.
///         There is NO admin, NO owner and NO escape hatch: not even the
///         deployer can switch the market hours off. The clock is the contract.
/// @dev    US DST rule hardcoded as legislated since 2007: EDT from the second
///         Sunday of March 02:00 to the first Sunday of November 02:00. If
///         Congress ever changes the rule, this token keeps the old one. The
///         clock is therefore only correct from 2007-03-11 onward; it answers
///         earlier instants with today's rule and can be an hour out on them.
/// @dev    MarketClosed does not survive a router. Uniswap's TransferHelper
///         wraps the token call and re-reverts with Error("TF") on a buy and
///         Error("STF") on a sell, so a swap attempted outside the session
///         surfaces a generic transfer failure rather than this token's own
///         error. Only a direct transfer/transferFrom returns
///         MarketClosed(opensAtUtc), selector 0x9dc30b8e. This is router
///         behaviour and applies to any token that restricts transfers; it
///         cannot be changed from here, because TransferHelper discards custom
///         errors by design. Interfaces should call isMarketOpen() before
///         offering a trade rather than interpreting a revert reason.
/// @dev    Integration notes: a zero-value transfer is gated like any other, so
///         accounting pokes fail outside the session; approve() works around the
///         clock but there is no EIP-2612 permit; transfers to address(0)
///         succeed while totalSupply is immutable, so burning that way leaves
///         totalSupply overstating the float.
contract MarketHoursToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Eastern-time day number of the last session that traded.
    uint256 public lastSessionDay;


    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @notice Rung by the first transfer that clears on each trading day.
    /// @dev    Any address can ring it with a zero-value transfer at its own
    ///         gas cost, so treat it as "the session opened", not as a trade.
    ///         It cannot be suppressed or repeated within a session.
    event OpeningBell(uint256 indexed easternDay);

    error MarketClosed(uint256 opensAtUtc);

    uint256 private constant OPEN = 9 hours + 30 minutes; // 09:30 ET
    uint256 private constant CLOSE = 16 hours; //            16:00 ET

    constructor(string memory name_, string memory symbol_, uint256 supply) {
        name = name_;
        symbol = symbol_;
        totalSupply = supply;
        balanceOf[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);
    }

    /// @notice Send tokens. Reverts MarketClosed(opensAtUtc) outside the session, a zero-value transfer included.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        {
            if (!isOpenAt(block.timestamp)) revert MarketClosed(nextOpenAfter(block.timestamp));
            uint256 day = (block.timestamp - _easternOffset(block.timestamp)) / 1 days;
            if (day != lastSessionDay) {
                lastSessionDay = day;
                emit OpeningBell(day);
            }
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    // ------------------------------------------------------------------
    // The clock. All pure; UIs and bots can call these for any timestamp.
    // ------------------------------------------------------------------

    function isMarketOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    /// @notice UTC timestamp of the next opening bell (now, if the market is open).
    function nextOpen() external view returns (uint256) {
        return nextOpenAfter(block.timestamp);
    }

    /// @notice UTC timestamp of the next closing bell.
    function nextClose() external view returns (uint256) {
        uint256 t = nextOpenAfter(block.timestamp);
        uint256 day = (t - _easternOffset(t)) / 1 days;
        return day * 1 days + CLOSE + _easternOffset(t);
    }

    /// @notice True during the regular session at the given UTC instant.
    /// @dev    Accurate from 2007-03-11 onward (see the DST note on the
    ///         contract). Reverts for ts < 18000: subtracting the Eastern
    ///         offset underflows, so do not call it with 0 as a sentinel.
    function isOpenAt(uint256 ts) public pure returns (bool) {
        uint256 eastern = ts - _easternOffset(ts);
        uint256 dow = (eastern / 1 days + 4) % 7; // 0 = Sunday
        if (dow == 0 || dow == 6) return false;
        uint256 s = eastern % 1 days;
        return s >= OPEN && s < CLOSE;
    }

    /// @notice The next opening bell at or after ts; ts itself when open.
    /// @dev    Always lands on an instant where isOpenAt is true and the second
    ///         before it is false. The trailing revert cannot be reached: any
    ///         weekday after `day` opens later than ts, and any 7 consecutive
    ///         days contain a weekday.
    function nextOpenAfter(uint256 ts) public pure returns (uint256) {
        if (isOpenAt(ts)) return ts;
        uint256 day = (ts - _easternOffset(ts)) / 1 days;
        for (uint256 i = 0; i < 8; i++) {
            uint256 d = day + i;
            uint256 dow = (d + 4) % 7;
            if (dow == 0 || dow == 6) continue;
            uint256 openEastern = d * 1 days + OPEN;
            // Offset probed 12h past the bell: the nearest DST switch (a Sunday
            // 06:00/07:00 UTC) is always further away, so this is exact.
            uint256 openUtc = openEastern + _easternOffset(openEastern + 12 hours);
            if (openUtc > ts) return openUtc;
        }
        revert(); // unreachable: any 8-day window holds a weekday bell
    }

    /// @dev Seconds behind UTC: 4h during EDT, 5h during EST.
    function _easternOffset(uint256 ts) internal pure returns (uint256) {
        uint256 y = _yearOf(ts);
        uint256 dstStart = _nthSundayUtc(y, 3, 2) + 7 hours; // 02:00 EST
        uint256 dstEnd = _nthSundayUtc(y, 11, 1) + 6 hours; //  02:00 EDT
        return (ts >= dstStart && ts < dstEnd) ? 4 hours : 5 hours;
    }

    /// @dev 00:00 UTC of the n-th Sunday of the given month.
    function _nthSundayUtc(uint256 y, uint256 m, uint256 n) private pure returns (uint256) {
        uint256 first = _daysFromCivil(y, m, 1);
        uint256 dow = (first + 4) % 7; // 0 = Sunday
        uint256 date = 1 + ((7 - dow) % 7) + 7 * (n - 1);
        return _daysFromCivil(y, m, date) * 1 days;
    }

    // Howard Hinnant's civil-date algorithms.
    function _daysFromCivil(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        unchecked {
            y -= m <= 2 ? 1 : 0;
            uint256 era = y / 400;
            uint256 yoe = y - era * 400;
            uint256 doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
            uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            return era * 146097 + doe - 719468;
        }
    }

    function _yearOf(uint256 ts) private pure returns (uint256) {
        unchecked {
            uint256 z = ts / 1 days + 719468;
            uint256 era = z / 146097;
            uint256 doe = z - era * 146097;
            uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
            uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            uint256 mp = (5 * doy + 2) / 153;
            return yoe + era * 400 + (mp >= 10 ? 1 : 0);
        }
    }
}

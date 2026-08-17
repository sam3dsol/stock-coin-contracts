// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Probe Hours Token
/// @notice A rehearsal of the $STOCK gate on the shortest useful timetable:
///         five minutes open, five minutes shut, forever, from the epoch. Six
///         complete open-close-open cycles per hour, so an entire trading day
///         of behaviour can be watched over a coffee.
/// @notice It exists to answer questions about the FLAGSHIP launch that only
///         a live pool can answer: how DexScreener charts a token that stops
///         trading, how wallets and aggregators classify a closed gate, what a
///         router does with a reverting swap, and whether our fee crank, prize
///         settlement and buyback loop behave across a close.
/// @dev    NOT THE LAUNCH CONTRACT AND NOT A DEMO FOR ANYONE ELSE. The gate,
///         the revert and the OpeningBell event are identical to
///         MarketHoursToken, and neither has an owner or an off switch;
///         only the schedule differs, and it
///         differs so violently that this contract can never be mistaken for
///         the real one by watching how it behaves. Name and symbol must stay
///         throwaway: the launch ticker never goes on a drill.
/// @dev    Shares the flagship's integration edges: MarketClosed does not
///         survive a DEX (Uniswap's TransferHelper re-reverts Error("TF") on a
///         buy, Error("STF") on a sell, so pre-flight isMarketOpen() instead of
///         parsing the revert); zero-value transfers are gated; approve() works
///         around the clock with no EIP-2612 permit; transfers to address(0)
///         succeed while totalSupply is immutable.
contract ProbeHoursToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Index of the last five-minute slot that traded.
    /// @dev    Slots are counted from the epoch and include the shut ones, so
    ///         this steps by 2 per session, not by 1. It is NOT the day number
    ///         MarketHoursToken puts in the same slot: a shared UI must branch.
    uint256 public lastSessionDay;


    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    /// @notice Rung by the first transfer of each five-minute session.
    event OpeningBell(uint256 indexed sessionDay);

    error MarketClosed(uint256 opensAtUtc);

    /// @dev One full cycle is two slots: slot even = open, slot odd = shut.
    uint256 private constant SLOT = 5 minutes;

    constructor(string memory name_, string memory symbol_, uint256 supply) {
        name = name_;
        symbol = symbol_;
        totalSupply = supply;
        balanceOf[msg.sender] = supply;
        emit Transfer(address(0), msg.sender, supply);
    }



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
            uint256 session = block.timestamp / SLOT;
            if (session != lastSessionDay) {
                lastSessionDay = session;
                emit OpeningBell(session);
            }
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    // ------------------------------------------------------------------
    // The clock. Same surface as MarketHoursToken so one UI reads both.
    // ------------------------------------------------------------------

    function isMarketOpen() external view returns (bool) {
        return isOpenAt(block.timestamp);
    }

    function nextOpen() external view returns (uint256) {
        return nextOpenAfter(block.timestamp);
    }

    function nextClose() external view returns (uint256) {
        return (nextOpenAfter(block.timestamp) / SLOT) * SLOT + SLOT;
    }

    function isOpenAt(uint256 ts) public pure returns (bool) {
        return (ts / SLOT) % 2 == 0;
    }

    function nextOpenAfter(uint256 ts) public pure returns (uint256) {
        if (isOpenAt(ts)) return ts;
        return ((ts / SLOT) + 1) * SLOT;
    }
}

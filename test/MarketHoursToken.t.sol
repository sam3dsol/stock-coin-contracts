// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketHoursToken} from "../src/MarketHoursToken.sol";

contract MarketHoursTokenTest is Test {
    MarketHoursToken t;
    address alice = address(0xA11CE);

    // Reference instants, derived from IANA tzdata (test/vectors.json generator).
    uint256 constant MON_OPEN_EDT = 1786975200; // 2026-08-17 10:00 ET, open
    uint256 constant MON_PRE_OPEN = 1786973399; // 2026-08-17 09:29:59 ET, closed
    uint256 constant MON_BELL = 1786973400; //     2026-08-17 09:30:00 ET, open
    uint256 constant SAT_NOON = 1786795200; //     2026-08-15 12:00 UTC, closed
    uint256 constant FRI_POST_CLOSE = 1786737601; // 2026-08-14 16:00:01 ET, closed
    uint256 constant JAN_OPEN_EST = 1768228200; // 2026-01-12 09:30 ET = 14:30 UTC (EST)
    uint256 constant MAR_OPEN_EDT = 1773063000; // 2026-03-09 09:30 ET = 13:30 UTC (day after DST start)
    uint256 constant NOV_OPEN_EST = 1793629800; // 2026-11-02 09:30 ET = 14:30 UTC (day after DST end)

    function setUp() public {
        t = new MarketHoursToken("Nine To Five", "9TO5", 1_000_000_000e18);
    }

    /// Every vector cross-checked against the real America/New_York tzdata.
    function test_differential_tzdata() public view {
        string memory json = vm.readFile("test/vectors.json");
        uint256[] memory ts = abi.decode(vm.parseJson(json, ".ts"), (uint256[]));
        bool[] memory open = abi.decode(vm.parseJson(json, ".open"), (bool[]));
        assertEq(ts.length, open.length);
        assertGt(ts.length, 400);
        uint256 opens;
        for (uint256 i = 0; i < ts.length; i++) {
            assertEq(t.isOpenAt(ts[i]), open[i], vm.toString(ts[i]));
            if (open[i]) opens++;
        }
        // the probe must be able to fail: both classes must be present
        assertGt(opens, 50);
        assertGt(ts.length - opens, 50);
    }

    function test_boundaries() public view {
        assertFalse(t.isOpenAt(MON_PRE_OPEN));
        assertTrue(t.isOpenAt(MON_BELL));
        assertTrue(t.isOpenAt(MON_OPEN_EDT));
        assertFalse(t.isOpenAt(SAT_NOON));
        assertFalse(t.isOpenAt(FRI_POST_CLOSE));
        assertTrue(t.isOpenAt(JAN_OPEN_EST)); // winter bell is 14:30 UTC...
        assertFalse(t.isOpenAt(JAN_OPEN_EST - 1));
        assertTrue(t.isOpenAt(MAR_OPEN_EDT)); // ...summer bell 13:30 UTC
        assertFalse(t.isOpenAt(MAR_OPEN_EDT - 1));
        assertTrue(t.isOpenAt(NOV_OPEN_EST));
        assertFalse(t.isOpenAt(NOV_OPEN_EST - 1));
    }

    function test_nextOpen() public view {
        assertEq(t.nextOpenAfter(SAT_NOON), MON_BELL);
        assertEq(t.nextOpenAfter(FRI_POST_CLOSE), MON_BELL);
        assertEq(t.nextOpenAfter(MON_PRE_OPEN), MON_BELL);
        assertEq(t.nextOpenAfter(MON_OPEN_EDT), MON_OPEN_EDT); // open now => now
    }

    /// For a year of random instants: nextOpenAfter lands on an open second
    /// whose previous second is closed (or is the queried open instant itself).
    function testFuzz_nextOpen_isABell(uint256 ts) public view {
        ts = bound(ts, MON_BELL, MON_BELL + 365 days);
        uint256 n = t.nextOpenAfter(ts);
        assertTrue(t.isOpenAt(n));
        assertGe(n, ts);
        if (n != ts) assertFalse(t.isOpenAt(n - 1));
    }

    function test_transfer_gated() public {
        vm.warp(SAT_NOON);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursToken.MarketClosed.selector, MON_BELL));
        t.transfer(alice, 1e18);

        vm.warp(MON_OPEN_EDT);
        t.transfer(alice, 1e18);
        assertEq(t.balanceOf(alice), 1e18);

        // 16:00:00 ET sharp is closed
        vm.warp(1786996800);
        vm.expectRevert();
        t.transfer(alice, 1e18);
    }

    function test_transferFrom_gated_approve_isnt() public {
        vm.warp(SAT_NOON);
        t.approve(alice, 5e18); // approvals work around the clock
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursToken.MarketClosed.selector, MON_BELL));
        t.transferFrom(address(this), alice, 5e18);

        vm.warp(MON_OPEN_EDT);
        vm.prank(alice);
        t.transferFrom(address(this), alice, 5e18);
        assertEq(t.balanceOf(alice), 5e18);
        assertEq(t.allowance(address(this), alice), 0);
    }

    function test_openingBell_oncePerSession() public {
        vm.warp(MON_BELL);
        uint256 day = (MON_BELL - 4 hours) / 1 days;
        vm.expectEmit(true, false, false, true);
        emit MarketHoursToken.OpeningBell(day);
        t.transfer(alice, 1e18);

        vm.recordLogs();
        t.transfer(alice, 1e18); // same session: no second bell
        assertEq(vm.getRecordedLogs().length, 1); // only the Transfer event

        vm.warp(MON_BELL + 1 days); // Tuesday: new bell
        vm.expectEmit(true, false, false, true);
        emit MarketHoursToken.OpeningBell(day + 1);
        t.transfer(alice, 1e18);
    }


    function test_deploy_mints_even_while_closed() public {
        vm.warp(SAT_NOON);
        MarketHoursToken w = new MarketHoursToken("Weekend", "WKND", 42e18);
        assertEq(w.balanceOf(address(this)), 42e18);
        assertEq(w.totalSupply(), 42e18);
    }

    function test_views() public {
        vm.warp(SAT_NOON);
        assertFalse(t.isMarketOpen());
        assertEq(t.nextOpen(), MON_BELL);
        assertEq(t.nextClose(), 1786996800); // Mon 2026-08-17 16:00 ET
        vm.warp(MON_OPEN_EDT);
        assertTrue(t.isMarketOpen());
        assertEq(t.nextClose(), 1786996800);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProbeHoursToken} from "../src/ProbeHoursToken.sol";

/// The rehearsal token has to behave exactly like the flagship at the edges,
/// because the whole point of running it is to trust what we learn from it.
contract ProbeHoursTokenTest is Test {
    ProbeHoursToken t;
    address alice = makeAddr("alice");

    uint256 constant SLOT = 5 minutes;

    function setUp() public {
        vm.warp(1786973400); // an even slot: open
        t = new ProbeHoursToken("Probe", "PROBE", 1_000_000e18);
    }

    function test_alternates_every_five_minutes() public view {
        uint256 base = (block.timestamp / SLOT) * SLOT;
        assertTrue(t.isOpenAt(base), "slot start open");
        assertTrue(t.isOpenAt(base + SLOT - 1), "still open one second before the bell");
        assertFalse(t.isOpenAt(base + SLOT), "shut on the next slot");
        assertFalse(t.isOpenAt(base + 2 * SLOT - 1), "shut through the whole slot");
        assertTrue(t.isOpenAt(base + 2 * SLOT), "open again after ten minutes");
    }

    function test_transfer_gated_by_the_slot() public {
        uint256 base = (block.timestamp / SLOT) * SLOT;

        vm.warp(base + 10);
        t.transfer(alice, 1e18);
        assertEq(t.balanceOf(alice), 1e18, "clears while open");

        vm.warp(base + SLOT + 10); // shut
        vm.expectRevert(abi.encodeWithSelector(ProbeHoursToken.MarketClosed.selector, base + 2 * SLOT));
        t.transfer(alice, 1e18);

        vm.warp(base + 2 * SLOT); // reopened
        t.transfer(alice, 1e18);
        assertEq(t.balanceOf(alice), 2e18, "clears again after the reopen");
    }

    /// Approvals never sleep, exactly like the flagship: only the move is gated.
    function test_approve_works_while_shut() public {
        vm.warp(((block.timestamp / SLOT) * SLOT) + SLOT + 1);
        t.approve(alice, 5e18);
        assertEq(t.allowance(address(this), alice), 5e18);
    }

    function test_nextOpen_and_nextClose() public {
        uint256 base = (block.timestamp / SLOT) * SLOT;

        vm.warp(base + SLOT + 30); // shut
        assertEq(t.nextOpen(), base + 2 * SLOT, "opens at the next even slot");

        vm.warp(base + 30); // open
        assertEq(t.nextOpen(), base + 30, "already open");
        assertEq(t.nextClose(), base + SLOT, "closes at the end of this slot");
    }


    /// Never open and shut at the same instant, at any point on the timeline.
    function testFuzz_open_and_shut_are_exclusive(uint32 ts) public view {
        bool open = t.isOpenAt(ts);
        uint256 next = t.nextOpenAfter(ts);
        if (open) {
            assertEq(next, ts, "an open instant opens now");
        } else {
            assertTrue(next > ts, "a shut instant opens later");
            assertTrue(t.isOpenAt(next), "and what it points at is open");
            assertLe(next - ts, SLOT, "never more than one slot away");
        }
    }
}

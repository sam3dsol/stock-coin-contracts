// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeSplitter} from "../src/FeeSplitter.sol";

/* --------------------------------------------------------------- mocks */

contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) public returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

contract MockWeth is MockERC20 {
    constructor() MockERC20("WETH") {}

    function withdraw(uint256 v) external {
        balanceOf[msg.sender] -= v;
        (bool ok,) = msg.sender.call{value: v}("");
        require(ok, "eth send");
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// Pays out whatever fees were staged, exactly like collect() does.
contract MockNpm {
    MockERC20 public token0;
    MockERC20 public token1;
    uint256 public owed0;
    uint256 public owed1;

    constructor(MockERC20 t0, MockERC20 t1) {
        token0 = t0;
        token1 = t1;
    }

    function stage(uint256 a0, uint256 a1) external {
        owed0 = a0;
        owed1 = a1;
        token0.mint(address(this), a0);
        token1.mint(address(this), a1);
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    address public owner_ = address(0);
    address public pt0;
    address public pt1;
    uint24 public pfee = 10000;
    uint128 public plq = 1e18;

    function setLiquidity(uint128 v) external {
        plq = v;
    }

    function setPosition(address holder, address t0, address t1, uint24 fee) external {
        owner_ = holder;
        pt0 = t0;
        pt1 = t1;
        pfee = fee;
    }

    function ownerOf(uint256) external view returns (address) {
        return owner_;
    }

    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), pt0, pt1, pfee, 0, 0, plq, 0, 0, 0, 0);
    }

    function collect(CollectParams calldata p) external returns (uint256 a0, uint256 a1) {
        a0 = owed0;
        a1 = owed1;
        owed0 = 0;
        owed1 = 0;
        if (a0 > 0) token0.transfer(p.recipient, a0);
        if (a1 > 0) token1.transfer(p.recipient, a1);
    }
}

/// Sells the token side for WETH at a fixed rate, honouring amountOutMinimum.
contract MockRouter {
    MockERC20 public token;
    MockWeth public weth;
    uint256 public rateNum = 1;
    uint256 public rateDen = 10; // 10 tokens -> 1 WETH

    constructor(MockERC20 t, MockWeth w) {
        token = t;
        weth = w;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256 out) {
        out = (p.amountIn * rateNum) / rateDen;
        require(out >= p.amountOutMinimum, "slippage");
        token.transferFrom(msg.sender, address(this), p.amountIn);
        weth.mint(p.recipient, out);
    }
}

/// A recipient that can be made to reject ETH, like a contract wallet whose
/// receive() reverts. This is the shape that stranded fees on RWA404.
contract PickyRecipient {
    bool public accepting;

    function setAccepting(bool v) external {
        accepting = v;
    }

    receive() external payable {
        require(accepting, "not accepting");
    }
}

/* ---------------------------------------------------------------- test */

contract FeeSplitterTest is Test {
    FeeSplitter splitter;
    MockERC20 token;
    MockWeth weth;
    MockNpm npm;
    MockRouter router;

    address keeper = makeAddr("keeper");
    address pot = makeAddr("pot");
    address partner = makeAddr("partner");
    address dev = makeAddr("dev");
    address stranger = makeAddr("stranger");

    function setUp() public {
        token = new MockERC20("STOCK");
        weth = new MockWeth();
        npm = new MockNpm(MockERC20(address(weth)), token); // token0 = WETH
        router = new MockRouter(token, weth);
        vm.deal(address(weth), 100 ether); // the mock unwraps from its own balance

        splitter = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, pot, partner, dev
        );
        /* the launch mints straight into the splitter, then we record the id */
        npm.setPosition(address(splitter), address(weth), address(token), 10000);
        vm.prank(keeper);
        splitter.lock(1);
    }

    /// The position is locked the moment it is minted here, before anyone
    /// records its id: this contract has no way to send an NFT out.
    function test_lock_records_the_position_and_only_once() public {
        assertEq(splitter.positionId(), 1, "recorded");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.AlreadyLocked.selector, uint256(1)));
        splitter.lock(2);
    }

    /// lock() must NOT share the crank's ACL: it is one-shot and irreversible,
    /// so a recipient could mint a dust position in our own pool, send it in and
    /// lock it first, stranding the real LP's fees forever.
    function test_only_the_keeper_may_lock() public {
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, pot, partner, dev
        );
        npm.setPosition(address(s2), address(weth), address(token), 10000);
        for (uint256 i = 0; i < 3; i++) {
            address who = [pot, partner, dev][i];
            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotAuthorised.selector, who));
            s2.lock(5);
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotAuthorised.selector, stranger));
        s2.lock(5);
        vm.prank(keeper);
        s2.lock(5);
        assertEq(s2.positionId(), 5, "only the keeper got there");
    }

    /// The dead-man switch must never hand out lock(), only crank().
    function test_dead_man_never_opens_lock() public {
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, pot, partner, dev
        );
        npm.setPosition(address(s2), address(weth), address(token), 10000);
        vm.warp(block.timestamp + 3650 days);
        assertTrue(s2.crankableBy(stranger), "crank is open after a decade");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotAuthorised.selector, stranger));
        s2.lock(5);
    }

    /// An empty position of the right pool is the mistake a human types.
    function test_lock_refuses_an_empty_position() public {
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, pot, partner, dev
        );
        npm.setPosition(address(s2), address(weth), address(token), 10000);
        npm.setLiquidity(0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.PositionEmpty.selector, uint256(5)));
        s2.lock(5);
    }

    /// The switch must measure "the keeper is gone", not "trade was quiet".
    function test_poke_keeps_the_switch_shut_through_a_drought() public {
        vm.warp(block.timestamp + 29 days);
        vm.prank(keeper);
        splitter.poke();
        vm.warp(block.timestamp + 29 days);
        assertFalse(splitter.crankableBy(stranger), "a poked keeper is a live keeper");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotAuthorised.selector, stranger));
        splitter.poke();
    }

    /// A hostile or stray NFT must not be able to take the slot and strand the
    /// real position forever.
    function test_lock_refuses_a_position_that_is_not_ours() public {
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, pot, partner, dev
        );

        // right owner, wrong pair
        address other = makeAddr("otherToken");
        // (keeper-only now, so every prank below is the keeper)
        npm.setPosition(address(s2), address(weth), other, 10000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotOurPool.selector, address(weth), other, uint24(10000)));
        s2.lock(7);

        // right pair, wrong fee tier
        npm.setPosition(address(s2), address(weth), address(token), 3000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotOurPool.selector, address(weth), address(token), uint24(3000)));
        s2.lock(7);

        // our pair, but the splitter does not hold it
        npm.setPosition(stranger, address(weth), address(token), 10000);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotOwned.selector, uint256(7)));
        s2.lock(7);
    }

    /// Cranking before the position is recorded must fail loudly, not collect
    /// from position zero.
    function test_crank_refuses_before_the_position_is_recorded() public {
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, pot, partner, dev
        );
        vm.prank(keeper);
        vm.expectRevert(FeeSplitter.NotLocked.selector);
        s2.crank(0);
    }

    /// The keeper cranks, and the money always goes 60/20/20.
    function test_keeper_cranks_and_splits_60_20_20() public {
        npm.stage(1 ether, 10 ether); // 1 WETH + 10 STOCK (worth 1 WETH)

        vm.prank(keeper);
        (uint256 split,) = splitter.crank(0);

        assertEq(split, 2 ether, "2 ETH total");
        assertEq(pot.balance, 1.2 ether, "pot 60%");
        assertEq(partner.balance, 0.4 ether, "partner 20%");
        assertEq(dev.balance, 0.4 ether, "dev 20%");
        assertEq(keeper.balance, 0, "caller keeps nothing");
    }

    /// The fix for the sandwich: a stranger cannot choose our slippage floor.
    function test_stranger_cannot_crank() public {
        npm.stage(1 ether, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotAuthorised.selector, stranger));
        splitter.crank(0);
    }

    /// Losing one key must not stop the pot: every recipient can crank too.
    function test_each_recipient_can_crank() public {
        address[3] memory who = [pot, partner, dev];
        for (uint256 i = 0; i < who.length; i++) {
            npm.stage(1 ether, 0);
            vm.prank(who[i]);
            splitter.crank(0);
        }
        assertGt(pot.balance, 0, "pot was paid across the three cranks");
    }

    /// The dead-man switch: the LP is locked in here forever, so if every key
    /// we own dies the fees must not die with it.
    function test_dead_man_switch_reopens_the_crank() public {
        npm.stage(2 ether, 0);

        // closed on day one, and still closed the second before it opens
        assertFalse(splitter.crankableBy(stranger), "shut at construction");
        vm.warp(block.timestamp + splitter.CRANK_OPENS_AFTER());
        assertFalse(splitter.crankableBy(stranger), "still shut at exactly 30 days");

        vm.warp(block.timestamp + 1);
        assertTrue(splitter.crankableBy(stranger), "open once 30 days have passed");
        vm.prank(stranger);
        splitter.crank(0);
        assertEq(pot.balance, 1.2 ether, "the pot still gets its 60%");

        // and a successful crank slams it shut again
        assertFalse(splitter.crankableBy(stranger), "reset by the crank");
    }

    /// minEthOut governs the SALE only; the WETH side was never swapped. This
    /// is the bug that made every honest crank revert.
    function test_return_separates_sale_proceeds_from_the_whole_split() public {
        npm.stage(9 ether, 10 ether); // 9 WETH of fees + 10 STOCK worth 1 ETH

        vm.prank(keeper);
        (uint256 split, uint256 fromSale) = splitter.crank(0);

        assertEq(split, 10 ether, "the whole take");
        assertEq(fromSale, 1 ether, "only the swapped part");
        /* Sizing the floor off `split` is what used to revert: 97% of 10 ETH
           can never come out of a sale that only ever yields 1 ETH. */
        assertGt((split * 97) / 100, fromSale, "the old ops formula was unsatisfiable");
    }

    /// A wrong position id must be refused, not swallowed forever.
    function test_rejects_the_wrong_position_and_any_other_sender() public {
        /* Unrelated NFTs cannot be parked here at all. Which Uniswap position
           actually counts is decided by lock(), not by this hook. */
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeSplitter.NotAuthorised.selector, stranger));
        splitter.onERC721Received(address(0), address(0), 1, "");

        vm.prank(address(npm));
        assertEq(
            splitter.onERC721Received(address(0), address(0), 999, ""),
            bytes4(0x150b7a02),
            "a Uniswap position is accepted into custody"
        );
    }

    /// Fees only. The contract has no code path that can move liquidity.
    function test_no_function_can_move_the_position() public {
        bytes4[3] memory forbidden = [
            bytes4(keccak256("recoverPosition(address)")),
            bytes4(keccak256("decreaseLiquidity(uint256)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(splitter).call(abi.encodeWithSelector(forbidden[i], address(this)));
            assertFalse(ok, "no escape hatch may exist");
        }
    }

    function test_slippage_guard_reverts() public {
        npm.stage(0, 10 ether);
        vm.expectRevert(bytes("slippage"));
        vm.prank(keeper);
        splitter.crank(5 ether); // asks for more than the 1 ETH the sale yields
    }

    function test_reverts_when_nothing_is_owed() public {
        vm.expectRevert(FeeSplitter.NothingToSplit.selector);
        vm.prank(keeper);
        splitter.crank(0);
    }

    /// A pure WETH cycle still splits, with no token sale involved.
    function test_weth_only_cycle() public {
        npm.stage(3 ether, 0);
        vm.prank(keeper);
        splitter.crank(0);
        assertEq(pot.balance, 1.8 ether);
        assertEq(partner.balance, 0.6 ether);
        assertEq(dev.balance, 0.6 ether);
    }

    /// The RWA404 lesson: one recipient that cannot receive ETH must never
    /// block the crank, and must never lose its share.
    function test_failed_payment_never_blocks_the_crank() public {
        PickyRecipient picky = new PickyRecipient(); // refuses ETH for now
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, address(picky), partner, dev
        );

        npm.setPosition(address(s2), address(weth), address(token), 10000);
        vm.prank(keeper);
        s2.lock(1);
        npm.stage(2 ether, 0);
        vm.prank(keeper);
        s2.crank(0);

        assertEq(address(picky).balance, 0, "picky could not receive");
        assertEq(s2.owed(address(picky)), 1.2 ether, "its 60% is booked, not lost");
        assertEq(partner.balance, 0.4 ether, "the others were still paid");
        assertEq(dev.balance, 0.4 ether);

        /* it can collect later, and ANYONE can push it */
        picky.setAccepting(true);
        vm.prank(stranger);
        s2.withdraw(address(picky));
        assertEq(address(picky).balance, 1.2 ether, "paid in full afterwards");
        assertEq(s2.owed(address(picky)), 0);
        assertEq(s2.deferredTotal(), 0);
    }

    /// Money already booked to a recipient is never re-split by a later crank.
    function test_deferred_balance_is_not_resplit() public {
        PickyRecipient picky = new PickyRecipient();
        FeeSplitter s2 = new FeeSplitter(
            address(npm), address(router), address(weth), address(token), 10000, keeper, address(picky), partner, dev
        );

        npm.setPosition(address(s2), address(weth), address(token), 10000);
        vm.prank(keeper);
        s2.lock(1);
        npm.stage(2 ether, 0);
        vm.prank(keeper);
        s2.crank(0); // 1.2 deferred to picky
        npm.stage(1 ether, 0);
        vm.prank(keeper);
        s2.crank(0); // must split exactly 1 ETH, not 2.2

        assertEq(s2.owed(address(picky)), 1.8 ether, "1.2 + 0.6");
        assertEq(partner.balance, 0.6 ether, "0.4 + 0.2");
        assertEq(dev.balance, 0.6 ether);
    }

    /// Dust must not strand: the three shares always sum to the whole.
    function testFuzz_shares_sum_to_total(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(weth), amount); // the mock unwraps from its own balance
        npm.stage(amount, 0);
        vm.prank(keeper);
        (uint256 split,) = splitter.crank(0);
        assertEq(pot.balance + partner.balance + dev.balance, split, "no wei left behind");
        assertEq(address(splitter).balance, 0, "contract holds nothing");
    }
}

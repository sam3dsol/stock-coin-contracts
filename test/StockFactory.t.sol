// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFactoryBase} from "../src/LaunchFactoryBase.sol";
import {StockFactory} from "../src/StockFactory.sol";
import {ProbeFactory} from "../src/ProbeFactory.sol";
import {TickMath} from "../src/TickMath.sol";
import {MarketHoursToken} from "../src/MarketHoursToken.sol";
import {ProbeHoursToken} from "../src/ProbeHoursToken.sol";

/* ------------------------------------------------------------ mocks */

contract MockWeth {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 v) external {
        balanceOf[msg.sender] -= v;
        (bool ok,) = msg.sender.call{value: v}("");
        require(ok, "eth");
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
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

interface IERC20Like {
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract MockNpm {
    address public pool;
    uint160 public initialisedAt;
    uint256 public nextId = 42;
    address public lastRecipient;
    uint256 public tookToken;
    uint256 public tookWeth;
    int24 public lastTickLower;
    int24 public lastTickUpper;
    int24 public reportedTick = -204200;
    bool public tickForced;
    address public wethAddr;

    function setWeth(address w) external {
        wethAddr = w;
    }

    function setReportedTick(int24 t) external {
        reportedTick = t;
        tickForced = true;
    }

    bool public preInitialised;

    /// Somebody got here first: the real call is a NO-OP once a pool exists,
    /// and Uniswap will create one for an address that has no code yet.
    function preInitialise(uint160 sqrtPriceX96, int24 tick) external {
        initialisedAt = sqrtPriceX96;
        reportedTick = tick;
        tickForced = true;
        preInitialised = true;
        pool = address(this);
    }

    function createAndInitializePoolIfNecessary(address token0, address, uint24, uint160 sqrtPriceX96)
        external
        payable
        returns (address)
    {
        if (preInitialised) return pool; // no-op, exactly like the real one
        initialisedAt = sqrtPriceX96;
        pool = address(this); // the mock answers slot0 for its own pool
        /* a real pool ends up at the tick the price implies, which flips sign
           with token ordering; mimic that unless a test forces a value */
        if (!tickForced) reportedTick = token0 == wethAddr ? int24(204200) : int24(-204200);
        return pool;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata p) external payable returns (uint256, uint128, uint256, uint256) {
        /* pull whichever side was offered, like the real position manager */
        if (p.amount0Desired > 0) IERC20Like(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired);
        if (p.amount1Desired > 0) IERC20Like(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired);
        lastRecipient = p.recipient;
        lastTickLower = p.tickLower;
        lastTickUpper = p.tickUpper;
        (tookToken, tookWeth) = p.token0 == wethAddr
            ? (p.amount1Desired, p.amount0Desired)
            : (p.amount0Desired, p.amount1Desired);
        return (nextId, 1e18, p.amount0Desired, p.amount1Desired);
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function positions(uint256)
        external
        pure
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0, 0);
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (initialisedAt, reportedTick, 0, 0, 0, 0, true);
    }
}

contract MockRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    address public lastRecipient;
    uint256 public lastAmountIn;

    /// Reports a flat 1000 tokens per ETH. It does not move real tokens: a
    /// live router pays out of the pool, which no mock here holds. What this
    /// asserts is that the factory calls it, in the right order, with the
    /// right recipient and the right ETH.
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        lastRecipient = p.recipient;
        lastAmountIn = p.amountIn;
        out = p.amountIn * 1000;
    }

    receive() external payable {}
}

/* ------------------------------------------------------------- test */

contract StockFactoryTest is Test {
    StockFactory f;
    ProbeFactory pf;
    MockWeth weth;
    MockNpm npm;
    MockRouter router;
    address locker = makeAddr("feeSplitter");

    uint256 constant SUPPLY = 1_000_000_000;

    function setUp() public {
        vm.warp(1786973400); // a Monday inside the session, and an even 5-min slot
        weth = new MockWeth();
        npm = new MockNpm();
        npm.setWeth(address(weth));
        router = new MockRouter();
        f = new StockFactory(address(npm), address(router), address(weth), 10000, 200);
        pf = new ProbeFactory(address(npm), address(router), address(weth), 10000, 200);
        vm.deal(address(this), 100 ether);
    }

    /// PONS v1's own numbers: 1e9 supply, opening tick -204200, 4.2 ETH to graduate.
    function params(bool flagship, bytes32 salt) internal view returns (LaunchFactoryBase.LaunchParams memory p) {
        p = LaunchFactoryBase.LaunchParams({
            salt: salt,
            name: flagship ? "Stock Coin" : "Probe Hours",
            symbol: flagship ? "STOCK" : "PROBE",
            supply: SUPPLY,
            initialTick: -204200,
            ethForDevBuy: 1 ether,
            graduationThreshold: 4.2 ether,
            lpRecipient: locker
        });
    }

    /// A stranger who learns the address early can create and price its pool
    /// before we launch, because Uniswap will make a pool for an address with
    /// no code. createAndInitializePoolIfNecessary then does NOTHING, and the
    /// launch would build on their price -- or, priced above our tick, fail
    /// with an opaque revert and burn the salt for good.
    function test_refuses_a_pool_somebody_else_priced() public {
        bytes32 salt = keccak256("stock-frontrun");
        address predicted = f.predict(salt, "Stock Coin", "STOCK", SUPPLY);
        bool t0 = predicted < address(weth);

        int24 ourTick = t0 ? int24(-204200) : int24(204200);
        int24 theirTick = ourTick + 200;
        npm.preInitialise(TickMath.getSqrtRatioAtTick(theirTick), theirTick);

        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchFactoryBase.PoolAlreadyPriced.selector,
                TickMath.getSqrtRatioAtTick(theirTick),
                TickMath.getSqrtRatioAtTick(ourTick)
            )
        );
        f.launch{value: 1 ether}(params(true, salt));
    }

    /// ...but a pool already sitting at OUR price is harmless, and must not
    /// cost us the launch: that is the benign half of the same situation.
    function test_accepts_a_pool_already_at_our_own_price() public {
        bytes32 salt = keccak256("stock-benign");
        address predicted = f.predict(salt, "Stock Coin", "STOCK", SUPPLY);
        int24 ourTick = predicted < address(weth) ? int24(-204200) : int24(204200);
        npm.preInitialise(TickMath.getSqrtRatioAtTick(ourTick), ourTick);

        (address token,,) = f.launch{value: 1 ether}(params(true, salt));
        assertEq(token, predicted, "the launch still lands on its address");
    }

    /// A tick off the 200 spacing dies deep inside the pool with an opaque
    /// revert, after the token has already been deployed to its salt.
    function test_rejects_a_misaligned_tick() public {
        LaunchFactoryBase.LaunchParams memory p = params(true, keccak256("stock-tick"));
        p.initialTick = -204201;
        vm.expectRevert(abi.encodeWithSelector(LaunchFactoryBase.TickNotAligned.selector, int24(-204201), int24(200)));
        f.launch{value: 1 ether}(p);
    }

    /// The dev buy may only spend what this call carries, never ETH a stranger
    /// left sitting in the factory.
    function test_dev_buy_cannot_exceed_the_value_sent() public {
        (bool sent,) = address(f).call{value: 5 ether}(""); // a stranger's donation
        assertTrue(sent, "factory takes ETH");

        LaunchFactoryBase.LaunchParams memory p = params(true, keccak256("stock-value"));
        p.ethForDevBuy = 3 ether;
        vm.expectRevert(abi.encodeWithSelector(LaunchFactoryBase.DevBuyExceedsValue.selector, 3 ether, 1 ether));
        f.launch{value: 1 ether}(p);
    }

    /// The address is known before a wei is spent, and the launch honours it.
    function test_predicted_address_is_the_deployed_one() public {
        bytes32 salt = keccak256("stock-1");
        address predicted = f.predict(salt, "Stock Coin", "STOCK", SUPPLY);
        (address token,,) = f.launch{value: 1 ether}(params(true, salt));
        assertEq(token, predicted, "salt must decide the address");
        assertEq(MarketHoursToken(token).symbol(), "STOCK");
    }

    /// One transaction: pool priced, liquidity seeded, dev buy filled.
    function test_launch_pools_and_dev_buys_atomically() public {
        (address token, uint256 lpId, uint256 bought) = f.launch{value: 1 ether}(params(true, keccak256("s2")));

        bool t0 = token < address(weth);
        assertEq(npm.initialisedAt(), TickMath.getSqrtRatioAtTick(t0 ? int24(-204200) : int24(204200)), "pool priced from the tick");
        assertEq(lpId, 42, "position minted");
        assertEq(npm.lastRecipient(), locker, "LP goes straight to the locker");
        assertEq(npm.tookToken(), SUPPLY * 1e18, "the whole supply went in as liquidity");
        assertEq(npm.tookWeth(), 0, "single-sided: none of our ETH is in the pool");
        assertEq(router.lastAmountIn(), 1 ether, "dev buy used its ETH");
        assertEq(bought, 1000 ether, "dev buy filled");
        assertEq(router.lastRecipient(), address(this), "the dev bag goes to the launcher");
        assertEq(MarketHoursToken(token).balanceOf(address(f)), 0, "factory keeps no tokens");
        assertEq(f.positionOf(token), 42, "position recorded for graduation");
        assertEq(f.graduationThresholdOf(token), 4.2 ether, "PONS v1 threshold");
    }

    /// The drill runs the same shared code path, from its own factory.
    function test_probe_launch_uses_the_same_path() public {
        (address token,, uint256 bought) = pf.launch{value: 1 ether}(params(false, keccak256("s3")));
        assertEq(ProbeHoursToken(token).symbol(), "PROBE");
        assertEq(ProbeHoursToken(token).totalSupply(), SUPPLY * 1e18, "same supply as the flagship");
        assertGt(bought, 0, "dev buy works on the drill too");
    }

    /// Seeding moves tokens, so a shut market must stop the launch early and
    /// clearly rather than reverting somewhere inside the router.
    function test_reverts_while_the_market_is_shut() public {
        vm.warp(1787011200); // a Saturday
        vm.expectRevert();
        f.launch{value: 1 ether}(params(true, keccak256("s4")));
    }

    /// Nobody but the deployer of the factory can fire the launch.
    function test_only_the_launcher_may_launch() public {
        address sniper = makeAddr("sniper");
        vm.deal(sniper, 10 ether);
        vm.prank(sniper);
        vm.expectRevert(LaunchFactoryBase.NotLauncher.selector);
        f.launch{value: 1 ether}(params(true, keccak256("s5")));
    }

    /// The opening price is derived on chain from the tick, so the pool is
    /// initialised at exactly the price the tick names, in either ordering.
    function test_price_comes_from_the_tick() public {
        (address token,,) = f.launch{value: 1 ether}(params(true, keccak256("p1")));
        bool isToken0 = token < address(weth);
        uint160 expected = TickMath.getSqrtRatioAtTick(isToken0 ? int24(-204200) : int24(204200));
        assertEq(npm.initialisedAt(), expected, "pool priced from the tick, exactly");
    }

    /// Each factory can deploy exactly one kind of token. Nothing can mix them.
    function test_factories_cannot_deploy_each_others_token() public {
        (address probe,,) = pf.launch{value: 1 ether}(params(false, keccak256("iso1")));
        (address stock,,) = f.launch{value: 1 ether}(params(true, keccak256("iso2")));

        /* the drill token alternates every five minutes; the flagship keeps
           NYSE hours. Warp to a Saturday: only the drill can still be open. */
        vm.warp(1787011200); // Saturday, in an even five-minute slot
        assertTrue(ProbeHoursToken(probe).isMarketOpen(), "the drill keeps its own clock");
        assertFalse(MarketHoursToken(stock).isMarketOpen(), "the flagship keeps NYSE hours");
    }

    receive() external payable {}
}

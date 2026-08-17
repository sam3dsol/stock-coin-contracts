// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "./TickMath.sol";
import {FullMath} from "./FullMath.sol";

/// @title  Launch Factory Base
/// @notice Launches $STOCK in ONE transaction: deploys the token at a chosen
///         address, pairs it against WETH in a Uniswap v3 pool, seeds the
///         liquidity and performs the dev buy before anyone else can trade.
///         Nothing sits between pool creation and the first buy, so there is
///         no window for a sniper to take the open.
/// @notice The launch logic lives here once, and two thin factories inherit
///         it: one that can only ever deploy the rehearsal token and one that
///         can only ever deploy the flagship. They share this code so the
///         drill exercises exactly what the real launch will do, and they are
///         separate contracts so a drill can never touch the real launch.
/// @notice Liquidity is seeded the way PONS v1 seeds it: ONE single-sided
///         position holding the entire supply, priced from an opening tick
///         upward, with no ETH of ours in the pool. Buyers' ETH accumulates
///         inside that position, which is also what "graduation" measures.
///         The dev buy in the same transaction is what puts the first ETH in,
///         so the pool is never priceless and indexers can render it.
/// @dev    ⛔ The token gates its own transfers, so seeding liquidity and the
///         dev buy only succeed while the market is OPEN. The factory checks
///         that first and reverts with MarketIsShut rather than burning the
///         launch on a revert deep inside the router.
/// @dev    The opening price is derived ON CHAIN from the tick, the way PONS
///         v1 does it, so a caller cannot supply a price that disagrees with
///         the tick it names. There is nothing to verify because there is
///         nothing to get wrong.
/// @dev    The token address is CREATE2(this, salt, initCode), so the salt can
///         be ground in advance. It changes if the name, symbol or supply
///         change by a single character.
abstract contract LaunchFactoryBase {
    /// @notice Uniswap v3 position manager, router and WETH, fixed at deploy.
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter public immutable router;
    IWETH9 public immutable weth;
    /// @notice The pool fee tier, in hundredths of a bip. 10000 = 1%.
    uint24 public immutable poolFee;
    /// @notice Tick spacing of that tier. 200 on the 1% tier.
    int24 public immutable tickSpacing;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    /// @notice Position id and graduation threshold of each launched token.
    mapping(address token => uint256 positionId) public positionOf;
    mapping(address token => uint256 threshold) public graduationThresholdOf;

    /// @notice Emitted once per launch, with everything needed to verify it.
    event Launched(
        address indexed token, address indexed launcher, uint256 lpTokenId, uint256 ethInPool, uint256 devBought
    );

    error MarketIsShut(uint256 opensAtUtc);
    error DeployFailed();
    error NotLauncher();
    /// @notice The pool already existed at a price that is not the one we
    ///         asked for. Somebody initialized it ahead of us; see the note on
    ///         _poolAndSeed for why this must abort the launch.
    error PoolAlreadyPriced(uint160 found, uint160 expected);
    error TickNotAligned(int24 tick, int24 spacing);
    error DevBuyExceedsValue(uint256 asked, uint256 sent);
    error SweepFailed(address to, uint256 amount);

    /// @notice Only this address may launch. It is the deployer of the
    ///         factory, so nobody can front-run the launch itself.
    address public immutable launcher;

    struct LaunchParams {
        bytes32 salt; // chosen so the token wears the address we want
        string name;
        string symbol;
        uint256 supply; // whole tokens, 18 decimals added here
        int24 initialTick; // the opening price, PONS v1 uses -204200
        uint256 ethForDevBuy; // the whole msg.value, minus nothing
        uint256 graduationThreshold; // ETH of principal that counts as graduated
        address lpRecipient; // where the position goes; the locker cannot exist
            // before the launch, so this is a parameter rather than fixed at
            // construction. It is set to the locker once the locker exists.
    }

    constructor(
        address _positionManager,
        address _router,
        address _weth,
        uint24 _poolFee,
        int24 _tickSpacing
    ) {
        positionManager = INonfungiblePositionManager(_positionManager);
        router = ISwapRouter(_router);
        weth = IWETH9(_weth);
        poolFee = _poolFee;
        tickSpacing = _tickSpacing;
        launcher = msg.sender;
    }

    /// @notice Deploy, pool, seed and dev buy, in that order, atomically.
    /// @param  p Everything the launch needs; see LaunchParams.
    /// @return token The deployed token address, equal to predict(...).
    /// @return lpTokenId The Uniswap position id, owned by lpRecipient.
    /// @return devBought Tokens bought by the dev buy, sent to the launcher.
    function launch(LaunchParams calldata p)
        external
        payable
        returns (address token, uint256 lpTokenId, uint256 devBought)
    {
        if (msg.sender != launcher) revert NotLauncher();
        /* A misaligned tick dies deep inside TickBitmap.flipTick with an opaque
           revert, after the token has already been deployed to its salt. */
        if (p.initialTick % tickSpacing != 0) revert TickNotAligned(p.initialTick, tickSpacing);
        /* The dev buy may only spend what this call carries. Without this it
           can also spend ETH a stranger left in the factory. */
        if (p.ethForDevBuy > msg.value) revert DevBuyExceedsValue(p.ethForDevBuy, msg.value);

        uint256 supply = p.supply * 1e18;

        // 1. the token, at the address the salt chose. Which token this is
        //    depends on the factory: each one can deploy exactly one kind.
        token = _deployToken(p.salt, p.name, p.symbol, supply);
        if (token == address(0)) revert DeployFailed();

        // 2. refuse early if the gate would stop us: seeding moves tokens
        if (!IHoursToken(token).isMarketOpen()) revert MarketIsShut(IHoursToken(token).nextOpen());

        // 3 and 4. price the pool, then seed it single-sided with the whole
        //          supply. Split out so the stack stays shallow enough.
        lpTokenId = _poolAndSeed(token, supply, p.initialTick, p.lpRecipient);

        positionOf[token] = lpTokenId;
        graduationThresholdOf[token] = p.graduationThreshold;

        // 5. the dev buy, in the same transaction: this is what puts the first
        //    ETH into a single-sided pool, so it is never priceless
        if (p.ethForDevBuy > 0) {
            devBought = router.exactInputSingle{value: p.ethForDevBuy}(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: token,
                    fee: poolFee,
                    recipient: launcher,
                    amountIn: p.ethForDevBuy,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // 6. nothing stays here: leftovers go back to the launcher
        uint256 leftTokens = IERC20(token).balanceOf(address(this));
        if (leftTokens > 0) IERC20(token).transfer(launcher, leftTokens);
        uint256 leftWeth = weth.balanceOf(address(this));
        if (leftWeth > 0) weth.withdraw(leftWeth);
        if (address(this).balance > 0) {
            uint256 change = address(this).balance;
            (bool ok,) = launcher.call{value: change}("");
            /* Ignoring this used to strand the change here forever: there is no
               owner and no rescue, so unswept ETH is unrecoverable. Failing the
               whole launch is the honest outcome -- launch from an EOA. */
            if (!ok) revert SweepFailed(launcher, change);
        }

        emit Launched(token, launcher, lpTokenId, p.ethForDevBuy, devBought);
    }

    /// @dev Creates and prices the pool, verifies the pool agrees with the
    ///      price we asked for, then mints one single-sided position holding
    ///      the entire supply and hands it to the locker.
    function _poolAndSeed(address token, uint256 supply, int24 initialTick, address lpRecipient)
        private
        returns (uint256 lpTokenId)
    {
        bool isToken0 = token < address(weth);
        (address token0, address token1) = isToken0 ? (token, address(weth)) : (address(weth), token);
        int24 poolTick = isToken0 ? initialTick : -initialTick;

        /* The price comes from the tick, computed here: nothing to get wrong.
           But createAndInitializePoolIfNecessary is a NO-OP when the pool
           already exists, and Uniswap's factory will happily create a pool for
           an address that has no code yet. Our token address is deterministic,
           so anyone who learns it early can initialize the pool at a price of
           their choosing and this call silently accepts it. Initialized above
           our tick, the single-sided mint below needs WETH it is not given,
           liquidity computes to zero and the launch reverts -- permanently,
           for that salt. So read the price back and refuse to build on top of
           somebody else's. */
        uint160 wantSqrt = TickMath.getSqrtRatioAtTick(poolTick);
        address pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, poolFee, wantSqrt);
        (uint160 gotSqrt,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (gotSqrt != wantSqrt) revert PoolAlreadyPriced(gotSqrt, wantSqrt);

        (int24 tickLower, int24 tickUpper) = _positionRange(isToken0, initialTick);
        IERC20(token).approve(address(positionManager), supply);

        (lpTokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: isToken0 ? supply : 0,
                amount1Desired: isToken0 ? 0 : supply,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lpRecipient,
                deadline: block.timestamp
            })
        );
        IERC20(token).approve(address(positionManager), 0);
    }

    /// @notice The single-sided range: everything from the opening price
    ///         upward, exactly as PONS v1 does it. Bounds are truncated to
    ///         usable ticks, which requires dividing before multiplying.
    function _positionRange(bool isToken0, int24 initialTick) private view returns (int24 lower, int24 upper) {
        int24 minUsable = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxUsable = (MAX_TICK / tickSpacing) * tickSpacing;
        if (isToken0) return (initialTick, maxUsable);
        return (minUsable, -initialTick);
    }

    /// @notice Graduation, measured the way PONS v1 measures it: the ETH
    ///         principal sitting inside the locked position. Tokens sent to
    ///         the pool as a donation do not count, and a zero threshold means
    ///         graduation is simply not tracked for that token.
    /// @return principal ETH currently held as principal by the position.
    /// @return threshold The figure it has to reach.
    /// @return graduated Whether it has reached it.
    function graduationStatus(address token)
        external
        view
        returns (uint256 principal, uint256 threshold, bool graduated)
    {
        uint256 id = positionOf[token];
        if (id == 0) return (0, 0, false);
        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = positionManager.positions(id);

        address pool = IUniswapV3Factory(univ3Factory()).getPool(token, address(weth), poolFee);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        principal = _wethInPosition(token < address(weth), sqrtP, tickLower, tickUpper, liquidity);

        threshold = graduationThresholdOf[token];
        graduated = threshold != 0 && principal >= threshold;
    }

    /// @dev The WETH actually held INSIDE the locked position at the current
    ///      price, which is the ETH buyers have put in.
    /// @dev This used to be read as weth.balanceOf(pool), and that was
    ///      spoofable by DONATION: anyone could send WETH straight to the pool
    ///      and make graduationStatus report success. Liquidity cannot be
    ///      donated into somebody else's position, so that door is shut.
    /// @dev  ⛔ It is still NOT a safe number to spend against. It is a pure
    ///      function of the live pool price, and anyone can move that price
    ///      with a swap and move it back in the same transaction -- at our fee
    ///      tier, faking the 4.2 ETH threshold costs about 2% of it. It is also
    ///      not a high-water mark: it falls again when people sell. Read it as
    ///      a display figure only. Wire a payout to it and you have wired a
    ///      payout to a number a stranger controls for one block.
    function _wethInPosition(bool isToken0, uint160 sqrtP, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        pure
        returns (uint256 amount)
    {
        if (liquidity == 0) return 0;
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);

        if (isToken0) {
            /* WETH is token1: it accrues from the lower bound upward. */
            if (sqrtP <= sqrtA) return 0;
            uint160 upper = sqrtP < sqrtB ? sqrtP : sqrtB;
            return FullMath.mulDiv(liquidity, upper - sqrtA, 1 << 96);
        }
        /* WETH is token0: it accrues from the upper bound downward. */
        if (sqrtP >= sqrtB) return 0;
        uint160 lower = sqrtP > sqrtA ? sqrtP : sqrtA;
        return FullMath.mulDiv(uint256(liquidity) << 96, sqrtB - lower, uint256(sqrtB) * lower);
    }

    /// @notice The Uniswap v3 factory, read from the position manager so it
    ///         can never disagree with it.
    function univ3Factory() public view returns (address) {
        return positionManager.factory();
    }

    /// @notice The address a salt will produce, so it can be checked before
    ///         a single wei is spent.
    function predict(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        external
        view
        returns (address)
    {
        bytes32 ich = keccak256(tokenInitCode(name, symbol, supply * 1e18));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, ich)))));
    }

    /// @dev Deploys this factory's one token type. Implemented by each
    ///      factory, which is what makes them impossible to mix up.
    function _deployToken(bytes32 salt, string calldata name, string calldata symbol, uint256 supply)
        internal
        virtual
        returns (address);

    /// @dev The creation code of this factory's one token type, with its
    ///      constructor arguments. Must match _deployToken exactly, or the
    ///      ground salt points at an address the launch will never produce.
    function tokenInitCode(string memory name, string memory symbol, uint256 supplyWei)
        public
        pure
        virtual
        returns (bytes memory);

    receive() external payable {}
}

/* ------------------------------------------------------------ interfaces */

interface IHoursToken {
    function isMarketOpen() external view returns (bool);
    function nextOpen() external view returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface INonfungiblePositionManager {
    function factory() external view returns (address);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

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

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface ISwapRouter {
    /// @dev SwapRouter02's shape: it has NO deadline field. Robinhood chain
    ///      runs 02 (it answers factoryV2() and positionManager()), and
    ///      encoding the older struct with a deadline shifts every argument
    ///      by one word, which reverts with no data at all.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

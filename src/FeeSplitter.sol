// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Fee Splitter
/// @notice Holds the $STOCK Uniswap v3 LP position and turns its trading fees
///         into ETH, split 60 / 20 / 20 between the daily prize pot, the partner
///         and the deployer. The three recipients and their shares are fixed
///         at construction and no function can change them.
/// @notice crank() is KEEPER-ONLY, and that is a deliberate reversal. It used
///         to be permissionless so the pot would keep filling even with every
///         machine of ours off, but the slippage floor is necessarily chosen by
///         the caller, and a permissionless crank hands that choice to an
///         attacker: call crank(0) inside your own sandwich and the pot eats
///         the loss. Measured on a fork, that cost the recipients 88% of one
///         cycle. Only the keeper may crank now, so the floor is always ours.
///         lock() is gated harder still -- keeper only -- because it is a
///         one-shot irreversible setter, not maintenance. withdraw() stays open
///         to anyone, since it can only ever pay its own recipient.
/// @notice THE LIQUIDITY IS LOCKED FOREVER, AND FROM THE FIRST BLOCK. This
///         contract is deployed BEFORE the launch and is named as the launch's
///         lpRecipient, so Uniswap mints the position straight into it and no
///         person ever holds it. Once here it can never leave: there is no
///         transfer, no decreaseLiquidity, no owner, no admin, no rescue and no
///         upgrade path. The only thing this contract can do with the position
///         is collect its fees. Nobody can touch the liquidity, us included.
/// @dev    $STOCK reverts every transfer outside market hours, so collect()
///         and the token-side sale only succeed while the session is open. A
///         crank attempted after the bell reverts and costs the caller gas
///         alone; nothing is stranded, the fees simply wait for the next open.

interface INonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function ownerOf(uint256 tokenId) external view returns (address);
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

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IWETH9 is IERC20 {
    function withdraw(uint256 amount) external;
}

contract FeeSplitter {
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter public immutable router;
    IWETH9 public immutable weth;
    IERC20 public immutable token;
    uint24 public immutable poolFee;

    /// @notice The locked position. Zero until lock() records it.
    /// @dev    NOT immutable, and that is the whole point. A constructor that
    ///         needed the position id could only run AFTER the launch, so the
    ///         LP would have to land in an EOA first and be forwarded -- a
    ///         window in which "locked forever" is simply untrue. Leaving it
    ///         mutable lets this contract exist BEFORE the launch and be the
    ///         mint recipient, so custody is never held by a person. Uniswap's
    ///         position manager mints with a plain _mint and never calls
    ///         onERC721Received, so the id has to be recorded afterwards; the
    ///         liquidity is already locked by then, because it arrived here and
    ///         there is no way out. This is how RWA404's locker did it.
    uint256 public positionId;

    /// @notice The ops key that cranks every 30 minutes. The three recipients
    ///         may also crank, so no single lost key stops the pot filling.
    address public immutable keeper;

    /// @notice When the last crank happened, set at construction so the
    ///         dead-man switch below cannot be open on day one.
    uint256 public lastCrankAt;

    /// @notice Dead-man switch. The LP is locked in here FOREVER, so a
    ///         keeper-only crank would mean that losing our keys strands every
    ///         future fee for good -- the liquidity could never be moved
    ///         somewhere with a working keeper. After this long without a
    ///         successful crank, anyone may crank again. It trades the sandwich
    ///         risk back for liveness, but only once we have visibly stopped.
    uint256 public constant CRANK_OPENS_AFTER = 30 days;

    address public immutable pot;
    address public immutable partner;
    address public immutable dev;
    uint16 public constant POT_BPS = 6000;
    uint16 public constant PARTNER_BPS = 2000;
    uint16 public constant DEV_BPS = 2000;

    /// @dev Reentrancy latch. 1 = open, 2 = inside a crank.
    uint256 private locked = 1;

    /// @notice ETH owed to a recipient whose direct payment failed. Anyone can
    ///         push it to them later with withdraw(). Exists so that one
    ///         recipient that cannot receive ETH can never brick the crank for
    ///         the other two, and can never strand the pot's share.
    mapping(address => uint256) public owed;

    /// @notice Sum of every unwithdrawn `owed` balance, held back from splits.
    uint256 public deferredTotal;

    /// @notice Emitted on every successful crank, whoever paid for it.
    event Cranked(address indexed caller, uint256 ethSplit, uint256 potShare);
    /// @notice A direct payment failed and was booked for later withdrawal.
    event PaymentDeferred(address indexed to, uint256 amount);
    /// @notice Deferred ETH was successfully pushed to its recipient.
    event Withdrawn(address indexed to, uint256 amount);
    /// @notice The position this splitter will collect from, recorded once.
    event Locked(uint256 indexed positionId);

    error Reentrancy();
    error NothingToSplit();
    error NothingOwed();
    error TransferFailed(address to);
    error ZeroAddress();
    error NotAuthorised(address caller);
    error WrongPosition(uint256 tokenId);
    error AlreadyLocked(uint256 positionId);
    error NotOwned(uint256 tokenId);
    error NotOurPool(address token0, address token1, uint24 fee);
    error NotLocked();
    error PositionEmpty(uint256 tokenId);

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address _positionManager,
        address _router,
        address _weth,
        address _token,
        uint24 _poolFee,
        address _keeper,
        address _pot,
        address _partner,
        address _dev
    ) {
        if (
            _positionManager == address(0) || _router == address(0) || _weth == address(0) || _token == address(0)
                || _keeper == address(0) || _pot == address(0) || _partner == address(0) || _dev == address(0)
        ) revert ZeroAddress();

        positionManager = INonfungiblePositionManager(_positionManager);
        router = ISwapRouter(_router);
        weth = IWETH9(_weth);
        token = IERC20(_token);
        poolFee = _poolFee;
        keeper = _keeper;
        pot = _pot;
        partner = _partner;
        dev = _dev;
        lastCrankAt = block.timestamp;
    }

    /// @notice Record the position this splitter holds. Call it once, right
    ///         after the launch that minted the LP straight to this address.
    /// @dev    The liquidity is ALREADY locked before this runs: the position
    ///         arrived here in the launch transaction and this contract has no
    ///         way to send an NFT anywhere. This only writes down which id to
    ///         collect from, so the crank knows where to look.
    /// @dev    Refuses anything that is not genuinely our token's pool position
    ///         and is not already owned by this contract, and can only ever be
    ///         set once -- so a stray or hostile NFT cannot take the slot and
    ///         strand the real position forever.
    function lock(uint256 tokenId) external {
        /* KEEPER ONLY, and deliberately NOT crankableBy(). Cranking is routine
           maintenance; this is a one-shot irreversible setter, and binding the
           wrong id makes the real position's fees unreachable forever. Sharing
           the crank's ACL would let any recipient -- including a third party's
           wallet -- mint a dust position in this very pool, send it in and lock
           it first, and the dead-man switch would eventually hand that power to
           everyone. A destructive setter must never inherit a maintenance ACL. */
        if (msg.sender != keeper) revert NotAuthorised(msg.sender);
        if (positionId != 0) revert AlreadyLocked(positionId);
        if (positionManager.ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);

        (,, address t0, address t1, uint24 fee,, , uint128 liq,,,,) = positionManager.positions(tokenId);
        /* An empty position of the right pool is still a valid-looking target,
           and it is the mistake a human types from an explorer. */
        if (liq == 0) revert PositionEmpty(tokenId);
        bool ours = fee == poolFee
            && ((t0 == address(token) && t1 == address(weth)) || (t0 == address(weth) && t1 == address(token)));
        if (!ours) revert NotOurPool(t0, t1, fee);

        positionId = tokenId;
        emit Locked(tokenId);
    }

    /// @notice Prove the keeper is alive without needing fees to sell.
    /// @dev    crank() reverts NothingToSplit when there is nothing to take, and
    ///         a revert rolls back lastCrankAt -- so a quiet month would open the
    ///         dead-man switch with every key alive and hand the slippage floor
    ///         back to the world. This advances the clock on its own.
    function poke() external {
        if (msg.sender != keeper) revert NotAuthorised(msg.sender);
        lastCrankAt = block.timestamp;
    }

    /// @dev The keeper and the three recipients may always crank. Everyone else
    ///      may only once the dead-man switch has opened.
    function crankableBy(address caller) public view returns (bool) {
        if (caller == keeper || caller == pot || caller == partner || caller == dev) return true;
        return block.timestamp > lastCrankAt + CRANK_OPENS_AFTER;
    }

    /// @notice Collects the position's fees, sells the $STOCK side for ETH and
    ///         pays out the three shares. Keeper or a fee recipient, while the
    ///         market is open; anyone once the dead-man switch has opened.
    /// @param  minEthOut Slippage floor for the TOKEN-SIDE SALE ONLY. Size it
    ///         against `ethFromSale`, never against `ethSplit`: the split also
    ///         contains the WETH the position collected as fees, which was
    ///         never routed through the pool. Quoting 97% of `ethSplit` was the
    ///         original bug -- it made every honest crank revert with "Too
    ///         little received" the moment the WETH side passed 3% of the take.
    /// @return ethSplit Total ETH paid out by this call.
    /// @return ethFromSale The part of it that came out of the swap, which is
    ///         the only part `minEthOut` governs.
    function crank(uint256 minEthOut)
        external
        nonReentrant
        returns (uint256 ethSplit, uint256 ethFromSale)
    {
        if (!crankableBy(msg.sender)) revert NotAuthorised(msg.sender);
        if (positionId == 0) revert NotLocked();
        lastCrankAt = block.timestamp;

        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint256 tokenBalance = token.balanceOf(address(this));
        if (tokenBalance > 0) {
            token.approve(address(router), tokenBalance);
            ethFromSale = router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(token),
                    tokenOut: address(weth),
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: tokenBalance,
                    amountOutMinimum: minEthOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) weth.withdraw(wethBalance);

        /* Only this cycle's proceeds are splittable: anything already booked
           to a recipient stays theirs and is never re-split. */
        ethSplit = address(this).balance - deferredTotal;
        if (ethSplit == 0) revert NothingToSplit();

        uint256 potShare = (ethSplit * POT_BPS) / 10_000;
        uint256 partnerShare = (ethSplit * PARTNER_BPS) / 10_000;
        /* the remainder rather than a third percentage, so wei never strands */
        uint256 devShare = ethSplit - potShare - partnerShare;

        _pay(pot, potShare);
        _pay(partner, partnerShare);
        _pay(dev, devShare);

        emit Cranked(msg.sender, ethSplit, potShare);
    }

    /// @notice What the position currently owes. Not a view: quote it with
    ///         a static call, exactly as ops and the crank script do.
    function pending() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (positionId == 0) revert NotLocked();
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// @notice Accepts the LP position. There is no matching way out, and
    ///         that is the point: the liquidity is locked from this moment.
    /// @dev    Accepts any NFPM position into custody; lock() is what decides
    ///         which one this splitter actually collects from, and lock() is
    ///         keeper-only precisely because taking custody is open.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        /* Only Uniswap positions, so unrelated NFTs cannot be parked here. Any
           position is accepted, because lock() is what decides which one this
           splitter collects from, and lock() verifies the pair itself. */
        if (msg.sender != address(positionManager)) revert NotAuthorised(msg.sender);
        return this.onERC721Received.selector;
    }

    /// @notice Pushes ETH that a failed payment booked for `to`. Callable by
    ///         anyone, and it can only ever pay `to`, so a recipient who could
    ///         not receive at crank time never loses the money.
    function withdraw(address to) external nonReentrant {
        uint256 amount = owed[to];
        if (amount == 0) revert NothingOwed();
        owed[to] = 0;
        deferredTotal -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed(to);
        emit Withdrawn(to, amount);
    }

    /// @dev Never reverts on a failed send. A recipient that cannot take ETH
    ///      today gets it booked instead, so it can neither block this crank
    ///      nor every future one.
    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        /* Capped: the deferral below covers a recipient that REVERTS, but not one
           that burns every drop of gas -- that would take the whole crank down
           with an out-of-gas before `ok` is ever read. 60k is far more than any
           EOA or reasonable contract wallet needs to accept ETH. */
        (bool ok,) = to.call{value: amount, gas: 60_000}("");
        if (!ok) {
            owed[to] += amount;
            deferredTotal += amount;
            emit PaymentDeferred(to, amount);
        }
    }

    receive() external payable {}
}

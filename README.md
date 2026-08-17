<p align="center">
  <img src="assets/logo.png" alt="STOCK" width="180">
</p>

# Stock Coin — an ERC-20 that keeps market hours

`$STOCK` is a token that can only be traded while the US stock market is open:
Monday to Friday, 09:30 to 16:00 America/New_York. Outside the session every
transfer reverts. The schedule is computed on chain from `block.timestamp`,
daylight saving included, and there is no way to change it.

The clock is the whole product, so the contract is deliberately small and has
nothing else in it.

## What the token can and cannot do

Cannot: pause, tax, blacklist, mint, upgrade, seize, disable the gate, or change
the hours. None of those functions exist.

Can: nothing. There is no owner, no admin, no guardian and no escape hatch. The
ABI is an ordinary ERC-20 plus read-only clock views.

Two properties are worth checking yourself rather than believing:

- `isOpenAt` is `pure`. The compiler enforces that it reads no storage, so no
  state anywhere can change whether the market is open.
- The deployed bytecode contains no `CALL`, `DELEGATECALL`, `CREATE`, `CREATE2`
  or `SELFDESTRUCT` opcode at all. The token makes no external call, so it has
  no reentrancy surface and no token hook. Storage is exactly five slots.

## The clock

```solidity
function isMarketOpen()               external view returns (bool);
function nextOpen()                   external view returns (uint256);
function nextClose()                  external view returns (uint256);
function isOpenAt(uint256 ts)         public  pure returns (bool);
function nextOpenAfter(uint256 ts)    public  pure returns (uint256);
```

Outside the session a transfer reverts with `MarketClosed(uint256 opensAtUtc)`,
carrying the timestamp of the next opening bell.

The US daylight-saving rule is hardcoded as legislated since 2007: EDT from the
second Sunday of March at 02:00 to the first Sunday of November at 02:00. If
Congress changes the rule, this token keeps the old one — an unchangeable
schedule is the point. The clock is therefore only correct from 2007-03-11
onward.

The implementation was differential-tested against IANA `tzdata` across roughly
16 million timestamps from 2007 to 2400 — every DST transition, every leap day,
and the exact boundary seconds at 09:30:00 and 16:00:00 — with zero mismatches.

## Integrating: read the clock, not the revert

`MarketClosed` does not survive a router. Uniswap's `TransferHelper` wraps the
token call and re-reverts with `Error("TF")` on a buy and `Error("STF")` on a
sell, so a swap attempted outside the session surfaces a generic transfer
failure rather than the token's own error. Only a direct `transfer` or
`transferFrom` returns `MarketClosed(opensAtUtc)`, selector `0x9dc30b8e`.

This is router behaviour and applies to any token that restricts transfers; it
cannot be changed from inside the token, because `TransferHelper` discards
custom errors by design. Interfaces should call `isMarketOpen()` before
offering a trade rather than attempting to interpret a revert reason.

Other integration notes: a zero-value transfer is gated like any other;
`approve` works around the clock but there is no EIP-2612 `permit`; transfers to
`address(0)` succeed while `totalSupply` is immutable, so burning that way
leaves `totalSupply` overstating the float.

## Launching

`StockFactory` does the whole launch in one transaction: CREATE2-deploys the
token, creates and prices a Uniswap v3 WETH pool from a tick, mints one
single-sided position holding 100% of supply, performs the dev buy, and sweeps
the remainder back to the launcher. `ProbeFactory` is identical except that it
deploys a rehearsal token on a five-minutes-open / five-minutes-shut clock, so
the behaviour of a market that opens and closes can be watched in an afternoon.

Each factory can deploy exactly one kind of token, which is what makes them
impossible to mix up.

The sqrt price is derived on chain by `TickMath`, a port of Uniswap v3-core's
`getSqrtRatioAtTick`. Computing it in floating point lands one tick low at large
ticks; that bug is why the library is here.

### If you launch to a pre-announced CREATE2 address, read this

`createAndInitializePoolIfNecessary` is a no-op when the pool already exists,
and Uniswap's v3 factory will create a pool for an address that has no code yet.
Anyone who learns the address in advance can therefore initialize the pool at a
price of their choosing before you launch. If they initialize it above your
intended tick, a single-sided mint that supplies no WETH computes to zero
liquidity and the launch reverts — permanently, for that salt.

`_poolAndSeed` therefore reads `slot0` back after creating the pool and aborts
with `PoolAlreadyPriced` unless the price is the one it asked for, rather than
silently building on a stranger's price. A pool that already sits at the
intended price is accepted, since that is harmless.

That check makes the launch fail safely instead of unpredictably; it does not
make a pre-announced address safe. Do not publish a CREATE2 launch address
before the launch lands. The window exists only while the token has no code.

## Fees

`FeeSplitter` holds the LP position and turns its trading fees into ETH, split
60 / 20 / 20.

It is deployed **before** the launch and named as the launch's `lpRecipient`, so
Uniswap mints the position straight into it and no person ever holds it. The
liquidity is therefore locked inside the launch transaction, not at some later
moment when somebody remembers to forward the NFT. `lock(tokenId)` afterwards
only records which position to collect from; it accepts one position, once, and
only if this contract already owns it and it really is this token's pool.

The position cannot leave: there is no transfer, no
`decreaseLiquidity`, no owner, no admin, no rescue and no upgrade path, and no
`isValidSignature`, so `ERC721Permit` cannot be used against it either. The only
thing the contract can do with the position is collect its fees.

`crank` is keeper-gated rather than permissionless. The slippage floor for the
token-side sale is necessarily chosen by the caller, and a permissionless crank
hands that choice to an attacker: calling `crank(0)` inside your own sandwich
turns the pot's ETH into your profit. Measured against a fork, that cost the
recipients 88% of a cycle. The three recipients can also crank, and a dead-man
switch reopens it to anyone after 30 days without a successful crank — because
the LP is locked in the splitter forever, so losing every key must not strand
every future fee.

## Build

```
forge install foundry-rs/forge-std
forge build
forge test
```

`via_ir` is on: the factories carry a whole token each, and without IR the
launch path is stack-too-deep. `bytecode_hash` is `none` so that comment-only
edits cannot move a CREATE2 address.

## Deployed

Robinhood Chain (4663). Uniswap v3, 1% fee tier, tick spacing 200.

| | |
|---|---|
| `StockFactory` | `0x2101057F4EA75514ae6dFCC7ad741180afFaCeC3` |
| `ProbeFactory` | `0xDB77794e7beeEa37F0Be8d4499EEDC14A769fB88` |
| `FeeSplitter` (flagship) | `0x12650aAFabCD799c585857660b9AEA22FAd97D8B` |

Each factory's `launcher` is fixed at construction and is the only address that
may call `launch`. Token addresses are published once their launch has landed,
for the reason given above.

## Audit

Findings, fixes and what was verified on chain: [AUDIT.md](AUDIT.md).

## Licence

MIT.

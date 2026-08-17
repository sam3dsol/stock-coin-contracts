# Stock Coin — Security Audit Summary

**Date:** 17 August 2026
**Network:** Robinhood Chain (4663) · Uniswap v3, 1% fee tier, tick spacing 200
**Compiler:** solc 0.8.26, optimizer enabled (20,000 runs), `via_ir`, `bytecode_hash = none`

## Scope

| Contract | Role |
|---|---|
| `MarketHoursToken.sol` | The token. Transfers clear only during the US equities regular session. |
| `ProbeHoursToken.sol` | Rehearsal token on a five-minute open/shut cycle. |
| `LaunchFactoryBase.sol` | Launch logic: deploy, pool, seed liquidity, dev buy, sweep. |
| `StockFactory.sol` / `ProbeFactory.sol` | Type-restricted factories, one token each. |
| `TickMath.sol` / `FullMath.sol` | Uniswap v3 arithmetic ports. |
| `FeeSplitter.sol` | Holds the LP position permanently; converts fees to ETH and distributes them. |

The operational scripts that hold keys and submit transactions were reviewed alongside the
contracts, as defects there are indistinguishable from contract defects in effect.

## Summary

Four independent adversarial reviews were carried out. **No open vulnerabilities remain.** One
advisory note is recorded below.

The test suite accompanying the audited contracts comprises 45 tests, all passing, and is
published alongside them. The complete launch, trading and fee settlement
lifecycle was additionally exercised on mainnet using the rehearsal token.

## Methodology

Review was conducted by source analysis, bytecode disassembly, storage-layout inspection,
exhaustive four-byte selector fuzzing, differential testing of the on-chain clock against IANA
`tzdata`, property-based fuzzing of the arithmetic against reference implementations, and
read-only fork testing against the live Uniswap v3 deployment.

Both deployed factories were confirmed byte-for-byte identical to the audited source outside their
immutable slots, so conclusions drawn from the source apply to the deployed code.

## Verified properties

**The token has no privileged role of any kind.** There is no owner, administrator, pause, mint,
blacklist or upgrade path. The ABI comprises the ERC-20 interface and read-only clock accessors.
`isOpenAt` is declared `pure`, so the compiler guarantees it reads no storage and no state can
affect whether the market is open. Storage is exactly five slots and `totalSupply` is immutable.

**The token performs no external calls.** Disassembly of both the creation and runtime bytecode
found no `CALL`, `CALLCODE`, `DELEGATECALL`, `STATICCALL`, `CREATE`, `CREATE2` or `SELFDESTRUCT`
instruction. Reentrancy is therefore structurally impossible and no transfer hook exists.

**Behaviour is identical for every address.** Fuzzing across arbitrary senders, recipients and
amounts produced identical outcomes throughout. No address receives distinct treatment, including
the pool.

**The trading schedule is exact.** The clock was differential-tested against IANA `tzdata` across
approximately 16.8 million timestamps spanning 2007 to 2400, including every daylight-saving
transition, every leap day, and the precise boundary seconds at 09:30:00 and 16:00:00, with no
discrepancies. A subset was replayed against the deployed bytecode.

**The liquidity position is irrevocable.** It is minted directly to the fee splitter within the
launch transaction and is never held by an externally owned account. The deployed splitter exposes
no function capable of transferring, approving or reducing the position, and the corresponding
selectors are absent from its compiled bytecode. Fee collection is the only reachable operation.

**Fee distribution is exact.** The 60 / 20 / 20 split was verified under fuzzing to allocate the
full amount with no residual balance, the remainder being assigned rather than truncated. A failed
payment to one recipient is recorded for later withdrawal and cannot impede the others.

**Arithmetic matches Uniswap.** The `TickMath` and `FullMath` ports were verified constant by
constant against Uniswap v3-core and differentially fuzzed against arbitrary-precision references.
The single-sided position range was confirmed correct in both token orderings.

**The launch is authenticated and deterministic.** Only the immutable `launcher` may launch. The
address produced by `predict` matches the address the launch deploys, verified against the deployed
factories.

## Advisory

`graduationStatus` is derived from the pool's current price. That price can be moved by any party
within a single transaction and returned immediately, so the value is suitable for display only and
must not be used as a settlement or unlock condition. It is not read by any contract or service at
present. Should that change, a time-weighted average or a monotonic high-water mark is required.

## On-chain verification

The rehearsal token was deployed and exercised end to end:

- **Custody.** The liquidity position was minted directly to the fee splitter within the launch
  transaction and was never held by an externally owned account.
- **Transfer restriction.** Purchases and sales executed during the session. Outside the session,
  transfers reverted while approvals continued to succeed, consistent with the specification.
- **Fee distribution.** A single settlement distributed 0.000034103766306355 ETH in the ratio
  60.00% / 20.00% / 20.00%, leaving a zero residual balance in the contract.

## Deployed contracts

| Contract | Address |
|---|---|
| `StockFactory` | `0x2101057F4EA75514ae6dFCC7ad741180afFaCeC3` |
| `ProbeFactory` | `0xDB77794e7beeEa37F0Be8d4499EEDC14A769fB88` |
| `FeeSplitter` | `0x12650aAFabCD799c585857660b9AEA22FAd97D8B` |

The `launcher` on each factory is fixed at construction and is an externally owned account.

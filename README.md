# WhaleTaxHook

WhaleTaxHook is a deliberately small Uniswap v4 dynamic-fee hook. For each swap it reads the
pool's **current active liquidity** from the canonical `PoolManager`. If the absolute value of
`amountSpecified` is greater than one percent of that liquidity, the swap uses the immutable whale
fee; otherwise it uses the immutable base fee. Equality is charged the base fee. This rule applies
equally to exact-input (negative) and exact-output (positive) swaps and in both directions.

The hook neither takes swap deltas nor holds tokens. It has no owner, administrator, upgrade path,
or mutable fee parameters. Its only permissions are `afterInitialize` and `beforeSwap` (address mask
`0x1080`, decimal `4224`). Liquidity addition/removal has no callback, so this hook cannot block an
LP exit.

## Build and test offline

The repository vendors exact ordinary-file snapshots of all dependencies:

- `v4-core`: `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`
- `forge-std`: `1de6eecf821de7fe2c908cc48d3ab3dced20717f`
- `solmate`: `4b47a19038b798b4a33d9749d25e570443520647`

With Foundry and Solidity 0.8.26 already installed, no network access is needed:

```sh
forge build
forge test
forge fmt --check
```

The suite uses a real vendored `PoolManager`, initializes a dynamic-fee pool, adds concentrated
liquidity, executes swaps through `PoolSwapTest`, checks emitted swap fees immediately below and
above the threshold, tests rejection paths, and removes the complete LP position.

## Deployment parameters and attestation

The constructor is:

```solidity
constructor(IPoolManager manager, uint24 baseFee, uint24 whaleFee)
```

The manager must be the canonical PoolManager for the target chain. Both fees use v4 fee units
(hundredths of a basis point), must be at most `1_000_000`, and `whaleFee` must be strictly greater
than `baseFee`. The deployment address must be CREATE2-mined so its low permission bits equal
`0x1080`; construction reverts at any other address.

For admission tooling, creation code means artifact creation bytecode followed by standard ABI
encoding of those three constructor arguments. The corresponding values are:

```text
IMD_HOOK_FLAGS=4224
IMD_POOL_MANAGER=<the constructor's canonical manager address>
IMD_HOOK_CREATION_CODE=<WhaleTaxHook creation bytecode || abi.encode(manager,baseFee,whaleFee)>
```

Every pool using the hook must set `PoolKey.fee` to `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`).
`afterInitialize` enforces that setting, verifies the key names this hook, records only that
`PoolId`, and publishes the base fee as the pool's stored dynamic fee. Every callback authenticates
`msg.sender` as the immutable manager; the router-like `sender` argument and arbitrary `hookData`
are ignored and cannot establish identity or affect pricing.

## Assumptions and operations

“Pool liquidity” means v4's active in-range liquidity, not token reserves, TVL, or total liquidity
across all ranges. Consequently the cutoff changes automatically when price crosses ticks or active
liquidity changes. A swap's classification is made once, immediately before execution, against that
pre-swap value. Integer division rounds the one-percent cutoff down.

Deployers are responsible for selecting economically sensible immutable fees, mining and verifying
the hook address, choosing the canonical manager, and creating only dynamic-fee pools. Integrators
must set normal slippage limits and should explain that crossing the threshold changes the fee
discontinuously. Operators have no emergency switch or fee-update power; remediation requires a new
hook and a new pool. Before production use, independently review the contract and rehearse the exact
deployment and full LP lifecycle on the target chain. Passing these tests is not a security audit.


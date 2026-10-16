# ROBOBET

A fixed-supply ERC-20 token for an IMD custom-token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `RoboBetToken` (`src/RoboBetToken.sol`) |
| `name()` | `ROBOBET` |
| `symbol()` | `ROBOBET` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |

## Behaviour

- The constructor mints the whole supply once, to `msg.sender`. On launch, `msg.sender` is IMD's
  ProjectFactory, which then distributes it (10% to the launch's MerkleDistributor, 80% into the
  Uniswap v4 pool against IMD, the remaining 10% to the requester's `remainderTo`).
- It is a plain OpenZeppelin v5.1.0 `ERC20`: no owner, no mint, no burn, no pause, no blacklist, no
  transfer fee or tax. The supply cannot grow or shrink after deployment, and no one but a holder
  (or a spender the holder approved) can move a holder's balance.
- Because transfers are exact, the factory's transfers, the distributor's claims, the pool seed and
  swaps all move exactly the stated amounts; no exemption addresses are needed.

## Assumptions

- The brief asks only for name, symbol, supply and decimals. No fee, tax, burn or governance logic
  was requested, so none is implemented.
- "Minted to the deployer" means `msg.sender` of the constructor (the factory on launch).
- No owner-settable values exist, so there is nothing to configure after launch.

## Deployment parameters

- Compiler: solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` (pinned in `foundry.toml`).
- No constructor arguments. Deployed by IMD's ProjectFactory from the built bytecode.
- Pool / economics are fixed by the launch (pair IMD, fee 12500, tick spacing 60, poolBps 8000,
  initial market cap 3,500 IMD, remainder to `0x12a7aad083cef06fef7c295514b52fc8bc81960d`); they are
  not part of the token contract. `launch.json` is written by the manifest step, not here.
- `script/DeployRoboBetToken.s.sol` is a reviewable local/testnet deploy script; it is not the launch.

## After launch

Nothing to set: the token has no admin and no configurable values.

## Operational responsibilities

- Nobody operates the token after deployment; it has no privileged roles.
- Holders and integrators are responsible for their own approvals (standard ERC-20 approve race
  caveats apply; prefer setting allowance to 0 before changing it, or use exact allowances).
- Explorer source verification and the launch itself are handled by IMD's deployer.

## Development

```
forge build
forge test
forge fmt --check
```

Dependencies are vendored as plain files in `lib/` (forge-std v1.9.7, OpenZeppelin Contracts v5.1.0).

## Security notes

Tests cover metadata, supply, transfers, allowances, revert paths and fuzzed conservation of
supply. Passing tests are not an audit. No static analysers (Slither/Mythril) were run for this task.

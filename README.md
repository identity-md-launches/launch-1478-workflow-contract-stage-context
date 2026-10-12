# RH PEPEFRONT contracts

RH PEPEFRONT is an **unofficial community strategy game**, not IMD and not an official IMD product. This deliverable implements the contracts, tests and ABI handoff for the contract stage. Deployment, source publication, launch admission, fee handoff, the playable website and its IPFS publication belong to the later services and frontend stages.

The application is a deterministic, single-player strategy campaign: Initiative Pepes and Cult Pepes harvest ore, build power → barracks → factory → tech, recruit ranked Pepes, and win by destroying the enemy base or holding a control point. Each confirmed transaction is a strategic order. Client animation does not decide outcomes. There is no score submission, server, signer, oracle, multiplayer settlement or randomness dependency.

## Build and check

Run from this repository root:

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

Solidity is pinned to **0.8.26**, optimizer enabled with 200 runs, EVM target `paris`, and `bytecode_hash = "none"`. No FFI, filesystem cheatcode permissions, environment-dependent tests, fork or network is required. All Solidity dependencies are ordinary vendored files. See [DEPENDENCIES.md](docs/DEPENDENCIES.md). The compiler and Foundry are the verifier's tools, not repository binaries.

The production deployment consists of:

| Contract | Constructor arguments, in order | Purpose |
| --- | --- | --- |
| `LaunchToken` | None | Plain ERC-20; name `RH PEPEFRONT`, symbol `PEPEFRONT`, 18 decimals; exactly `1000000000000000000000000000` units minted once to its deployer |
| `Game` | `address initialOwner`, `address token` | Owner is `$owner`; token is `$token`, referencing the earlier LaunchToken deployment |

`Battlefield` and `CommandPower` are internal libraries compiled into `Game`. They are not separate deployments. The application integrates match management, command-power accounting and prize custody; there is no application hook, MatchFactory or separate PrizeVault deployment. Every storage reference is initialized directly from its mapping; there is no storage-reference-returning ledger selector.

The constructors neither call external contracts nor require code at a dependency address. `Game` validates token code when tokens are first used. There are no initializer calls, payable constructors, upgrade paths or runtime link placeholders. The token has no owner, extra minting, pause, blocklist, transfer fee or upgrade entry point.

## Approved launch parameters

The manifest contributor writes `launch.json` after this implementation is accepted. No manifest is authored here. Source publication, policy artifacts, signed artifact linkage and admission are service responsibilities.

| Parameter | Approved value |
| --- | --- |
| Chain | Robinhood Chain, `4663` |
| Owner / creator (`$owner`) | `0x3d6a89c8751a45dd577a4c1f3b34e71c58236193` |
| IMD prize asset and pool pair | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, 18 decimals |
| Allocation receiver | `0x6f4f8890a34b509bc226377cf1e37a4972f55769` |
| Trading receiver | `0x8f8bc9d953f0891524fcfa5442b2b2f5c4badfb9` |
| Split factory | `0x5cfcece40ceb76f0e99733652fb9dfda1658d4e9` |
| Platform beneficiary | `0x0a5b0e232d47541eb503bc862a9db2672b8fba24` |
| Pool fee | `12500` = **1.25%** |
| Tick spacing | `60` |
| Manifest initial price | `"79228162514264337593543950336"` |
| Effective opening market cap | Policy derives opening price from **2,500 IMD for the entire supply** and token ordering |

The task's chain table overrides the older `0xD34a…263B7` IMD address in the creative brief. `Game.prizeToken()` embeds the approved chain-table IMD address. No alternative router, receiver or treasury address is guessed. No external addresses were inferred from the supporting address guide.

The factory mints no additional tokens: it splits the token's original balance, with 80% for pool liquidity, 10% for the swarm's distributor and 10% for the supplied allocation receiver. No supply is reserved for `Game`. Receiver splitting and the publishing relayer's transfer of requester fee entitlement to the trading receiver are external operations. These contracts neither replace those receivers nor grant the platform gameplay authority. Use the deployed pool key from the service handoff in the frontend; token ordering and live addresses cannot be predicted in this source contribution.

## Economy and reconciliation of the brief

The approved workflow references [ONCHAIN.md economy v2](https://github.com/adaki2004/pepe2pepe-game-template/blob/3df067d1ab5c82481f27e9d4e2dc17ecb1ea93aa/ONCHAIN.md). This implementation follows its on-chain single-player model and the assignment's fixed launch policy where the earlier creative proposal conflicts:

| Earlier proposal | Implemented contract behavior |
| --- | --- |
| 21M `$FRONT`, minting during play, per-block emissions and halvings | Fixed 1B `PEPEFRONT`; daily **deposited budgets**, no mint or autonomous emission/halving schedule. Funding is explicit; no unfunded future reward is promised. The title/symbol follow the workflow's repeated `RH PEPEFRONT (PEPEFRONT)` heading. |
| 1v1, 2v2, FFA, swarm or seat-signed outcomes | Solo deterministic battles against rising selectable AI pressure, with every meaningful move verified by `Game` |
| Match entries and season top-rank IMD payments | Free entry. Deposited IMD and game tokens are shared pro-rata by verified daily command power. Each UTC day is a settlement period; there is no extra top-N/season payout or player entry escrow. |
| 24h reward cooldown, 3 wins and 5 harvest claims per 24h | 24h cooldown after a rewarded victory, maximum 3 credited wins and 5 credited harvest actions per UTC day. The stricter cooldown means at most one rewarded victory in any rolling 24h window; limits are wallet limits, not identity checks. |
| Cosmetic spending burns 75% | Eight fixed-price cosmetics cost 100 PEPEFRONT each. 75% is permanently retired inside Game and cannot be spent or recovered; 25% funds the next day's game-token rewards. ERC-20 `totalSupply()` remains constant: this is retirement, not a token-level burn. |
| ETH office unlocks and automated buybacks | No ETH-priced action, swap, price oracle or buyback. All `act` calls require zero native value. No unspecified router or treasury is needed. |
| Extra transfer/trade/purchase fee splits | Plain token transfers; the protocol pool trades at the mandated 1.25%. No custom swap hook or extra tax is added. Cosmetic proceeds follow the 75/25 retirement/reward split above. |

These are disclosed implementation choices, not claims that the original multiplayer or emission system is present. Game rules, cosmetic prices and revenue splits are immutable. UI-only presentation and controls can animate these strategy orders; a client must not promise rewards for unconstrained local RTS scores.

## Funding and reward settlement

An epoch is `floor(block.timestamp / 86400)` (UTC day). Any sponsor may approve exact amounts and call `fund(epoch, tokens, prizes)` for one of the next 30 days. Both amounts are raw minor units, independently optional; at least one must be positive. Funding is irrevocable once the day begins **if any power is earned**. Funding cannot change an active day's terms. Approving/transferring directly to Game does not fund an epoch; use `fund`.

A battle is marked reward-eligible only at its start, when the current epoch is funded, the wallet's cooldown has ended, and the full 20-minute deadline fits inside that day. Other battles are free practice and award zero. Reward eligibility does not promise a fixed amount: the final share depends on the day's total verified power.

On an eligible victory, power is `10 × (difficulty + 1) + countedHarvests`, where difficulty is 0–2 and at most five harvest actions per wallet/day count. Loss, surrender and expiry give zero. A rewarded victory starts the wallet's 24-hour cooldown. Free play neither resets the cooldown nor increases reward power. All wallets split the same funded budget; creating more wallets cannot create more tokens or expand an epoch's budget.

At the next UTC midnight, a player's share becomes `floor(budget × playerPower / totalPower)`, separately for PEPEFRONT and IMD. `claimable` and `prizeClaimable` include that matured share and previously accrued credits. Before then they exclude the current day's unsettled share. `claim()` transfers only PEPEFRONT to the caller; `claimPrize()` or action 9 transfers only IMD to the caller. There is no recipient argument. One unavailable token does not prevent claiming the other.

`accrue(player)` is permissionless bookkeeping: it moves a closed epoch share to that player's permanent credit without transferring funds. A rewarded victory in a later epoch also accrues the old one. Nobody can redirect another player's credit, and claims never expire. A caller with no positive entitlement receives `NothingToClaim`.

If an epoch closes with **zero total power**, each sponsor can call `refund(epoch)` for their own deposit, without owner involvement. `refundToken(epoch)` and `refundPrize(epoch)` recover the assets independently if one asset is unavailable. Cosmetic revenue and recycled dust have no refundable sponsor; `recycle(epoch)` carries them to tomorrow. For an epoch with power, recycling is possible only once all power has been accrued, and moves only division dust, never outstanding credits. Anyone can accrue participants found in events and recycle dust; no array of all players is traversed on-chain.

The core accounting invariants are:

```text
Game PEPEFRONT balance >= totalTokenLiability + retiredTokens
Game IMD balance      >= totalPrizeLiability
sum of all payouts for an epoch <= its funded budget
```

Donated tokens sent directly to Game are unaccounted surplus and cannot be recovered. Cosmetic retirement is permanent. The owner cannot withdraw deposits, prizes, accrued credits, retirement balances or arbitrary ERC-20s. The only recovery operation is for forcibly sent ETH, since all ordinary native transfers are rejected.

## After launch

There are **no mandatory owner-settable external services**: no signer, registry, VRF subscription, relayer authorization or oracle is needed to play or claim. No missing requester value has been replaced with an address placeholder.

1. The deployment service must use the two constructors above, verify runtime/source/ABIs, check the actual chain and IMD contract, and hand real addresses and the exact pool key to the frontend stage. Live token code/behavior must match the non-rebasing, exact-transfer asset assumption before funding.
2. The publishing relayer handles fee entitlement handoff to the approved trading receiver. Game does not make or authorize that handoff.
3. The creator or any willing sponsor obtains actual PEPEFRONT/IMD, approves a chosen exact deposit and calls `fund` for a future day. No constructor allocation or factory initialization funds Game. Without deposits or cosmetic revenue, games remain playable with zero rewards.
4. The frontend uses [INTERFACE.md](docs/INTERFACE.md), [RULES.md](docs/RULES.md) and [ABI exports](docs/abi/). It must display both token contract addresses, the unofficial status, current epoch/cooldown, the battle's `rewarded` flag, variable pro-rata rewards, exact approval costs and action confirmations. Native value maximum is `0`; the gameplay cosmetic approval maximum is `100000000000000000000` raw PEPEFRONT units.
5. Players claim their matured rewards. Sponsors recover empty-day contributions. Anyone may expire abandoned matches, accrue known players and recycle eligible residual budgets. None needs an operator key.
6. The creator can transfer ownership using the two-step process or renounce. Ownership only controls forced-ETH recovery. Renouncing leaves any future forcibly sent ETH unrecoverable, but gameplay, ERC-20 rewards and sponsor refunds remain available.

## Trust and review

Public deterministic rules can be automated and solved repeatedly. Wallet cooldowns are not Sybil resistance. Sponsors should assume optimal automated play can consume their entire daily budget. The game proves legal transitions, not human skill, real-time reflexes or fairness against bots.

Timestamp gates use chain time, not browser time or block-number guesses. Sequencer downtime can expire a battle; free entry means no player deposit is forfeited. Timestamps affect deadlines and daily accounting, never random outcomes. ERC-20 transfers use SafeERC20 and exact balance-delta checks; fee-on-transfer/rebasing assets are unsupported, and IMD's own availability/administration remains an external dependency.

See [SECURITY.md](docs/SECURITY.md) for local checks and limitations. The local tests and static analysis are not an independent audit. The assignment's independent source-and-manifest review remains a release responsibility, followed by deployment and frontend validation. No transactions were broadcast and no funded wallet was accessed.

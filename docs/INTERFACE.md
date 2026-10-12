# Contract and frontend ABI handoff

Generated exports are [Game.json](abi/Game.json) and [LaunchToken.json](abi/LaunchToken.json). Regenerate with `python3 scripts/export_abis.py`; check them with `python3 scripts/export_abis.py --check`. They contain complete constructors, functions, events and custom errors from the accepted Solidity implementation, not an invented frontend interface.

## Deployment arguments

Deploy `LaunchToken()` first, then `Game(address initialOwner, address token)` with `$owner` and `$token`. The ABI has two static address constructor parameters, no dynamic data or payable value. The explicit owner resolves to the approved creator; the deployer/factory must never be substituted as owner. `prizeToken()` is the fixed canonical Robinhood IMD address listed in the README. Libraries are internal and require no deployment.

Do not put a guessed deployed address in the website. The subsequent deployment handoff supplies the live Game/LaunchToken addresses, pool key, chain configuration and service ABI hashes. This folder is the implementation ABI source for that process; it is not a signed deployment receipt or manifest.

## Required public interface

| Method | Meaning |
| --- | --- |
| `owner() → address` | Creator's current ownership address; two-step transfer and renounce supported |
| `state(address player) → bytes` | Versioned encoding defined below |
| `act(bytes action)` payable | Player-bound order. Every call requires native value **0**. Nonzero value reverts. |
| `claimable(address player) → uint256` | Already funded, matured launch-token entitlement, in raw units |
| `claim()` | Send only the caller's positive launch-token entitlement to that caller |

The contract never accepts a player or recipient supplied inside an action. A host bridge must send the transaction from the connected player's wallet. Relaying from a different account plays as that different account. There is no trusted-forwarder, permit, signature or platform score authorization.

## Action encoding

Every action is exactly **128 bytes**:

```solidity
abi.encode(uint8 command, uint64 sessionId, uint8 expectedTurn, uint8 argument)
```

These are four ordinary 32-byte ABI words, **not** packed encoding or JSON. Narrow integers must have zero high-byte padding. No arrays, variable-length replay or arbitrary target call is accepted. Read the wallet's current battle immediately before preparing a transaction. A stale turn/session must be refreshed after a revert.

| Command | sessionId / expectedTurn | Argument | Readable confirmation |
| --- | --- | --- | --- |
| 0: Start | previous ID + 1 / 0 | `faction + 2 × difficulty`, 0–5 | “Start Initiative/Cult battle at difficulty N. Free entry; show whether the current conditions qualify for rewards.” |
| 1: Harvest | active ID / current turn | 0 | “Order Harvester Pepes to gather 30/35 ore. Enemy retaliates.” |
| 2: Build | active ID / current turn | next tech level, 1–4 | “Build power/barracks/factory/tech for 30/40/60/80 ore.” |
| 3: Produce | active ID / current turn | 0 Recruit, 1 Tank, 2 Commando | “Recruit the selected Pepe unit for the faction's ore price.” |
| 4: Attack | active ID / current turn | 0 | “Attack the enemy base with the current army.” |
| 5: Hold | active ID / current turn | 0 | “Hold the control point; three consecutive holds win.” |
| 6: Repair | active ID / current turn | 0 | “Spend 25 ore to repair up to 30 base HP.” |
| 7: Surrender | active ID / current turn | 0 | “End this battle with zero reward; another battle can start immediately.” |
| 8: Cosmetic | **0 / 0** | cosmetic ID 0–7 | “Spend exactly 100 PEPEFRONT for this wallet's cosmetic; 75 are permanently retired and 25 fund tomorrow's rewards.” |
| 9: IMD claim | **0 / 0** | **0** | “Claim this wallet's matured IMD prize to the same wallet.” |

All actions except cosmetics require no ERC-20 allowance. Cosmetic action 8 requires an exact `LaunchToken.approve(Game, 100000000000000000000)`. It cannot spend IMD. Avoid unlimited approvals. Cosmetic ownership is a bit mask: bit `id` means the wallet owns that cosmetic, and repeat purchases revert. Suggested frontend labels are cosmetic-only: Recruit pip, Engineer patch, Harvester glow, Tank chevron, Commando visor, Initiative banner, Cult banner and Veteran insignia. They do not increase power or combat strength.

For the host metadata/bridge, `maxActionValueWei` is `"0"` and `maxTokenApproval` is `"100000000000000000000"`. `claim` uses the dedicated bridge claim request; IMD claims use bridge `act` with command 9. Sponsor funding/empty-epoch refunds are operational methods for a separate funding interface; the core gameplay bridge does not request arbitrary calls or IMD approvals.

The minimum time gates can make an otherwise legal victory premature. Show `startedAt + 300` for earliest victory and the actual deadline; do not treat these as client-side authority. The call reverts without consuming the turn if the gate is not met. Do not auto-resend an uncertain or rejected transaction. Read confirmed state after each write.

## `state` encoding, version 1

The returned `bytes` value decodes as:

```solidity
abi.decode(data, (
    uint8,
    Battlefield.Battle,
    CommandPower.Account,
    Game.RewardAccount,
    uint256,
    uint256,
    uint256
));
// version, battle, command, rewards, cosmetics, claimableTokens, claimableIMD
```

All fields are static, in declaration order. The ABI's typed getters `battleOf`, `commandOf` and `rewardsOf` expose the same component definitions for clients. Use the types from the actual ABI rather than guessing integer widths.

`Battle` components, in order:

| Fields | Types | Meaning |
| --- | --- | --- |
| `id`, `startedAt`, `deadline`, `epoch` | four `uint64` | Wallet session, timestamps in seconds, funding day |
| `status` | `uint8` enum | 0 None, 1 Active, 2 Won, 3 Lost, 4 Expired, 5 Surrendered |
| `faction`, `difficulty`, `turn`, `tech` | four `uint8` | Current rules and expected next turn |
| `recruits`, `tanks`, `commandos`, `harvests`, `points` | five `uint8` | Units, session harvest count, consecutive holds |
| `ore`, `baseHP`, `enemyHP` | three `uint16` | Session resources and HP |
| `rewarded` | `bool` | Eligibility fixed at start; still requires a legal victory |

`CommandPower.Account` components: `(uint64 day, uint64 lastRewardAt, uint8 wins, uint8 harvests, bool rewardedBefore)`. Counters describe the last rewarded UTC day; if `day` differs from today's epoch the effective daily counters are zero. `lastRewardAt + 86400` is the cooldown boundary when `rewardedBefore` is true.

`RewardAccount` components: `(uint64 epoch, uint256 power, uint256 tokens, uint256 prizes)`. `power` is not yet accrued power for that epoch; `tokens`/`prizes` are permanent already accrued credits. `claimableTokens`/`claimableIMD` additionally include a matured, unaccrued share. Do not add those account fields to `claimable` again.

The last three `uint256` values are the cosmetics mask, total currently claimable PEPEFRONT units and total currently claimable IMD units. A never-played wallet has the default zero state.

## Other methods and events

| Method | Access and behavior |
| --- | --- |
| `rewardAvailable(player)` | Preview start-time funding/cooldown/day-boundary eligibility; excludes active-session checks and may change before confirmation |
| `prizeClaimable(player)` / `claimPrize()` | Matured IMD counterpart to the required token claim methods |
| `fund(uint64 epoch, uint128 tokens, uint128 prizes)` | Sponsor's own tokens; approve each supplied asset separately; next 1–30 UTC days only |
| `contributions(epoch, sponsor)` | Recorded refundable source contribution amounts; refund requires zero total power after close |
| `epochs(epoch)` | Token/prize budgets, recycled/cosmetic revenues, total/credited power, allocated token/prize totals |
| `refund(uint64 epoch)` | Only caller's empty-day contribution, paid back to caller |
| `refundToken(uint64 epoch)` / `refundPrize(uint64 epoch)` | Independently recover the caller's token/IMD contribution; the other asset stays refundable |
| `accrue(address player)` | Anyone may fix a matured pro-rata share into that same player's credits |
| `recycle(uint64 epoch)` | Anyone may carry eligible revenue/dust into tomorrow, without transferring to any wallet |
| `expire(address player, uint64 id)` | Anyone, at/after deadline; checks exact active session ID; no payout |
| `recoverForcedEther()` | Only owner; recovers forcibly sent native currency to current owner; zero balance is a no-op with event |
| `transferOwnership`, `acceptOwnership`, `renounceOwnership` | OpenZeppelin Ownable2Step. No gameplay or fund-withdrawal authority is conveyed. |

`epochs` getter component order is `(tokenBudget, prizeBudget, tokenRevenue, prizeRevenue, totalPower, creditedPower, tokenAllocated, prizeAllocated)`, all `uint256`. After a refund or permitted recycling, budgets shrink by the released/reassigned amount; the events preserve the full history. A funded epoch's terms cannot change while it accepts power.

`BattleStarted` records player/session/day/selection/eligibility. `Move` records the zero-based turn executed and its command/argument. `BattleFinished` records a terminal result and power actually awarded (zero for unqualified or unsuccessful sessions). `RewardsAccrued` records the player's final epoch share, and `Claimed.asset` is 0 PEPEFRONT or 1 IMD. `Funded`, `Refunded`, `Recycled`, `CosmeticBought`, ownership events and `ForcedEtherRecovered` cover the other operations.

Events support a local/browser or third-party leaderboard without granting that indexer settlement powers. Indexing events is optional for an individual wallet's state and claim. A frontend can reconstruct daily scores from `BattleFinished` and the corresponding `BattleStarted` epoch. There is no on-chain enumeration of every player and no trusted global leaderboard.

## Errors and recovery

Invalid action encoding/arguments reverts (`InvalidAction` or ABI decoding failure). Game-state errors include `MatchActive`, `NotActive`, `WrongSession`, `WrongTurn`, `TooEarly`, `DeadlinePassed`, `InsufficientOre`, `PrerequisiteMissing`, `ArmyFull`, `InvalidMove`, and `NotExpired`. Refresh state and show the exact rule; funds are not charged by a reverted action.

Funding/settlement errors include `InvalidEpoch`, `InvalidAmount`, `EpochNotClosed`, `NoRefund` and `NothingToClaim`. `AlreadyOwned` rejects repeat cosmetic spending. `NativeValueNotAccepted` means the UI attached ETH to an action that requires zero. `AssetUnavailable` means the configured asset has no code on the current chain. Token transfer failures or `InexactTransfer` roll back both credits and movements, so an existing entitlement remains retryable if the external asset recovers.

Never display an open epoch's estimated share as guaranteed or immediately claimable. Show the epoch end, the wallet's power, current total power, deposited budget and the actual claimable methods separately. Check chain ID 4663 and display the real LaunchToken and IMD addresses from deployment/configuration.

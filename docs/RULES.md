# Battle rules, version 1

The authoritative implementation is `src/lib/Battlefield.sol`, inlined into `Game`.

Each wallet has one current session. Start uses the next sequential `uint64` session ID; an active session cannot be overwritten. A new completed session reuses the wallet's storage while events retain its history. None, Active, Won, Lost, Expired and Surrendered are status codes 0 through 5.

A session lasts at most 20 minutes and at most 48 completed strategic turns. A move with current turn `t` is eligible at `startedAt + (t + 1) × 10 seconds`. This is a schedule from start, not ten seconds after the previous transaction: a player can submit several pending orders later. A victory cannot complete before five minutes from start. At the exact deadline moves are rejected and permissionless expiry succeeds. Surrender is possible before the deadline without waiting for a turn slot.

Each legal move increments the turn. Surrender sets status directly without consuming a turn. Invalid orders and premature victories revert the entire transaction, including points, damage, ore and turn count. Losing on turn 48 applies only if that turn did not win. Winning ends the battle before enemy retaliation. Other successful moves receive one deterministic enemy retaliation. Every transaction has bounded work and storage access.

## Factions and difficulty

Start selection is `faction + 2 × difficulty`: faction 0 Initiative or 1 Cult, and difficulty 0, 1 or 2. All six choices are immediately available. Difficulty increases hostile base health and retaliation; it does not require an owner or score unlock.

| Attribute | Initiative Pepes | Cult Pepes |
| --- | --- | --- |
| Initial and maximum base HP | 200 | 160 |
| Initial ore | 100 | 100 |
| Ore per harvest order | 30 | 35 |
| Fixed base defense | 3 | 1 |
| Additional unit production cost | +5 ore per unit | None |

Enemy starting HP is `120 + 60 × difficulty`. The factions' engine effects express tougher defense versus cheaper/faster economy; cosmetic stealth effects do not change the on-chain rules. All troops are Pepes, and the map/animations may depict the persistent harvest and engineering work between orders.

## Economy and army

Buildings must be constructed once, in this order:

| New tech level | Structure | Ore |
| --- | --- | --- |
| 1 | Power plant | 30 |
| 2 | Barracks | 40 |
| 3 | Factory | 60 |
| 4 | Tech center | 80 |

There is one abstract Harvester Pepe operation from the start. Harvest adds the faction's ore yield and records one harvest action. The ore is session-local and has no token redemption value. An Engineer Pepe repair order costs 25 ore and adds 30 HP, capped at the faction maximum; a repair at full HP is rejected. Enemy retaliation still follows the repair.

| Production argument | Unit | Required tech | Base ore cost | Strength | Defense |
| --- | --- | --- | --- | --- | --- |
| 0 | Recruit Pepe | 2 | 20 | 8 | 1 |
| 1 | Tank Pepe | 3 | 45 | 20 | 2 |
| 2 | Commando Pepe | 4 | 60 | 32 | 1 |

Initiative pays five extra ore per unit. At most twelve units can be produced in a session. Units contribute persistent strength/defense and are not individually killed; retaliation targets the base. There is no minting or token-funded combat advantage.

## Battle resolution

Attack damage is `armyStrength - 3 × difficulty`; an army with no positive damage cannot attack. Damage reduces hostile base HP to a minimum of zero. Destroying the enemy base wins.

Holding a point requires strength at least `12 + 8 × difficulty`. Three consecutive Hold orders win. Any other ordinary order resets the consecutive point count. Invalid/reverted orders do not change it.

After each non-winning ordinary move:

```text
defense = factionBaseDefense + recruits + 2 × tanks + commandos
incoming = 5 + 2 × difficulty + floor(updatedTurn / 6)
baseDamage = max(incoming - defense, 0)
```

Zero base HP or exhausting turn 48 without winning loses. After win/loss/surrender/expiry, all further moves for that session are rejected. A new session resets ore, army, tech, HP, points and timestamps. Command power, cooldowns, accrued rewards and cosmetic ownership persist separately.

Rewarded sessions are fixed at start using the wallet cooldown, daily funding and deadline rules in the README. Harvesting alone never earns a claim. Only a legal rewarded victory adds daily power. A UI should show “practice: zero rewards” whenever the stored `rewarded` flag is false.

## Reproducible basic strategy

For difficulty 0 with Initiative: build power, build barracks, harvest, recruit twice, hold twice, then wait until the five-minute gate and hold once more. Each transaction must use the current turn. This is intentionally a public solution, not a secret or anti-bot mechanism. Tests also demonstrate Cult, higher difficulties, factory/tech progression, repairs and base-destruction victories. Deposited budgets, rather than solution secrecy, bound rewards.

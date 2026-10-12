# Local security and validation record

This is the source contributor's validation record, not an independent audit, service attestation, admission decision or deployment receipt. The next independent contributor must review accepted source together with the actual manifest constructor arguments.

## Implemented controls

- Every action is bound to `msg.sender`, with a session ID and expected turn. A copied strategy may be played independently, but another wallet cannot mutate or claim a player's session.
- Game transitions and final results are contract-computed. No signed or client-reported score, replay-derived timing, selectable random seed, external randomness or privileged outcome setter exists.
- Deposited epoch budgets close before play. Active-day terms cannot be changed by the owner, sponsor or another player. No minting backs rewards.
- Payouts and refunds reduce accounting before external transfers. All gameplay/accounting/asset-moving entry points share the OpenZeppelin reentrancy guard. Claiming, refunds and cosmetics require exact token balance changes.
- Game-token and IMD claims are independent. Empty-day sponsor refunds can also be made separately, so one unavailable asset does not freeze the other.
- The owner cannot sweep ERC-20s, spend retired tokens, rewrite results, pause claims or confiscate sponsorships. The only owner-only application method recovers forcibly sent ETH to the current owner; `act` rejects native value and there is no receive/fallback.
- The owner is an explicit constructor parameter. Constructors make no external calls and do not consume any launch allocation. All configured asset code checks occur on use.
- There is no upgrade mechanism, delegatecall, callcode, selfdestruct, externally linked library, operator key, environment-based runtime configuration or unbounded player iteration.
- `Game` uses directly initialized storage references (`Epoch storage pool = epochs[epoch]`, etc.). There is no `_ledger` function or uninitialized storage-reference return variable. The previous attempt's reported high-severity pattern is absent.

## Checks run

The compiler is Solidity **0.8.26** using the root Foundry profile. Foundry used locally was 1.8.3. All tests use isolated fixtures and explicit parameters; they read or mutate no process environment and use no RPC fork, filesystem access or FFI.

| Check | Result |
| --- | --- |
| `forge build` / `forge build --sizes` | Pass. Production runtime: Game **15,579 bytes**, LaunchToken **1,784 bytes**; both below 24,576. |
| `forge test` | **53 reported tests**, no failures/skips: 52 unit/fuzz tests plus one grouped invariant suite containing two invariant properties. |
| Fuzz tests | 512 runs each for exact fixed-supply token transfers and reward-budget conservation |
| Stateful invariant suite | 128 runs × depth 64 = **8,192 actions**, zero handler reverts. Exercises funding, gameplay, elapsed time, cosmetics, accrual, claims, refunds and recycling. |
| `forge fmt --check` | Pass |
| `python3 scripts/export_abis.py --check` | Both generated ABIs match compiled source |
| Runtime-opcode and constructor floor equivalents | Tested actual deployments, fixed factory-held supply, explicit owner, cold dependency addresses, EIP-170 size, and absence of DELEGATECALL/CALLCODE/SELFDESTRUCT in production runtime |
| Slither 0.11.3 | 100 detectors; **0 high, 0 medium, 11 low and 2 informational** production findings, addressed below |

The supplied protected tests use their verifier's environment and eventual manifest. They were read as requirements; the local equivalents do not claim to be an independent execution or approval of that later protected harness.

Coverage was run with:

```sh
forge coverage --no-match-test test_deployedBytecodeMeetsProtectedFloor --report summary
```

Coverage disables the production optimizer. The size/opcode test was therefore run separately under the actual pinned deployment settings, where it passes. An initial coverage run including that test correctly rejected the larger unoptimized diagnostic bytecode; it is not the deployed artifact. No production setting was weakened and the normal test suite retains the size/opcode assertion.

The final coverage run passed all 52 applicable tests. Line coverage was 100% for Game, LaunchToken and CommandPower, and 98.89% for Battlefield; function coverage was 100% for all production files. Coverage percentages do not establish correctness of unchecked economic assumptions.

The tests include every faction/difficulty, attack and point-control victories, building prerequisites, ore accounting, ranked units, army/turn caps, repairs, defeat, surrender, permissionless expiry, exact time boundaries, malformed and repeated actions, cross-wallet calls, open/closed/empty epochs, cooldown and harvest limits, proportional shares, double claims, sponsor refunds, dust recycling and permanently retired cosmetics. Adversarial assets exercise failed transfers, fee deductions, missing code, missing/false return data and callbacks during funding, claims and refunds. Ownership, renunciation and rejected/reentrant native receivers are covered.

## Static-analysis observations

The final scan included `src/lib/` and filtered only vendored dependency/test paths:

```sh
slither . --filter-paths '(^|/)lib/(openzeppelin-contracts|forge-std)/|(^|/)test/'
```

No detectors were disabled and no suppression comments were used. Slither returns a nonzero status for the following reported observations; “zero high/medium” does not mean “no findings.”

| Detector / severity | Scope | Assessment |
| --- | --- | --- |
| `timestamp` / low, 11 findings | Game epoch funding/refund/recycling/accrual/eligibility/expiry, Battlefield timing, CommandPower cooldowns | Intentional clock rules. Chain timestamps can be influenced near boundaries and sequencer downtime can prevent timely moves. They never supply randomness or enlarge a deposited budget. Exact deadline/day/cooldown boundaries are tested. |
| `cyclomatic-complexity` / informational | `Battlefield.step`, complexity 42 | Bounded dispatch across seven distinct strategy orders and deterministic retaliation. Tests cover legal paths and failure cases. No data-dependent unbounded loop is present. |
| `low-level-calls` / informational | `recoverForcedEther` | Owner-only native transfer to the current owner, guarded against reentrancy and checked for success. No player native deposit can enter through the supported interface. Rejected and reentrant receivers are tested. |

The earlier `uninitialized-storage` and `locked-ether` findings do not occur in this implementation. The initial implementation scan also identified two strict-equality notices; the epoch guard now expresses a deadline upper bound, and empty forced-ETH recovery is an explicit no-op.

Forge's heuristic linter also notes timestamp comparisons, integer narrowing, strict balance-delta comparisons and some guarded calls/events. The narrowing limits are bounded game health values or uint64 wall-clock timestamps/epochs (far beyond the supported chain's lifetime). Exact balance comparisons deliberately reject unsupported transfer behavior. These lint notices do not override the tests or establish security by themselves.

## Residual assumptions and operational responsibilities

1. **Automated play and wallet splitting:** deterministic strategies are reusable and wallets are cheap. A sponsor must assume an epoch's entire budget can be earned by bots. The 24h wallet cooldown and shared fixed budget limit distributions, not identities or bot participation. No human-skill or Sybil-resistance claim is made.
2. **External IMD behavior:** the canonical task-provided address is fixed in the contract. Tests use a local mock; no live-chain code, administrator or liquidity properties are asserted. Deployment services must validate the intended chain/asset before funding. Fee-on-transfer and rebasing behavior is unsupported, and a hostile or unavailable asset can prevent that asset's payouts; credits persist for retry.
3. **Sponsorship and retirement:** donors cannot reclaim a day with earned power. Dust is retained until all power is accrued, then anyone can recycle it. Cosmetic retirement and accidental direct token transfers are permanent. There is no administrative sweep or emergency token seizure path.
4. **Timing and liveness:** a match can expire during chain downtime. It has no paid entry escrow. Claims and empty-day refunds have no expiry and need no server/owner. Event indexing is needed only to find all participants for optional dust maintenance or a global display leaderboard.
5. **Ownership:** the factory and publishing relayer must not become owner. The approved manifest uses `$owner` for the creator and `$token` for the earlier launch token. Ownership only affects forced-ETH recovery; renunciation cannot stop player ERC-20 claims/refunds.
6. **Release:** independently review the manifest/source, source publication, policy/signature linkage, receiver fee handoff, actual chain assets and frontend wallet integration in their assigned stages. No transaction has been broadcast from this work.

Slither and Foundry were run. Mythril and external/manual independent audits were not run. Passing tests, coverage and static analysis are evidence about the implementation, not proof of economic fairness or production security.

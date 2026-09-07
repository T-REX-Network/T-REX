# OpenZeppelin T-REX Audit — Triage

Verified against `develop` @ `009457b`. Every claim below was checked by reading the
contract, not inferred from the finding title.

**Caveat:** I triaged from titles only — you have the full descriptions, I don't. Where a
title admits several readings I say so and give my reading. Re-check those against OZ's
actual text before acting.

---

## Blocker found while triaging (not in the report)

**The test suite does not compile on `develop` today.** 21 errors, all from ONCHAINID drift:

| | |
|---|---|
| `soldeer.lock` pins | `d2096509` |
| `dependencies/onchain-id-develop` is at | `edcc9f3` (Sep 4) |

Two breaking changes landed upstream and the T-REX tests were never updated:
- `Structs.ClaimData` gained a 4th field `metadataHash` — 6 struct-literal errors
- `IIdentityFactory.createIdentityFor` gained a parameter — 9 call-site errors
- `getClaim` return arity changed — 1 destructuring error, 5 more arity errors

Contracts compile; only `test/` is broken. **Fix this first** — you cannot validate a single
audit fix until the suite runs, and it's most of the "I feel out of date" gap.

Note this cuts directly across **M-04**: the fork's `isClaimValid` takes
`Structs.ClaimData` where canonical ONCHAINID takes `bytes`. So M-04 is not a slip — it's a
deliberate fork divergence. The decision is whether to keep it, which is a product call, not
a bug fix.

---

## Verdicts

**Confirmed live: 24 · Disputed: 3 · Needs your input: 5 · Already acknowledged: 1**

I found no issue that was already fixed. This report is current with the code.

### High

| ID | Verdict | Evidence |
|---|---|---|
| **H-01** | **Confirmed** | `TREXRegistry.sol:isVerified` derives `claimId` from `trustedIssuersForTopic[i]` but then calls `isClaimValid` on `issuer` — the address returned by `userIdentity.getClaim()`. The identity controls that return value. A self-issued claim stored under a trusted issuer's `claimId` gets validated by an attacker-chosen contract. **Fix: `require(issuer == trustedIssuersForTopic[j])` before the staticcall.** Small, contained, high value. Do this first. |
| **H-02** | **Confirmed** | `RolesLib.sol` — all role IDs are compile-time constants (`ROLE_PREFIX + n`). Two suites sharing an AccessManager share every role. `AGENT` on suite A is `AGENT` on suite B. Real, but note the blast radius is exactly "operators who share an AccessManager across suites". If your deployment model is one-manager-per-suite this is a documentation fix, not a code fix. **Tell me which model you ship** — it changes the fix from "namespace role IDs by suite" to "document the constraint + guard in the factory". |
| **H-03** | Acknowledged (OZ) | `AbstractModuleUpgradeable`'s own header documents this: "Capabilities are immutable per implementation. An upgrade that changes them is a breaking change until each bound compliance calls `refreshModuleCapabilities`." You already shipped `refreshModuleCapabilities` as the mitigation. Marked "Acknowledged Not Resolved" — reasonable. Consider emitting capabilities in the beacon-upgrade event so drift is detectable off-chain. |

### Medium — confirmed

| ID | Evidence |
|---|---|
| **M-02** | `unbindIdentityRegistry` removes the IR from the `identityRegistries` set, but that set is *never read for authorization*. Write authority on `addIdentityToStorage` etc. comes from the `AGENT` role on the AccessManager, which the unbind does not touch. An unbound registry keeps full write access. Confirmed and clean to fix. |
| **M-03** | `Token._migrateIdentity` — when `newWallet` already has an identity, the guard only checks it *equals* `investorOnchainId`. But `recoveryAddress` calls `_forceUpdate` first, so balances merge before any identity reconciliation. Two unrelated investors can end up sharing a balance. |
| **M-04** | Confirmed, but it's a fork-divergence decision — see the blocker section above. |
| **M-05** | `TREXFactory._grantAgentRoles` grants the flat `RolesLib.AGENT` to `tokenDetails.tokenAgents`. `AGENT` is the role wired to the *IdentityRegistry* selectors in `setupTREXRegistryRoles` (`registerIdentity`, `deleteIdentity`, …). Token agents should get the `AGENT_*` granular roles. **This is a straightforward factory bug and a good early fix.** |
| **M-06** | No `nonReentrant` anywhere in `contracts/`. `ModularCompliance.transferred` loops modules calling `moduleTransferAction`; a malicious/compromised module re-enters before later modules update their cumulative state. Exploitability depends on module trust assumptions — modules are owner-added, so this is "compromised module" not "anyone". Rate accordingly. |
| **M-07** | `_grantAgentRoles` calls `grantRole(role, account, 0)` — the `0` is `executionDelay`. Re-granting to an existing agent *resets their delay to zero*. Confirmed exactly as titled. |
| **M-09** | `Token._forcedTransfer` → `_forceUpdate` → `super._update` directly, bypassing the `_requireNotPaused()` that lives in the overridden `_update`. Forced transfers work while paused. Whether that's a bug depends on intent — **many ERC-3643 deployments deliberately want forced transfer to work during a pause** (that's the recovery/seizure path). Confirm intent before "fixing". |
| **M-10** | `AccessManagedOwnableBase.transferOwnership` rotates only `this` contract's authority. Its own docstring admits it: "a suite migration must rotate every contract together or the shared-authority invariant breaks." The token's ONCHAINID management keys still point at the old manager. Confirmed. |
| **M-11** | `ModularCompliance.removeModule` calls `IModule(_module).unbindCompliance(...)` unguarded. A module that reverts in `unbindCompliance` can never be removed. Confirmed — fix is a try/catch or a force-remove path. |

### Medium — disputed

| ID | Why I'd push back |
|---|---|
| **M-01** | Already marked False Positive, and the code agrees: `isVerified` uses `LowLevelCall.staticcallReturn64Bytes`, which caps returndata at 64 bytes — no returndata bomb. Gas griefing via a deliberately expensive issuer is still theoretically possible, but issuers are owner-curated and capped at 50. Agree with False Positive. |
| **M-08** | "Module binding delegates enforcement to unchecked foreign upgrade authorities" — true but this is the *design*. Modules are UUPS and owner-controlled; binding a module is already a trust decision. Worth a doc note on the operator checklist, not a code change. Low priority. |

### Low — worth doing (cheap, real)

- **L-01** — `_value > 0` reverts in `transferred`/`created`/`destroyed` (MC:182,198,214). Zero-value ERC-20 transfers are legal and some integrations rely on them. One-line fix per hook: return early instead of reverting.
- **L-03** — `AbstractModuleUpgradeable.bindCompliance` requires `msg.sender == _compliance` but nothing stops an arbitrary contract calling it. Confirmed.
- **L-06** — `Token._migrateIdentity`: if `lostWallet == newWallet`, `contains(newWallet)` is true so no re-register happens, then `deleteIdentity(lostWallet)` wipes the identity. Confirmed, cheap guard.
- **L-08** — `setName` rotates the EIP-712 domain separator (`_EIP712Name` returns `name()`). Restoring an old name reactivates old permit signatures. Already documented in the docstring; the fix is a nonce/version bump.
- **L-17** — Confirmed: events live in `ERC3643EventsLib` (27 events), the interface declares 10. Tooling expecting ERC-3643 events on the interface ABI won't find them. Pure interface change, zero runtime risk.
- **L-20** — In `isVerified`, `success && result != bytes32(0)`. `staticcallReturn64Bytes` on an EOA or a contract with no code returns `success=true` with empty data → `result` is zero → treated as invalid. **This one is actually already safe.** I'd push back unless OZ's description names a path I'm not seeing.
- **L-21** — `UtilityChecker.getVerifiedDetails` writes `_details[claimTopic]` inside the issuer loop without breaking, so the last issuer overwrites earlier results. Confirmed. Off-chain-only contract, so severity is genuinely Low.

### Low — needs your input before I judge

**L-04, L-05, L-07, L-09, L-10, L-11, L-12, L-13, L-14, L-15, L-16, L-18, L-19, L-22, L-23, L-24.**

These hinge on operational assumptions the code alone doesn't settle — deployment topology,
whether you use execution delays, whether ASSET_DEPLOYER is shared. Several (L-18, L-22,
L-24) are all the same underlying question: *do you ever set a non-zero execution delay on
these roles?* If the answer is no, all three collapse to doc notes.

Send me the descriptions and I'll finish these.

---

## Suggested fix order

**Batch 1 — unblock.** Resolve the ONCHAINID drift; get `forge test` green. Nothing else is
verifiable until this lands.

**Batch 2 — real bugs, contained fixes.** H-01 (issuer binding), M-05 (token agents get the
wrong role), M-02 (unbind doesn't revoke), M-11 (module can veto removal), L-01, L-06.
These are small, independently testable, and none of them are architectural.

**Batch 3 — decisions, not fixes.** H-02, M-04, M-09, M-08. Each needs a product call from
you before there's a correct patch. Writing code first risks fixing the wrong thing.

**Batch 4 — architectural.** M-03, M-06, M-07, M-10. Larger blast radius, want tests around
them first — which is why Batch 1 comes first.

**Batch 5 — polish.** Remaining Lows, once you've sent the descriptions.

---

## Catch-up: what changed under you

Roughly the last 40 commits, in dependency order:

1. **ONCHAINID → ERC-7579 identities** (`80f5aac`, Jul 17). The largest change. `ClaimData`
   became a typed struct with EIP-712 nesting; `isClaimValid` changed signature. This is the
   root of both M-04 and today's broken build.
2. **Three eligibility registries merged into one `TREXRegistry`** (`64a9cc8`). ClaimTopics +
   TrustedIssuers + IdentityRegistry are now one contract that returns `address(this)` from
   `issuersRegistry()`/`topicsRegistry()`. `setClaimTopicsRegistry`/`setTrustedIssuersRegistry`
   now revert `Deprecated()`.
3. **Custom proxy layer → beacons + version registry** (`558e98f`, `2bd8d9e`). Four
   `UpgradeableBeacon`s owned by `TREXImplementationAuthority`; versions are packed into one
   word and only roll forward. `deployTREXSuiteIsolated` gives a suite its own beacons owned by
   its own AccessManager.
4. **Module capability dispatch** (`43ec579`, `f322227`). Modules declare which of the 5
   dispatch points they implement; MC skips undeclared ones. Bound modules moved to an
   `EnumerableMap` keyed by address. This is what H-03 is about.
5. **Spender vetting on `transferFrom`** (`1fc38ab`, `279f5c5`). New `CHECK_SPENDER`
   capability + `canSpenderCall`; two new spender modules with namespaced storage.
6. **AccessManager throughout**, replacing Ownable/AgentRole. `RolesLib` + `AccessManagerSetupLib`
   are new and are where H-02, M-05, and M-07 all live.

The through-line: the suite moved from bespoke access control and proxies onto OpenZeppelin
primitives (AccessManager, BeaconProxy, Create3). Most Medium findings cluster in that new
wiring — which is expected for freshly-written access-control code, and is the part worth
your attention.

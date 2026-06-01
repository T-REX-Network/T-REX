# Certora Formal Verification — T-REX

Formal-verification scaffold for the security-critical T-REX v5 contracts. The specs encode the same
properties exercised by the Foundry fuzz/invariant suite and the manual review, but prove them over **all**
inputs rather than sampled ones.

> **Status: authored, not yet run.** `certora-cli` is not installed in this environment and no `CERTORAKEY`
> is configured, so these specs have **not** been executed here. They are written to be runnable as-is once
> the prover is available (CI or a developer machine with a key). Treat the rule list below as *claims to be
> discharged*, not as verified results, until a prover run is attached.

## Layout

```
certora/
├── confs/        # one runnable conf per contract (certoraRun entry points)
├── specs/        # CVL rules & invariants
└── harnesses/    # thin Solidity harnesses exposing ERC-7201 namespaced state to CVL
```

| Contract | Conf | Spec | Harness |
|----------|------|------|---------|
| `Token` | `confs/Token.conf` | `specs/Token.spec` | `harnesses/TokenHarness.sol` |
| `ModularCompliance` | `confs/ModularCompliance.conf` | `specs/ModularCompliance.spec` | `harnesses/ModularComplianceHarness.sol` |
| `IdentityRegistry` | `confs/IdentityRegistry.conf` | `specs/IdentityRegistry.spec` | `harnesses/IdentityRegistryHarness.sol` |

## Properties

**Token** (`Token.spec`)
- `mintIncreasesSupplyAndBalance`, `burnDecreasesSupplyAndBalance`, `transferPreservesTotalSupply` — supply
  conservation (mirrors invariant INV-1/INV-2).
- `frozenNeverExceedsBalance` — the INV-3 safety invariant: frozen ≤ balance, so free balance ≥ 0.
- `freezeCannotExceedBalance`, `unfreezeCannotExceedFrozen` — freeze arithmetic has no silent clamp.
- `pausedBlocksTransfer`, `frozenAddressCannotTransfer`, `transferCannotSpendFrozen` — the `_update` gates.
- `restrictedMethodsRequireAuthorisation` — the AccessManager `restricted` gate (AV-1 / AV-6).

**ModularCompliance** (`ModularCompliance.spec`)
- `moduleSetBounded` — module set capped at 25 (MC-1).
- `onlyBoundedTokenNotifies{Transfer,Created,Destroyed}` — hooks callable only by the bound token (MC-2).
- `restrictedAdminRequiresAuthorisation`, `bindTokenAccessControl` — access control (MC-3/MC-4, AV-1).

**IdentityRegistry** (`IdentityRegistry.spec`)
- `disabledChecksImplyVerified` — `checksDisabled ⇒ isVerified` (AV-5).
- `disableRequiresEnabled`, `enableRequiresDisabled` — the eligibility toggle is well-formed (IR-2).
- `restrictedAdminRequiresAuthorisation` — access control (IR-3, AV-1).

## Modelling assumptions

- **External dependencies are summarised.** Calls a contract makes into *other* audited contracts
  (`IdentityRegistry.isVerified`, `ModularCompliance.canTransfer`, the `IModule` callbacks, the downstream
  registries) are summarised permissively so each spec isolates the contract under test. Those gates are
  proved on their own contracts and exercised end-to-end by the Foundry invariant suite (INV-5/INV-6).
- **AccessManager is ghost-modelled.** `authority().canCall(...)` / `hasRole(...)` are summarised with a
  ghost, so the access-control rules assert "deny ⇒ revert" without instantiating a full `AccessManager`.
  This assumes the standard OZ AccessManaged gate with **`executionDelay == 0`**, which matches the suite's
  deployment model (see `../SECURITY-ANALYSIS.md` AV-6). Verifying the delayed-grant path is future work.
- **ERC-7201 namespaced storage** is reached through the thin harnesses (`frozenAmount`, `moduleCount`,
  `checksDisabled`, …); no production logic is overridden.

## Running

1. Install the prover and set a key:
   ```bash
   pip install certora-cli            # provides certoraRun
   export CERTORAKEY=<your key>
   solc-select install 0.8.33         # or ensure `solc8.33` is on PATH (it is, in this repo's setup)
   ```
2. From the **repository root** (imports resolve `contracts/…` relative to it):
   ```bash
   certoraRun certora/confs/Token.conf
   certoraRun certora/confs/ModularCompliance.conf
   certoraRun certora/confs/IdentityRegistry.conf
   ```
3. Each run prints a verification report URL. Expect first-run tuning of `loop_iter` / summaries; record the
   discharged rules and any counterexamples back into `../SECURITY-ANALYSIS.md`.

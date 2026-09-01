# Certora Formal Verification — T-REX

Formal-verification scaffold for the security-critical T-REX v5 contracts. The specs encode the same
properties exercised by the Foundry fuzz/invariant suite and the manual review, but prove them over **all**
inputs rather than sampled ones.

> **Status: adapted to this branch; harnesses compile, prover not yet run here.** The three harnesses compile
> cleanly under `solc 0.8.30` (this branch's pinned compiler). The CVL specs were re-pointed at this branch's
> contract surface — the removed ERC-2771 / default-allowance entry points and the renamed AccessManager roles
> are no longer referenced (see "Adaptations" below). A full prover run was **not** completed in this
> environment: the available `CERTORAKEY` was rejected by the Certora cloud (`Invalid key or key is missing`),
> so the rule verdicts below remain *claims to be discharged*, not verified results, until a run with a valid
> key is attached. The repo's bundled `certora-cli` (7.28.0) is also older than the current server (8.16.1);
> use a matching CLI when running.

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

## Adaptations from the upstream draft

This branch diverged from the spec's original target. The following were changed when porting:

- **ERC-2771 removed.** `TokenHarness.trustedForwarderAddress()` was dropped, the `sane()` meta-tx `require`
  was removed (`_msgSender() == msg.sender` holds unconditionally now), and `setTrustedForwarder` was removed
  from the Token access-control selector set.
- **Default-allowance removed.** `setAllowanceForAll` was removed from the Token access-control selector set.
- **Compiler / package pins.** Confs use `solc8.30` (was `solc8.33`) and `@forge-std=…forge-std-1.16.1/src`
  (was `1.12.0`).
- ModularCompliance and IdentityRegistry harnesses/specs needed no surface changes — every referenced function,
  selector, the module cap (`< 25`), and the IR `checksDisabled` ERC-7201 slot/offset were verified against the
  current contracts.

## Modelling assumptions

- **External dependencies are summarised.** Calls a contract makes into *other* audited contracts
  (`IdentityRegistry.isVerified`, `ModularCompliance.canTransfer`, the `IModule` callbacks, the downstream
  registries) are summarised permissively so each spec isolates the contract under test. Those gates are
  proved on their own contracts and exercised end-to-end by the Foundry invariant suite (INV-5/INV-6).
  `IModule.moduleCapabilities` is summarised as every defined bit (31) and `moduleCheckSpender` as `true`,
  so modules always bind and no dispatch point is skipped. Capability routing is covered by the Foundry
  dispatch suite instead.
- **AccessManager is ghost-modelled.** `authority().canCall(...)` / `hasRole(...)` are summarised with a
  ghost, so the access-control rules assert "deny ⇒ revert" without instantiating a full `AccessManager`.
  This assumes the standard OZ AccessManaged gate with **`executionDelay == 0`**, which matches the suite's
  deployment model. Verifying the delayed-grant path is future work.
- **ERC-7201 namespaced storage** is reached through the thin harnesses (`frozenAmount`, `moduleCount`,
  `checksDisabled`, …); no production logic is overridden.

## Running

1. Install a matching prover CLI and set a valid key:
   ```bash
   pip install certora-cli            # use a version matching the current Certora server
   export CERTORAKEY=<your valid key>
   solc-select install 0.8.30         # the compiler this branch pins
   # certoraRun resolves the conf "solc" field as an executable name; expose 0.8.30 as `solc8.30`:
   ln -sf "$HOME/.solc-select/artifacts/solc-0.8.30/solc-0.8.30" "$HOME/.local/bin/solc8.30"
   ```
2. From the **repository root** (imports resolve `contracts/…` relative to it), via the wrapper which blocks
   for results and writes a greppable summary under `.audit-cache/`:
   ```bash
   certora/run.sh Token
   certora/run.sh ModularCompliance
   certora/run.sh IdentityRegistry
   ```
   or directly: `certoraRun certora/confs/Token.conf`.
3. Each run prints a verification report URL. Expect first-run tuning of `loop_iter` / summaries; record the
   discharged rules and any counterexamples.

# Swapping the ERC-3643 bases for OpenZeppelin's

This is the procedure for replacing the local standard bases in `contracts/ERC-3643/base/` with
OpenZeppelin's implementation once it ships, and the record of what that swap will cost. It is part of
the deliverable of issue #65.

## The layering in one paragraph

`contracts/ERC-3643/` holds the standard interfaces and, under `base/`, one abstract contract per
interface implementing exactly that interface over its own ERC-7201 namespace. The T-REX contracts
inherit those bases and add everything T-REX-specific through internal virtual hooks. No base refers to
anything in the T-REX layer; no extension writes a base namespace directly.

The one exception to "extensions never change a standard function's semantics": `TREXRegistry` reverts
the inherited `setClaimTopicsRegistry` and `setTrustedIssuersRegistry` with `Deprecated`, because it is
its own topics and issuers registry and there is nothing for either setter to point at. Both reverted
before the split too. Splitting the registries apart would restore the base implementations unchanged.

## Procedure

1. Replace the layer-2 import in the T-REX contract with OpenZeppelin's base.
2. Recompile. The compiler reports every hook whose name or signature moved.
3. Run `forge test --match-path "test/standard/*"` against the new base. This suite exercises the
   standard surface only, so it is the regression net that turns the swap into a diff.
4. Run the full suite. Failures here are T-REX behavior that the new base changed.
5. Apply the storage migration for any contract whose namespace string differs (see the table).

## Namespace status

A base's ERC-7201 slot is derived from its namespace string, so a string that differs from
OpenZeppelin's means a one-time storage migration for every live proxy. Swapping before mainnet, with no
live state, removes the problem entirely.

| Contract | Namespace today | OpenZeppelin's | Status |
|---|---|---|---|
| `ERC3643Token` | `erc3643.storage.ERC3643Token` | `openzeppelin.storage.ERC3643` (proposed, slot TBD) | Provisional. Migration needed at swap unless adopted first. |
| `ERC3643IdentityRegistry` | `erc3643.storage.IdentityRegistry` | none published | Provisional. |
| `ERC3643IdentityRegistryStorage` | `erc3643.storage.IdentityRegistryStorage` | none published | Provisional. |
| `ERC3643TrustedIssuersRegistry` | `erc3643.storage.TrustedIssuersRegistry` | none published | Provisional. |
| `ERC3643ClaimTopicsRegistry` | `erc3643.storage.ClaimTopicsRegistry` | none published | Provisional. |
| `ERC3643Compliance` | `erc3643.storage.Compliance` | none published | Provisional. |

Extension namespaces are T-REX's own, so the OpenZeppelin swap will not move them. The split itself did
move all of them, which is the migration below.

### Migration the split itself incurs

Every contract's layout changed, because state that used to sit at the head of a T-REX struct now lives
in a standard base. **Every namespace string had to change with it.** Reusing a namespace over a changed
struct does not fail loudly: it relocates every field after the one that moved, and the contract reads
neighbouring data as if it were its own.

Two of these were caught in review rather than by tests, because the test suite always deploys fresh and
so never exercises an in-place upgrade. The `TREXRegistry` case was the dangerous one: `checksDisabled`
would have been read from the low byte of the old identity-storage address, which is non-zero for 255 of
every 256 addresses, silently disabling eligibility checks and verifying every address.
`test/unit/registries/RegistryStorageLayout.t.sol` reads the deployed registry's storage to keep that
reasoning executable for the new layout.

| Contract | Before | After |
|---|---|---|
| Token | `token.storage.main` | `erc3643.storage.ERC3643Token` for standard state, `erc3643.storage.TREXToken` for `decimals`; name and symbol move to the ERC-20 base |
| IdentityRegistryStorage | `ERC3643.storage.IdentityRegistryStorage` | `erc3643.storage.IdentityRegistryStorage` |
| TREXRegistry | `erc3643.storage.TREXRegistry` | `erc3643.storage.TREXEligibility` |
| ModularCompliance | `ERC3643.storage.ModularCompliance` | `erc3643.storage.TREXCompliance` |

Nothing is deployed to mainnet, so this is recorded rather than scheduled. Any proxy deployed from an
earlier commit must be redeployed, not upgraded in place.

`test/standard/Namespaces.t.sol` records the expected slot for every namespace, and
`test/unit/token/TokenStorageLocationUnitTests.t.sol`, `test/unit/registries/RegistryStorageLayout.t.sol`
and a layout test in `test/unit/compliance/ModularComplianceInitUnitTest.t.sol` read real storage with
`vm.load` to confirm each field sits where
the new namespace says it does. None of this catches a struct that changes without its namespace moving:
no fresh-deploy test can, since the suite never upgrades a proxy in place. Committing
`forge inspect <Contract> storage-layout` and diffing it in CI would close that gap.

The Token's frozen state also changed shape, per issue #54: one mapping to a packed
`{bool addressFrozen, uint256 amount}` struct became two separate mappings, matching OpenZeppelin's
`ERC3643Storage`. This costs one extra SSTORE when both fields are set together and removes the need to
virtualize every internal frozen access on the upstream base.

### Mutable name and symbol

`ERC3643Token._setName` / `_setSymbol` write into `ERC20Upgradeable`'s **private** storage through a copy
of OpenZeppelin's struct at a hardcoded slot, because the ERC-20 base ships no setter. This depends on
OpenZeppelin never reordering that private struct's fields: the namespace test checks the slot, not the
order, so a reordering upstream would be silent.

Upstream is adding `name` and `symbol` setters to openzeppelin-contracts#5838 (@ernestognw), which
removes the hardcoded-slot copy at the swap. The remaining question there is how a name change interacts
with the EIP-712 domain, since both are usually set to the same value at construction: changing the name
rotates the domain separator and invalidates outstanding ERC-2612 permit signatures, which is why
`Token._setName` carries that note.

### Typed getters (#54) are not provided

Issue #54 asks for `compliance()` / `identityRegistry()` getters returning the T-REX types "if callers
still depend on them". None do: the only casts are internal (`Token.transferFrom` and `UtilityChecker`),
and the integration tests that cast to `ModularCompliance` / `TREXRegistry` would keep casting either
way. Returning the standard interface keeps `Token` swappable, so the getters are deliberately skipped.

### Caps are T-REX's, not the standard's

`MAX_CLAIM_TOPICS`, `MAX_TRUSTED_ISSUERS` and `MAX_ISSUER_CLAIM_TOPICS` come from T-REX v4, not from
ERC-3643. The bases expose `_maxClaimTopics`, `_maxTrustedIssuers` and `_maxIssuerClaimTopics`,
defaulting to unlimited; `TREXRegistry` overrides them with the v4 values, which is what keeps them
after the swap.

## Divergences to re-decide at swap time

The behavioral divergences this section used to list are closed: openzeppelin-contracts#5838 was aligned
with what this layer 2 needs (@ernestognw, commit `55f35f91d`). Upstream now makes the contract abstract
and gates every admin path on an abstract `_checkAdmin()` instead of `Ownable` plus `isAgent`; mint and
burn work while paused; `created` and `destroyed` fire on mint and burn; `isVerified` / `canTransfer`
skip a zero recipient; every batch entry point checks array lengths with `onlyAdmin` running first; and
burn auto-unfreezes just enough to keep `frozenTokens <= balanceOf`.

Two things still differ, neither a behavior change:

1. **Freeze error surface.** Upstream keeps a silent clamp in `_freezePartialTokens` and the Solidity
   panic on under-freeze in `_unfreezePartialTokens`; ours revert with named errors. Both are
   overridable upstream, so this stays a T-REX override rather than an upstream request.
2. **Storage field names.** Upstream's struct uses `_frozen`, `_frozenTokens`, `_identityRegistry`,
   `_compliance` and `_onchainID`, all private, so the namespace-migration procedure above still
   applies at the swap.

Upstream also documents a deliberate ERC-173 incompatibility (`transferOwnership(address(0))` is not
accepted), so anything needing that surface layers its own.

One item is not closed and is tracked separately: the recovery flow's ordering corrupts identity-keyed
compliance aggregates (#70). Upstream's `_recoveryAddress` already orders the steps so
`compliance.transferred` sees both endpoints of the identity migration resolvable; **this layer 2 must
adopt that ordering**, either when #70 is fixed or at the swap.

## Upstream status

openzeppelin-contracts#5838 was closed in August 2025 in favour of the ERC-3643 Association's own
implementation, reopened in July 2026, and last merged with master in September 2026. It ships the token
base and the interfaces only. There is no upstream implementation for the identity registry, the identity
registry storage, the trusted issuers registry, the claim topics registry, or the compliance; those are
expected in `openzeppelin-community-contracts`, if anywhere. Until then the five non-token bases have
nothing to swap to, and their namespace strings stay provisional.

As of commit `55f35f91d` that PR is aligned with this layer 2: the contract is abstract, authorization
goes through an abstract `_checkAdmin()` hook, and the behaviors listed under divergences above match.
It ships no ERC-3643 tests yet, so the standard suite here stays the regression net for the swap.

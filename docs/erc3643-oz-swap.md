# Swapping the ERC-3643 bases for OpenZeppelin's

This is the procedure for replacing the local standard bases in `contracts/ERC-3643/base/` with
OpenZeppelin's implementation once it ships, and the record of what that swap will cost. It is part of
the deliverable of issue #65, not an afterthought: the whole point of the layering is that this document
stays short.

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
`test/unit/registries/RegistryStorageLayout.t.sol` keeps that reasoning executable.

| Contract | Before | After |
|---|---|---|
| Token | `token.storage.main` | `erc3643.storage.ERC3643Token` for standard state, `erc3643.storage.TREXToken` for `decimals`; name and symbol move to the ERC-20 base |
| IdentityRegistryStorage | `ERC3643.storage.IdentityRegistryStorage` | `erc3643.storage.IdentityRegistryStorage` |
| TREXRegistry | `erc3643.storage.TREXRegistry` | `erc3643.storage.TREXEligibility` |
| ModularCompliance | `ERC3643.storage.ModularCompliance` | `erc3643.storage.TREXCompliance` |

Nothing is deployed to mainnet, so this is recorded rather than scheduled. Any proxy deployed from an
earlier commit must be redeployed, not upgraded in place.

`test/standard/Namespaces.t.sol` pins every namespace slot, so a future struct change that
forgets to move its namespace fails a test instead of shipping.

The Token's frozen state also changed shape, per issue #54: one mapping to a packed
`{bool addressFrozen, uint256 amount}` struct became two separate mappings, matching OpenZeppelin's
`ERC3643Storage`. This costs one extra SSTORE when both fields are set together and removes the need to
virtualize every internal frozen access on the upstream base.

## Divergences to re-decide at swap time

`ERC3643Token` deliberately differs from openzeppelin-contracts#5838 as that PR stands. Each is a T-REX
behavior the standard suite pins, so the swap must re-decide it rather than silently change it. They are
listed on the contract itself; the ones with teeth:

1. **Mint and burn while paused.** OpenZeppelin puts `whenNotPaused` on `_update`, which blocks both.
   T-REX pauses circulation, not issuance and redemption.
2. **Compliance notifications.** T-REX calls `created` on a mint and `destroyed` on a burn. OpenZeppelin
   calls only `transferred`, and only on transfers. Modules that track balances need all three.
3. **Burn and recipient verification.** OpenZeppelin's `_update` checks `isVerified(to)` unconditionally,
   so a burn would ask the registry to verify the zero address and revert.
4. **Authorization.** T-REX authorizes through an AccessManager via `_checkTokenAdmin`; OpenZeppelin uses
   `Ownable` plus an abstract `isAgent`. The hook makes this a one-line override, but every test asserting
   a revert selector changes.

Items 1 to 3 should be raised on the upstream PR before adopting its base. As written, inheriting it
would lose all three.

## Upstream status

openzeppelin-contracts#5838 was closed in August 2025 in favour of the ERC-3643 Association's own
implementation, reopened in July 2026, and last merged with master in September 2026. It ships the token
base and the interfaces only. There is no upstream implementation for the identity registry, the identity
registry storage, the trusted issuers registry, the claim topics registry, or the compliance; those are
expected in `openzeppelin-community-contracts`, if anywhere. Until then the five non-token bases have
nothing to swap to, and their namespace strings stay provisional.

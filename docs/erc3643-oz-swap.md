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

Extension namespaces are T-REX's own and are unaffected by the swap: `erc3643.storage.TREXToken`,
`erc3643.storage.TREXRegistry`, `ERC3643.storage.ModularCompliance`.

### Migration already incurred by the split

Two namespaces moved when the layering landed. Any proxy deployed before it needs a one-time migration;
nothing is deployed to mainnet yet, so this is recorded rather than scheduled.

| Contract | Before | After |
|---|---|---|
| Token | `token.storage.main` (name, symbol, decimals, onchainId, compliance, identityRegistry, packed frozen struct) | `erc3643.storage.ERC3643Token` for standard state, `erc3643.storage.TREXToken` for `decimals`; name and symbol move to the ERC-20 base's own storage |
| IdentityRegistryStorage | `ERC3643.storage.IdentityRegistryStorage` | `erc3643.storage.IdentityRegistryStorage` |

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

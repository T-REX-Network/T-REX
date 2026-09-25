# Compliance modules

A compliance module is a rule about who may hold or move a token. This page is everything you need to
write one.

## The four numbers the compliance keeps

The token knows balances per wallet. One investor holds several wallets, here and on satellite chains,
and every rule about distribution asks about the investor, not the wallet. So the compliance keeps four
numbers itself, from the hooks the token already calls, and modules read them instead of rebuilding them:

| View on the compliance | What it means |
|---|---|
| `positionOf(identity)` | what the identity owns in total: free, frozen and bridged, over every linked wallet |
| `pendingInOf(identity)` | what open cross-chain validations promise to it |
| `pendingOutOf(identity)` | what open cross-chain validations promise out of it |
| `pendingOutOfWallet(walletKey)` | what open validations may still draw from one satellite wallet |

They are declared in `IComplianceLedger`. Nothing outside the compliance writes them. A movement between
two wallets of one identity changes none of them: relocating your own tokens is not a change of ownership.

## The three kinds of module

A module says what it is in `moduleTypes()`, and the compliance calls it only where it said so.

| Type | Function | When |
|---|---|---|
| `RULE` | `allowedAmount(ctx)` | before a transfer or a mint, and when a cross-chain validation is issued |
| `SPENDER` | `moduleCheckSpender(ctx)` | before an allowance is spent in `transferFrom`, and when a validation names a spender |
| `TRACKER` | `afterTransfer(ctx)` | after the tokens moved and the positions were updated |

A module may name one, two or all three. It inherits `AbstractModuleUpgradeable`, which answers every
question neutrally, and overrides only the ones its types cover.

## allowedAmount

A rule answers one question: what is the largest amount you allow to move? `type(uint256).max` means no
limit, `0` means refused. The compliance keeps the smallest answer over the bound rules.

That one answer serves both worlds. On a native transfer the amount must be at most the minimum. On a
cross-chain issuance, where the satellite will later execute some amount inside a range, the range is
narrowed to that same minimum. There is no second function for the cross-chain case and no range to
reason about.

The rule must be monotonic: a smaller amount is never less acceptable than a larger one. Caps, floors,
limits and allow lists all are. A rule that is not, "a multiple of 100" for instance, reads
`ctx.amountMax` and answers `max` or `0`, and refuses an issuance whose range is not a point.

`allowedAmount` is a view. The compliance calls it under `staticcall`, so a module that writes there
reverts.

## The context

Every call carries a `TransferContext` the compliance filled in once:

```solidity
struct TransferContext {
    address compliance;     // read the ledger and your settings from this, never from msg.sender
    address fromIdentity;   // zero on a mint
    address toIdentity;     // zero on a burn
    bytes32 fromWallet;     // canonical wallet key, zero on a mint
    bytes32 toWallet;       // zero on a burn
    uint256 amountMin;      // equal to amountMax on a native movement
    uint256 amountMax;      // the amount that moved, or the requested maximum on an issuance
    bool    isIssuance;     // true while a cross-chain validation is being issued
    bytes   spender;        // ERC-7930 envelope of who executes on the sender's behalf, empty otherwise
}
```

A `SPENDER` module answers about `ctx.spender`, a wallet on this chain or on a satellite, so one
policy covers `transferFrom` here and a validation a satellite operator will execute. The shipped
`SpenderVerificationModule` asks the registry whether that wallet is eligible; `SpenderWhitelistModule`
keeps an allowlist of wallets by their canonical key.

Identities arrive resolved, so a module never calls the registry to find out whose tokens these are. The
ledger describes the state before the move.

One context, one convention, everywhere. A mint has no sender, so `fromIdentity` and `fromWallet` are zero;
a burn has no recipient, so `toIdentity` and `toWallet` are zero. A `TRACKER` reads that to tell the three
apart, which is why it needs one function and not three.

A recipient that resolves to no identity is refused before any rule is asked, whenever a rule is bound. A
distribution rule keys on the identity and would read a zero one as a burn, so the tokens would land where
no cap could reach them. Only a token whose registry has eligibility checks disabled can get that far.

## Two rules a module must follow

**A module never calls another module.** It talks to the compliance and to the token's identity registry,
and nothing else. A module that needs a fact nobody publishes keeps it itself, in its own storage, and
updates it in its tracker actions.

**Record before you call out.** A module that keeps a counter must write it before any external call and
rely on the transaction reverting to undo it. The token guards its own reentrancy; that guard does not
extend to calls your module makes.

## A complete rule

`MaxBalancePerIdentityModule` caps what one identity may own, over every wallet and every chain:

```solidity
function allowedAmount(TransferContext calldata ctx) external view override returns (uint256) {
    if (ctx.toIdentity == address(0) || ctx.fromIdentity == ctx.toIdentity) return type(uint256).max;
    IComplianceLedger ledger = IComplianceLedger(ctx.compliance);
    uint256 held = ledger.positionOf(ctx.toIdentity) + ledger.pendingInOf(ctx.toIdentity);
    uint256 cap = _getMaxBalanceStorage().maxBalance[ctx.compliance][getNonce(ctx.compliance)];
    return held >= cap ? 0 : cap - held;
}

function moduleTypes() external pure returns (ModuleType[] memory types) {
    types = new ModuleType[](1);
    types[0] = ModuleType.RULE;
}
```

No burn is limited, no relocation between one identity's wallets is limited, and the same nine lines
cover a native transfer, an issuance, two validations racing for the same cap and a late settlement.
`MaxBalancePerIdentityModule.t.sol` exercises exactly that list.

## The compliance follows its token from the first mint

The numbers above are right because the compliance saw every movement since the token's first mint. A
token deployed with its compliance needs nothing. Moving a token that already has holders onto a new
compliance with `setCompliance` is not supported: the new compliance would start every identity at
zero. A circulating token's compliance is upgraded in place through its beacon, or changed through its
modules.

Two events say when a position and the balances disagree: `PositionUnresolved` when a wallet that holds
tokens resolves to no identity, `PositionUnderflow` when a debit exceeds what the identity held. Both
mean a registry entry was removed or relinked under a wallet that holds tokens; neither reverts, so a
burn or a forced transfer stays possible while the link is repaired.

## Binding

The owner binds a module with `addModule`, or with `addAndSetModule` to configure it in the same
transaction. The compliance reads `moduleTypes()` once at binding and files the module under each type.
An implementation upgrade that changes the types takes effect when the owner calls `resyncModuleTypes`.
Do not remove and re-add the module instead: an unbind increments the module's bind nonce, which is how a
module scopes its per-compliance settings, so it would come back with an empty allowlist or an unset cap.

`getModules()` lists every bound module; `getModulesByType(type)` lists the ones of one kind.

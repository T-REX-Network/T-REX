# Compliance modules

A compliance module is a rule about who may hold or move a token. This page is everything you need to
write one.

## What the compliance keeps

The token knows balances per wallet. One investor holds several wallets, here and on satellite chains,
and every rule about distribution asks about the investor, not the wallet. So the compliance keeps these
numbers itself, from the hooks the token already calls, and modules read them instead of rebuilding them:

| View on the compliance | What it means |
|---|---|
| `positionOf(identity)` | what the identity owns in total: free, frozen, away and on hold, over every linked wallet |
| `pendingInOf(identity)` | what open cross-chain tickets promise to it |
| `pendingOutOf(identity)` | what open cross-chain tickets promise out of it |
| `onHoldForwardOf(chainKey)` | money that left that away chain toward a receiver on another chain and is on hold, not done yet |
| `reservedFromOf(chainKey)` | what the tickets open on that away chain reserve, at their maximum |
| `ownerOf(wallet)` | the identity the ledger credited a native wallet to |

They are declared in `IComplianceLedger`. Nothing outside the compliance writes them. A movement between
two wallets of one identity changes none of them: relocating your own tokens is not a change of ownership.

## The three kinds of module

Every module implements the same three methods, two questions and one notice, and names in `moduleTypes()`
the ones it answers. The compliance calls a module only where it said so.

Two are questions and one is a notice. `checkTransfer` and `checkSpender` are views: the compliance asks
them under `staticcall`, before anything moves, and a module cannot record anything there. `afterTransfer`
is the notice: it is told once the ledger moved, and that is where a module counts.

| Type | Method | When | Sees |
|---|---|---|---|
| `TRANSFER_CHECK` | `checkTransfer(ctx)` view | before a transfer or a mint, and when a cross-chain validation is issued | the ledger before the move |
| `SPENDER` | `checkSpender(ctx)` view | before an allowance is spent in `transferFrom`, and when a validation names a spender | who executes |
| `AFTER` | `afterTransfer(ctx)` | after the tokens moved and the positions were updated | the ledger after the move |

A module may name any combination. It inherits `AbstractModuleUpgradeable`, which answers every question
neutrally, and overrides only the methods its types cover.

The order on a native movement is: `canTransfer` asks the `TRANSFER_CHECK` modules; the token moves the balances and
calls the compliance; the compliance moves the positions and tells the `AFTER` modules. A settlement tells the
`AFTER` modules once the positions moved. It asks the `TRANSFER_CHECK` modules again only where home still decides:
whether the second half of a move to another chain goes to the receiver or back to the sender, and, announced with
`MoveBreachedRule` and never refused, a move inside one away chain. The issuance of a validation asks `TRANSFER_CHECK`
and `SPENDER` only: nothing moves there.

Which to pick. A bound on how much may move is a `TRANSFER_CHECK`: it returns a number, so it narrows a cross-chain
issuance as well. A veto on the state a movement leaves behind is an `AFTER` module that reverts, with its
own error; the movement and the ledger move are undone together. A counter that must be checked and then
recorded is `TRANSFER_CHECK` plus `AFTER` on the same storage. A fact about the state before the move is read in
`AFTER` too: the context carries the exact amount, so the position before is the position after plus or
minus it.

An `AFTER` veto refuses a native transfer and a mint, nothing else. `afterTransfer` also runs where a revert
is no veto: on a settlement, where the satellite already executed, so the revert leaves the delivery
undeliverable until `forceRemoveModule` drops the module, and with it the veto on every movement; on a
forced transfer and a recovery, which are the agent's override, usually the movement that has to get
through; and on a burn, which only an agent can call, so a revert there blocks a redemption the same way.
So an `AFTER` module that judges the state reads `kind` and refuses `TRANSFER` and `MINT` only, letting
`BURN`, `CROSS_CHAIN`, `DELEGATION`, `RECALL`, `FORCED_TRANSFER` and `RECOVERY` pass. A limit on what may cross
chains belongs in `checkTransfer`, which narrows the issuance before anything leaves.

## checkTransfer

A `TRANSFER_CHECK` module answers one question: what is the largest amount you allow to move? `type(uint256).max` means no
limit, `0` means refused. The compliance keeps the smallest answer over the bound rules.

That one answer serves both worlds. On a native transfer the amount must be at most the minimum. On a
cross-chain issuance, where the satellite will later execute some amount inside a range, the range is
narrowed to that same minimum. There is no second function for the cross-chain case and no range to
reason about.

The rule must be monotonic: a smaller amount is never less acceptable than a larger one. Caps, floors,
limits and allow lists all are. A rule that is not, "a multiple of 100" for instance, reads
`ctx.amountMax` and answers `max` or `0`, and refuses an issuance whose range is not a point.

`checkTransfer` is a view. The compliance calls it under `staticcall`, so a module that writes there
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
    uint8   kind;           // a MovementKindLib constant: TRANSFER, MINT, BURN, FORCED_TRANSFER, RECOVERY, CROSS_CHAIN, DELEGATION, RECALL; never zero
    bool    isIssuance;     // true while a cross-chain validation is being issued
    bytes   spender;        // ERC-7930 envelope of who executes on the sender's behalf, empty otherwise
    bytes   data;           // abi.encode(bytes32 fromChainKey) on a move between chains, empty on a native one
}
```

`kind` says what produced the movement. The zero sides already tell a mint and a burn apart, but a forced
transfer and a recovery move between two non-zero wallets exactly like a transfer does, and only the token
knows the difference: it reports them to the compliance through `agentTransferred`, with the kind, instead
of `transferred`. A tracker that counts an investor's own activity, a monthly transfer limit for instance,
reads `kind` and leaves `FORCED_TRANSFER` and `RECOVERY` out. A tracker that follows ownership does not:
a forced transfer always moves the position between identities, and a recovery does when the new wallet
belongs to another identity, so a holder count or a per-identity tracker records both. No rule is ever
asked about those two, so a `TRANSFER_CHECK` module only ever sees `TRANSFER`, `MINT` and `CROSS_CHAIN`.

`DELEGATION` is a home wallet's move out to an away wallet, told once when the move is done, with the real
`fromWallet` and `toWallet` and both identities. The rules were asked at the ask, as a `CROSS_CHAIN`, and the
position moves between the identities when they differ; when they are the same, only the location changes. A tracker
of the investor's own activity reads both identities to tell a move to their own away wallet from one to someone
else's; a holder count records a change of ownership when the identities differ.

`RECALL` is the way back, an agent's bring home answered by the away token's receipt: the inverse of a `DELEGATION`,
so a module that debited the out-leg has the in-leg to credit. `fromWallet` and `toWallet` are both the home wallet
the credit landed on; the position does not move, and no rule is asked. The credit lands only on a home wallet still
linked to the bring home's identity and verified; an empty one whose ledger record names an earlier owner takes that
identity. A funded one the ledger counts under another identity is not credited: what was burned goes back to the
away wallet by a `MOVE_OUT`, as for a wallet no longer the identity's (see the last sentence). The credit is already
counted in that identity's position as an away one, so nothing else moves. The compliance tells the `RECALL` once
the mint is done, with both identities the bring home's. The mint itself goes through no hook, so a module never
sees a plain `MINT` of tokens it saw leave as a `DELEGATION`. A tracker of the investor's own activity leaves it
out; a module keeping its own record of native balances credits it, and needs no reseed after a round trip. A bring
home whose home wallet is no longer the identity's is sent back to the away wallet and tells nobody.

`kind` is a number and not an enum, on purpose. Solidity range-checks an enum when it decodes calldata, so a
module compiled against today's kinds would revert on a kind added later and block every movement of that
kind until it was upgraded. With a number, a module that meets a kind it was not written for sees an
unfamiliar value. A module MUST NOT revert on a kind it does not know; that is the contract `IModule` states
on each hook. Zero is never a kind: a context reporting zero was built without one, and a test sees that
instead of a forced transfer that reads as a plain transfer.

Letting an unknown kind through is not safe by itself. A tracker that skips a kind it does not know misses
a movement in silence, and a revert that would have been loud becomes a count that is quietly wrong. So each
tracker decides, on purpose, what an unknown kind means for it. A counter of the investor's own activity
leaves it out, the way it leaves out `FORCED_TRANSFER` and `RECOVERY`. A tracker that has to see every
change of ownership, a holder count for instance, records it like any other movement. Write that choice
in the module; never let it fall out of a `switch` with no default.

`data` is room for what the struct does not carry. The struct is a parameter of every module function, so it is part
of their selectors: a field added once modules are deployed changes the selectors and breaks every one of them. A
new fact goes in `data` instead. The compliance that fills it documents the shape, an `abi.encode`d tuple,
and only ever appends to that tuple, so a module that decodes the prefix it knows keeps working when a
later fact is added behind it. A module decodes `data` only when it knows which compliance filled it, and
ignores it otherwise.

`ModularCompliance` fills it on every move between chains, at the ask, when the rules are asked again and when the
move is done: `abi.encode(bytes32 fromChainKey)`, the key of the chain the money leaves (`MessageTypesLib.chainKey`),
home's own key for a home wallet's move out. The wallet keys cannot say it: an away wallet's key is a hash of its
envelope. A native movement leaves `data` empty.

A `SPENDER` module answers about `ctx.spender`, a wallet on this chain or on a satellite, so one
policy covers `transferFrom` here and a validation a satellite operator will execute. The shipped
`SpenderVerificationModule` asks the registry whether that wallet is eligible; `SpenderWhitelistModule`
keeps an allowlist of wallets by their canonical key.

Identities arrive resolved, so a module never calls the registry to find out whose tokens these are. The
ledger describes the state before the move.

One context, one convention, everywhere. A mint has no sender, so `fromIdentity` and `fromWallet` are zero;
a burn has no recipient, so `toIdentity` and `toWallet` are zero. An `AFTER` module reads that, and `kind`, to
tell every movement apart, which is why it needs one function and not three.

A recipient that resolves to no identity is refused before any rule is asked, whenever a rule is bound. A
distribution rule keys on the identity and would read a zero one as a burn, so the tokens would land where
no cap could reach them. Only a token whose registry has eligibility checks disabled can get that far.

## A check that answers later

Some rules cannot answer inside the request. Part of the data may live only in an institution's systems, an
investor's holdings across every asset for instance, or the rule may be computed with FHE and only learn its
result in a later transaction, through its decryption callback. `checkTransfer` is a view and cannot wait, so
the compliance has a waiting state for cross-chain requests, and a module of type `APPROVAL` decides them.

While an `APPROVAL` module is bound (one at most), `askToMove` does everything it does today,
resolving the route, checking that the chain its first message goes to is open (`ChainNotOpen`), narrowing the
range by every rule and reserving it, but records the validation as
`WaitingForApproval` instead of issuing it. Nothing is signed and nothing is sent. The module is told through
`approvalRequested`. A ticket that waits for an approver always travels the receipt route, at full finality: a home
reorg short of finality could otherwise drop the approver's answer after the away token executed the ticket. The
request's `validUntil`, the receipt route's validity window from now, is the deadline for the answer and the
satellite's deadline: the time spent waiting comes out of the time to execute, so the rules are never older than one
validity window when the satellite executes. The first send has no deadline of its own. The approvers' answer time is not measured on
chain: the receipt route's validity window is sized off chain to cover it.

Only the module answers, with `answerApproval(bytes32 ticketId, approvedMax)`, before the deadline. An approval
lowers the maximum when the answer is lower, releases the difference and opens the ticket; no rule runs again,
since every rule ran and the room was reserved at the request. Nothing is sent by the answer: anyone makes the
first send with `sendTicket(ticketId, to, spender)`, at any time, and that send checks the token
and the chain again, as either may have been stopped while the request waited, and a receiver's other away chain
only for a block. A zero answer is a refusal,
which releases the reservation and ends the validation `Cancelled`; any other answer must lie inside
`[amountMin, amountMax]`, or it reverts with `EmptyValidationRange`. A request nobody answered is discarded past its
deadline with `cancelTickets`, by anyone, since nothing was sent for it, unless a receipt for it waits and can be
applied now (`ApplyWaitingReceiptFirst`): anyone applies it first with `applyWaitingReceipt`. An approved ticket
from an away wallet is cancelled only once an ask for its receipt went unanswered, as any open ticket: a first send
made at or after `waitingEndsAt` is that ask. An approved move from a home wallet that nobody sent has no ask and
nothing out for it, so it is discarded past its deadline as an unanswered request is: its holder may have spent or
frozen the tokens, and the first send would then never go out.
A receipt for a ticket that was never sent (still waiting, approved and not sent, refused or
unanswered) answers no copy home sent: it is put on hold with no destination and reversed, never applied as the
ticket's move. Home's own copy is the only honest one of an approved ticket: a first-half receipt on any other ask
block hash breaks its terms and blocks its away chain. Neither stops the token.

Because the request reserves while it waits, two waiting requests cannot jointly break a rule that reads the
ledger: the second one sees the first one's pending amount, as it would see an issued validation's.

An `APPROVAL` module is bound, removed or filed again only while asks are paused for the whole token
(`setAsksPaused(0, true)`, otherwise `AsksNotPaused`): whether a ticket waits for an approver is written at its ask, and a
change inside a home block a reorg drops would leave one fork's ticket waiting and the other's not. A module change
does not wait for open tickets: `addModule`, `addAndSetModule`, `removeModule`, `resyncModuleTypes` and
`callModuleFunction` run while tickets are open, since a ticket keeps what was decided at its ask. Only unbinding
the compliance from its token waits: it is refused with `ValidationsPending` while the reserved total is above zero,
and before `latestStopWaitingAt`, the latest `stopWaitingAt` of any ticket, since a new compliance would meet a late
receipt with no record. Unbinding the module turns new requests
back into immediate issuances; the OWNER of the compliance can do it if the approvers stop answering, and the
requests left waiting are discarded past their deadline.

`AsyncApprovalModule` is the `APPROVAL` module that ships:

- The compliance owner lists the approvers with `setApprovers`, through `addAndSetModule` or
  `callModuleFunction`. An approver is any address: an institution's backend key, a multisig, or a contract.
- They answer in that order, on the validation id, with `approveValidation(compliance, id, amountMax)` or
  `refuseValidation(compliance, id)`. They cannot change the recipient or the spender, or widen the range: the
  lowest maximum approved is the one issued, and the first refusal refuses at once.
- The last approval only records the request as fully approved. Anyone then calls `finalize(compliance, id)`,
  which answers the compliance; anyone then sends the ticket with `sendTicket`. An approver answering from a
  callback therefore never reverts on a paused chain, nor carries the cost of a send.
- An approver contract is told in the same transaction, through `IAsyncApprover.approvalAsked`, when its turn
  comes. An FHE rule starts its computation there and answers from its decryption callback, with no trusted
  party in between. Telling is best effort: an approver that does not implement it reads `ApprovalRequested`.
- A relocation between one identity's own wallets changes no position, so the module approves it at once,
  inside the request, and asks nobody.
- Setting a new approver list stops the requests already waiting, since what was approved so far was approved
  under the old list. They are discarded at their deadline.
- Native transfers cannot wait, since the investor executes them in one call. Any approver can store an approval
  of one exact transfer (sender, recipient, amount) with an expiry, under an `approvalId` of its own, so a
  decision delivered twice approves one transfer. Ids are kept per approver, so two approvers never block each
  other's decisions. `checkTransfer` passes it, `afterTransfer` uses it up, and
  `revokeApproval` withdraws one. Approving the same transfer again adds to the count, and the newest expiry
  applies to all of its approvals.
- The approvers are the compliance's own, so on a module shared by several issuers, one issuer's approver
  cannot answer for another.

Limits, stated plainly:

- **The approvers gate every cross-chain movement.** If they stop answering, requests are discarded at their
  deadline, and only unbinding the module restores immediate issuance.
- **A native transfer passes on one approver's approval,** while a cross-chain request needs all of them in
  order. With a backend and an FHE rule listed, the backend alone approves native transfers, and the FHE rule
  never sees them: the native path is as strong as the weakest approver.
- **Mints are not judged**, being the issuer's own action, though they move holdings like a transfer does. An
  issuer whose rule covers total holdings checks it before minting.
- **Forced transfers, recoveries and relocations** between one identity's native wallets are not judged either.

## A limit per away chain

The caps on the ticket route bound what a home reorg can cost. They do not bound a hostile away token, which can
still report a move made on a home block that was dropped. `AwayChainVolumeModule` bounds what one away chain can
make leave in a window, per compliance:

- The compliance owner sets a limit per away chain with `setVolumeLimit(chainKey, limitPerWindow, window)`, through
  `addAndSetModule` or `callModuleFunction`, at any time, open tickets included. Home's own key is refused
  (`NotAnAwayChain`). The window is in seconds and must be positive (`ZeroDuration`); a new length also moves the end of the window running
  now. `VolumeLimitSet` says so; `volumeLimitOf(compliance, chainKey)` reads it. To lift a limit, set
  `type(uint256).max`. A chain with no limit set is neither limited nor counted.
- `checkTransfer` reads the chain the money leaves from `data` and answers the room left on it in the current window,
  less the money on hold forward from it (`onHoldForwardOf(chainKey)` on the compliance: money that left the chain
  toward a receiver on another chain, not done yet) and less what the tickets open there reserve
  (`reservedFromOf(chainKey)`, at their `amountMax`): the ask is narrowed to it, and refused once nothing is left. So is home's decision for a second half: a move whose
  chain is full by then goes back to its sender. A native movement carries no chain and is never limited.
- `afterTransfer` counts a move once, when it is done, on the chain it left. A window starts at the first move counted
  after the last window ended, and the next window opens the chain again.

Limits, stated plainly:

- **Open tickets count at their maximum.** Tickets open at the same time share one room, so what is open, on hold
  forward and done in a window never passes the limit, a relocation aside.
- **A relocation is counted but never narrowed.** The rules are not asked about a move between one identity's own
  wallets, so it passes whatever the room, and fills the room of the moves after it.
- **Counting starts at binding,** and for a chain at its first limit. An unbind discards the limits and the counts.

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
function checkTransfer(TransferContext calldata ctx) external view override returns (uint256) {
    if (ctx.toIdentity == address(0) || ctx.fromIdentity == ctx.toIdentity) return type(uint256).max;
    IComplianceLedger ledger = IComplianceLedger(ctx.compliance);
    uint256 held = ledger.positionOf(ctx.toIdentity) + ledger.pendingInOf(ctx.toIdentity);
    uint256 cap = _getMaxBalanceStorage().maxBalance[ctx.compliance][getNonce(ctx.compliance)];
    return held >= cap ? 0 : cap - held;
}

function moduleTypes() external pure returns (ModuleType[] memory types) {
    types = new ModuleType[](1);
    types[0] = ModuleType.TRANSFER_CHECK;
}
```

No burn is limited, no relocation between one identity's wallets is limited, and the same nine lines
cover a native transfer, an issuance, two validations racing for the same cap and a late settlement.
`MaxBalancePerIdentityModule.t.sol` exercises exactly that list.

## The compliance follows its token from the first mint

The numbers above are right because the compliance saw every movement since the token's first mint. A
token deployed with its compliance needs nothing. Once the token has supply, `setCompliance`,
`setIdentityRegistry` and the compliance's `bindToken` all revert with `TokenCirculating`: a new
compliance would start every identity at zero, and a new registry could attribute wallets to identities
that hold no position. A circulating token's compliance is upgraded in place through its beacon, or
changed through its modules; wallet bindings are changed in the registry it has.

A wallet keeps its identity after the investor revokes it, so a revoked wallet can still be burned,
recovered or force-transferred against the right position; it just may not act.

Wallet bindings are sticky in the registry's storage, as in the ONCHAINID IdentityFactory. An agent
cannot relink a wallet to another identity, and deleting an entry revokes it: the wallet keeps its
identity but may no longer act, and it can never be registered again. Moving an investor to a new
identity is a forced transfer to a wallet of that identity.

Who a wallet resolves to can still change through an admin action, a registry upgrade to an implementation
on another IdentityFactory. The ledger remembers which identity it credited each native wallet to
(`ownerOf(wallet)`). When the registry names another identity for an empty wallet, the next movement
takes the new owner; `WalletOwnerChanged` says so. When it names another identity for a wallet that
holds tokens, every movement through that wallet reverts with `WalletBoundToAnotherIdentity` until the
registry names the credited owner again: a balance never changes identity without the rules seeing it,
and the rules only see movements. When the registry names nobody, the remembered owner still answers.

Every token has an owner. The registry admits no wallet without an active identity, even with its
eligibility checks disabled, which skip the claims only. So `sum(positions) == totalSupply` always
holds, and a debit the position cannot cover reverts.

Nothing repairs a position. A debit that reverts means the invariant is broken, so the agent's own
calls on that identity (burn, forced transfer, recovery) revert with it. The fix is a compliance
implementation upgrade through the version manager, not an owner call.

## Binding

The owner binds a module with `addModule`, or with `addAndSetModule` to configure it in the same
transaction. The compliance reads `moduleTypes()` once at binding and files the module under each type.
A module built on `AbstractModuleUpgradeable` cannot change its types in an upgrade, not even their order:
the upgrade reverts with `ModuleTypesChanged`. A module that needs other types is a new module, deployed and
bound in place of the old one, and configured again, since its settings belong to the old module.

The guard lives in the module's own code, so it does not cover a module that is not built on
`AbstractModuleUpgradeable`, one behind another kind of proxy, or one upgraded to code that dropped the
override. Such a module can still change its types under every bound compliance. The owner then calls
`resyncModuleTypes`, which files the module again by what it now names. Do not remove and re-add the module
instead: an unbind increments the module's bind nonce, which is how a module scopes its per-compliance
settings, so it would come back with an empty allowlist or an unset cap.

`getModules()` lists every bound module; `getModulesByType(type)` lists the ones of one kind.

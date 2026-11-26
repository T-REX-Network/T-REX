# The satellite Lite

A Lite is the token's presence on a satellite chain: it holds the satellite positions, executes what the reference
chain authorises, and reports back. It lives outside this repository, so this page is its contract: what the
reference chain assumes of a Lite, stated as rules the Lite MUST follow. The reference chain is safe only while
every Lite does. `test/integration/mocks/SatelliteLiteMock.sol` follows them;
`test/integration/interop/LiteDrivenSettlement.t.sol` and `test/invariant/DelegationRecall.invariants.t.sol` run the
reference chain against it.

## Messages

| Direction | Type | Body | What the Lite does |
|---|---|---|---|
| in | `TICKET` | `TicketMessage { ticketId, salt, from, to, spender, amountMin, amountMax, requestedMax, token, validUntil, askBlockHash }` | stores the first copy under `ticketId` |
| in | `MOVE_OUT` | `MoveOutMessage { delegationId, toWallet, amount, holder }` | mints `amount` to `toWallet`, once per `delegationId` |
| in | `BRING_HOME` | `BringHomeMessage { recallId, wallet, amount, nativeWallet }` | burns up to `amount` of `wallet` once, answers with a `BurnProof` |
| out | `RECEIPT` | `ReceiptMessage { ticketId, from, to, amount, askBlockHash, seenMax, seenValidUntil, half, answer }` | one per leg it executed, echoing the copy it executed under: its `askBlockHash`, its `amountMax` as `seenMax` and its `validUntil` as `seenValidUntil`; `half` is 0 and `answer` is `Executed` |
| out | `BURN_PROOF` | `BurnProof { recallId, burnedWallet, amount }` | one per recall id, resent unchanged on request |

Every message carries the envelope version 2 (`MessageTypesLib.VERSION`); a message of any other version is refused,
on both sides.

The ticket id is built from the whole request: `keccak256(abi.encode(kind, fromKey, toKey, spenderKey, amountMin,
requestedMax, salt))`, where the keys are `keccak256` of the canonical envelopes (of empty bytes for no spender) and
`kind` is 0 for a move. The same ask mined in any block gets the same id. The ask block hash,
`keccak256(abi.encode(block.number, blockhash(block.number - 1), amountMax, validUntil))` read in the block that
issued the ticket, names the copy: two copies of one ask mined in two blocks share the id and differ in it.

`answer` says why a receipt says what it says, so a receipt of amount zero says why it is zero: `Executed` (the
copy echoed was executed, for `amount`, possibly zero), `Expired` (never executed and past its valid until) or
`StillOpen` (never executed, still before its valid until). A Lite reports `Executed` for every leg it executed;
home reads the other two once it asks a Lite for a receipt.

Every message travels through a gateway the network's `TrustedGatewayRegistry` trusts. The token accepts a settlement
only from the chain's current peer, and a burn proof for an open recall only from the peer and through the gateway
that recall was dispatched to.

## Rules

### Transport

1. **Act on each delivery once.** A gateway may redeliver; the Lite dedupes on a nonzero receive id, and also on
   the operation id, since a resend arrives under a new receive id: `ticketId` for a validation, see rule 3 for
   what a second body under a known id means, and the instruction ids of rules 9 and 10. A zero receive id names
   no delivery (ERC-7786 allows it) and is never recorded, or the first one would refuse every later message.
2. **Accept only the reference token as author**, through its own gateway.
2a. **Send every report on the final route.** A chain may have two routes on the reference side: a fast one, set
   with `setTicketRoute`, that carries validations out ahead of finality and nothing else, and the final one, set with
   `setReceiptRoute`, that carries instructions out and is the only one settlements and burn proofs are taken from. The
   token refuses a delivery from the fast route with `WrongRoute`, and pins each validation leg to the final
   route of the moment (`pinnedRouteFor`), so a validation that arrived on the fast gateway is settled through the
   final one, not back through the gateway that delivered it.

### Validations

3. **Execute a ticket once, and keep the first copy per id.** A ticket delivered again under a known id is never
   held in place of the first: a resend repeats it, and a later copy of the same ask, mined again in another block
   after a reorg (another `askBlockHash`, maybe another `amountMax` or `validUntil`), is ignored. The receipt echoes
   the copy held, and the reference chain tells which one it was.
4. Execute strictly before `validUntil`.
5. Execute an amount inside `[amountMin, amountMax]`.
6. Execute only for the named wallets, by `from` or by the named `spender`.
7. Report every leg it executed, exactly once, echoing the copy it executed under (`askBlockHash`, `seenMax`,
   `seenValidUntil`) with `answer` `Executed`. One-leg
   movements carry both wallets; on a two-leg movement the sending Lite reports the burn leg with `to` empty, the
   receiving Lite the mint leg with `from` empty. A report lost on the way may be sent again byte for byte: the
   reference chain recognises a leg it already consumed (`ReceiptDuplicate`) and changes nothing.

### The two-leg invariant

8. **The receiving Lite mints only on the sending Lite's burn message**, carried by a trusted gateway and authored by
   that Lite, for the amount it carries, never from the validation alone. This is what makes a range safe on a
   two-leg validation, and what the token's `SettlementAmountMismatch` check backs up. The receiving Lite's own copy
   of the validation is what it checks that message against: the recipient, the bounds and the token. A burn message
   for a validation the Lite does not hold is refused, not minted, and redelivered once the leg arrives; rule 4 binds
   the sending Lite, the mint follows the burn whatever the clock says, and the reference chain takes a late leg.

### Instructions

9. **A mint instruction mints at most once per `delegationId`.** The same id again with the same body is a no-op;
   the same id with a different body is refused. The reference chain already burned the native balance and credited
   the bridged position; a Lite that mints twice has inflated its chain.
10. **A recall instruction burns at most once per `recallId`.** The Lite burns `min(amount, balance)`, where `balance`
    may be below `amount`, down to zero, when a validation requested before the recall executed first, including
    one that was still awaiting approval when the recall was instructed; stores the proof; sends it. A validation
    requested after it cannot draw on the recalled amount: the token holds `amount` back from the wallet's
    `availableOf` from the instruction until the proof settles the recall. Nothing else releases it: an instruction
    that was never answered may still be executed, so its amount stays held back. A repeated
    instruction is answered with the stored proof, and the operator can resend it. The Lite never answers one id with
    two different proofs and never proves more than instructed. The token credits the native wallet the instruction
    recorded, not one the proof could choose.

## Lanes

A message may be attested to a Lite before the reference chain reaches finality only when nothing it carries
depends on which block, or in which order, its transaction landed. That holds for one type:

| Type | Lane | Why |
|---|---|---|
| `TICKET` | may ride before finality | `ticketId` is built from the whole request, never from the chain's ordering or clock; the settlement path never halts the token. A validation issued by an approval SHOULD wait for finality all the same: a reorg can drop the approval and the approver answer otherwise, which leaves the executed leg parked. Which route a validation takes is the token's routing, not this table's |
| `RECEIPT`, `BURN_PROOF` | MUST wait for the satellite chain's finality | the reference chain applies a report once and cannot take it back; a leg or a burn its chain later reorgs away would stay on the ledger for a movement that never happened |
| `MOVE_OUT`, `BRING_HOME` | MUST wait for finality | `delegationId` and `recallId` are counters, assigned by inclusion order; a reorg can give the same id to another instruction |

A Lite that executes a validation before finality owns the reorg exposure, and the reference chain bounds it to
that chain. Three things can happen to an issuance after the Lite acted on it, and each has one outcome:

- **Re-included in another order.** The id is the same, since it never depended on the order. Nothing to do.
- **Dropped.** The leg reaches the reference chain under an id nothing is issued under: the leg is parked
  (`ReceiptWaiting`, `waitingReceiptOf`) and the chain's inbound is paused. Neither the request sent again nor
  `applyWaitingReceipt` goes through while that pause stands. Once the pause is lifted, the request
  sent again with the same terms and `salt` issues the same id and sends no leg to the chain that already executed; the body
  carries the `salt`, so an agent can send it on the requester's behalf from the Lite's copy. Anyone then calls
  `applyWaitingReceipt(ticketId, chainKey)`, which judges the leg as a delivery would (`WaitingReceiptApplied`, or one
  of the outcomes below); a leg that reverts there stays parked and is tried again, and once the keeper resolved
  the pair it ends as a replay. While a leg is parked under an id its validation is not discarded
  (`ApplyWaitingReceiptFirst`): the report is already here and is settled first. When the request can no longer be issued, because a rule that allowed it now
  refuses it or an `APPROVAL` module refuses it this time, the leg stays parked and readable through
  `waitingReceiptOf`: nothing is applied and the ledger does not follow what the Lite executed. No function takes
  such a leg in or sends it back today: that exit needs a contract change.
- **Mined again in another block.** The id is the same and the ask block hash is not: the copy home now holds may
  have another `amountMax` or `validUntil`. The ask block hash the receipt echoes tells the two cases apart. A leg
  inside the issued terms settles whatever copy it echoes (`SettlementBodyDiverged` when it is not the issued one).
  A leg outside the terms with the issued ask block hash is a Lite that broke rule 5 or 6 (`ReceiptRefused`); one
  with another ask block hash, from a chain the validation involves, executed a copy from a block a reorg dropped
  (`ValidationOrphaned`): while `Open` the validation ends `Orphaned` and its reservation is released, otherwise it
  stands. A leg from any other chain is rejected whatever it echoes, since that chain could not have executed
  anything under the id. Nothing is applied either way, and the chain is paused.

The ask block hash holds the block number, the hash of the block before and the terms home narrows: two sibling
blocks at one height share number and parent, so the terms tell their copies apart. Home writes it at the ask and
only compares it later, so it never reads a block hash older than the chain serves (8,191 blocks, EIP-2935).

## Retries

Nothing is written off; a lost message is sent again.

| Lost | Who retries | How |
|---|---|---|
| validation leg | sender's identity, recipient's identity for the leg toward the recipient's chain, or agent | `sendTicket(ticketId, chainKey, to, spender)`: either leg while `Open` and before `validUntil`; the receiving chain's leg also once the burn landed, before `waitingEndsAt`, so the leg cannot land after the pair was resolved and the burned amount returned; rebuilt from the record, `to` and `spender` checked against the ones asked with, and the recorded ask block hash sent again; goes out as the issuance did, on the fast route when one is set and on the final route otherwise, and only while the final route and the peer are still the ones the issuance pinned; refused while issuance toward that chain is paused or the token is paused; nothing counts or spaces resends, the token forwards no value and the Lite ignores a leg it holds |
| mint instruction | agent | `resend(0, delegationId, abi.encode(toWallet, amount, holder, peer))`, the fields from `DelegatedOut` and the peer at dispatch; checked against the stored commitment |
| recall instruction | agent | `resend(1, recallId, abi.encode(wallet))`; the admitted gateway moves to the current route, which delivers the resend |
| burn proof | Lite operator | resend the stored proof; the token settles it once |
| a proof delivered twice | nobody | the token recognises the settled proof and changes nothing (`BurnProofDuplicate`) |

A resend never retargets: it is refused (`PeerChanged`) once the chain's peer is no longer the one the instruction
was addressed to. A resend after a route switch is the expected way to recover a recall whose original gateway is gone.
A validation leg is the exception: its settlement is matched against the gateway and the peer it was pinned to, so
after a route switch or a peer change the leg is not resent (`ValidationAlreadyRouted`). While `Open`, the
reservation comes back through discard at `waitingEndsAt` and a new validation is requested. Once the burn landed, the
pair cannot be discarded: its exit is `resolveStuckValidation` after the second window, which returns the burned
amount to the sender. The leg already sent keeps settling from the peer it was sent to.

## What the reference chain does with a Lite that breaks a rule

| Broken rule | Reference-chain reaction |
|---|---|
| 3, 7: a settlement leg for a validation already settled, other than the applied leg itself, a leg for a pair the keeper already resolved, or a second, different leg from one chain for a parked id | `ReplayedSettlement`, the token stops taking that chain's messages (`setInboundPaused`) |
| a leg already consumed, whether applied, parked or refused, delivered again byte for byte (a gateway redelivery, or the Lite resending its settlement) | `ReceiptDuplicate`, consumed, nothing applied, nothing paused; a chain paused over the first delivery and reopened stays open |
| a settlement for a validation never issued, or recorded but never sent | `ReceiptWaiting`, the leg kept under its id, the token stops taking that chain's messages; once the request is sent again with the same terms and salt, `applyWaitingReceipt` settles it |
| 5, 6: amount outside the range, wrong wallets or chain, under the issued ask block hash | `ReceiptRefused`, consumed, the token stops taking that chain's messages; the validation stands |
| 5, 6 under another ask block hash: a copy from a block a reorg dropped | `ValidationOrphaned`, consumed, the token stops taking that chain's messages; `Orphaned` while no leg had landed |
| 8: two legs with two amounts | `SettlementAmountMismatch` on the second; the keeper resolves the pair after the second window |
| 10: proof above the instruction | `RecallAmountExceeded`, stays deliverable |
| 10: proof for another wallet | `RecallMismatch`, stays deliverable |
| 10: a different proof for a settled recall | `ReplayedBurnProof`, the token stops taking that chain's messages |
| a proof for a recall never issued | `ReplayedBurnProof`, the token pauses itself |

A settlement leg never reverts for what it carries: every leg the token cannot account for is consumed with the
chain's inbound paused, so nothing stays deliverable for good and nothing is lost, see "Lanes". A reverted
delivery, from a tracker module for instance, can be redelivered once the cause is understood, on the assumption
that the ERC-7786 gateway keeps a reverted execution retryable; a gateway that marks it failed for good loses the
message, and its author has to send it again. Either pause is lifted by the pauser after an investigation:
`setInboundPaused(chainKey, false)` for one chain, `unpause` for the token. While a chain's inbound is paused its deliveries revert with
`AwayChainBlocked` and wait at the gateway; a delegation toward it is refused, and the compliance neither issues a
validation toward it nor resends one, nor discards or resolves a validation still awaiting that chain's leg, since
the held reports may answer it and acting on their absence would release or return what they move. Native transfers,
every other chain, and recall instructions and instruction resends toward the paused chain are unaffected; the proof
answering a recall lands once the pause is lifted. To abandon a chain for good: distrust its gateway or close its
route, then lift the pause so its validations can be discarded and resolved.

Threat model, stated plainly. A trusted gateway, or the registered peer behind it, can stop its own chain's inbound
with one message, and a settlement can do little more: a validation id is a function of the request, so a leg for
an id the token never issued is the leg's chain's problem, a reorg's or the peer's, and is parked under the chain
pause rather than halting the token. The one reach beyond its own chain: on a two-leg validation, a peer that
echoes a foreign ask block hash on a leg outside the terms ends the pair `Orphaned`, so the honest leg from the other chain
then lands as a replay and pauses that chain too. That peer is involved in the validation and hostile, and is
answered as any hostile peer is. A burn proof naming a recall never issued still pauses the whole token, with
its price: recall ids are counters and wait for finality, so an unknown one has two readings the token cannot tell
apart, the peer invented it, or the token's own records are out of step with what it dispatched, which is local
and must not keep running. The remedy against a peer abusing either is to distrust its gateway.

### The brakes

| Brake | Stops | Set by | Lifted by |
|---|---|---|---|
| token pause, `pause` | every balance movement between wallets, native or satellite, and every inbound settlement and proof; new validations, approvals into issuance and validation resends; discards and resolutions of validations that may have a leg waiting | the pauser; the token itself on a proof for a recall it never issued | the pauser, `unpause` |
| chain inbound pause, `setInboundPaused` | every message from one chain; delegations, new validations and validation resends toward it; discards and resolutions of validations still awaiting its leg | the pauser; the token itself on every settlement leg from that chain it cannot account for (replayed, parked, rejected, orphaned) and on a conflicting proof from that chain | the pauser, `setInboundPaused(chainKey, false)` |
| chain issuance pause, `setIssuancePaused` on the compliance | new validations and validation resends toward one chain | the compliance manager; the compliance itself on a late settlement that breaches a rule, or a stuck pair resolved with the burn still owed | the compliance manager |
| route close, `setReceiptRoute(..., 0)` | every send toward one chain and every message from it, a settlement of a validation already sent and a proof for an open recall included (`ChainNotOpen`); they stay deliverable and land once a route is set again | the identity manager | the identity manager, with a trusted gateway |
| gateway distrust, `TrustedGatewayRegistry` | every message through that gateway, pinned or not, for every token | the registry's owner | the registry's owner |

Before lifting the token pause or a chain pause, the operator has the gateway discard the deliveries refused while
it was paused that should never land: lifting a pause lets every pending delivery through, and while the replay that
triggered it is consumed, a misbehaving peer may have queued more.

A peer replaced with `setPeer` while recalls are open keeps the authority to settle those recalls, through their
pinned gateway, for up to the instructed amounts: that is what lets a recall survive a planned peer change. When the
peer is replaced because it is hostile, the operator first distrusts its gateway in `TrustedGatewayRegistry`, since a
distrusted gateway is refused even when pinned, or drains the open recalls before switching.

## Assumptions and accepted limitations

- **Sticky satellite bindings.** A satellite wallet's identity binding in the ONCHAINID IdentityFactory does not move
  to another identity while the wallet holds a position. The bridged ledger keeps no owner record for satellite
  wallets and relies on this.
- **Gateway fees.** The token forwards no value to the gateway, so only gateway adapters that require no value from
  the sender are supported in this release.
- **Permanent loss of a trusted gateway or peer** with instructions or validations outstanding needs a separately
  reviewed migration procedure; it is not covered here.
- **A native wallet unlinked after a recall was instructed:** the proof reverts `WalletsNotLinked` and stays
  deliverable; repair the link, then redeliver. An identity deleted while a satellite position is outstanding is
  re-registered first.
- **A lost message is recovered by retry, not by write-off.** There is no proof-free recovery and no recall cancel.

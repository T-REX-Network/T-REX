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
| out | `RECEIPT` | `ReceiptMessage { ticketId, from, to, amount, askBlockHash, seenMax, seenValidUntil, half, answer }` | one per ticket it executed, echoing the copy it executed under: its `askBlockHash`, its `amountMax` as `seenMax` and its `validUntil` as `seenValidUntil`; `half` is 0 and `answer` is `Executed` |
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
`StillOpen` (never executed, still before its valid until). A Lite reports `Executed` for every ticket it executed;
home reads the other two once it asks a Lite for a receipt. A still open answer is not an answer to an ask: home
raises the ticket's `seenValidUntil` up to its valid until plus the chain's full finality delivery and clock lead, and
cancels only after an ask went unanswered for one waiting time. The Lite must ignore a ticket whose valid until is
further ahead of its own clock than the validity window plus its lag budget, so a forged far valid until is never
held.

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
2a. **Send every receipt on the receipt route, at full finality.** A chain may have two routes on the reference
   side: a ticket route, set with `setTicketRoute` to a ticket bridge, that carries tickets out ahead of finality and
   nothing else, and the receipt route, set with `setReceiptRoute` to a receipt bridge, that carries money messages out
   and is the only one receipts and burn proofs are taken from. The token takes deliveries from receipt bridges only,
   so a ticket bridge's delivery is refused (`ERC7786RecipientUnauthorizedGateway`), and it reads the receipt
   bridge's receiving policy for this chain's receipt bridge when the route is set and on every receipt, refusing
   one that admits less than full finality (`ReceiptBridgeNotFullFinality`). Each half is pinned to the receipt route
   and the peer it left through (`pinOf`), and its receipt is taken from that pair or the current one, so a ticket
   that arrived on the ticket bridge is answered through the receipt route, not back through the bridge that
   delivered it.

### Validations

3. **Execute a ticket once, and keep the first copy per id.** A ticket delivered again under a known id is never
   held in place of the first: a resend repeats it, and a later copy of the same ask, mined again in another block
   after a reorg (another `askBlockHash`, maybe another `amountMax` or `validUntil`), is ignored. The receipt echoes
   the copy held, and the reference chain tells which one it was.
4. Execute strictly before `validUntil`.
5. Execute an amount inside `[amountMin, amountMax]`.
6. Execute only for the named wallets, by `from` or by the named `spender`.
7. Report every ticket it executed, exactly once, echoing the copy it executed under (`askBlockHash`, `seenMax`,
   `seenValidUntil`) with `answer` `Executed`, and both wallets. A report lost on the way may be sent again byte for
   byte: the reference chain keeps one receipt per half, recognises the same one again (`ReceiptDuplicate`) and
   changes nothing; another receipt for a half that already has one blocks the Lite's chain.

### The two-leg invariant

8. **The receiving Lite mints only on the sending Lite's burn message**, carried by a trusted gateway and authored by
   that Lite, for the amount it carries, never from the validation alone. This is what makes a range safe on a
   two-leg validation. The receiving Lite's own copy
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
| `TICKET` | may ride before finality | `ticketId` is built from the whole request, never from the chain's ordering or clock; a receipt never stops the token. A ticket an approval opened SHOULD wait for finality all the same: a reorg can drop the approval after the away token executed the ticket. Which route a ticket takes is the token's routing, not this table's |
| `RECEIPT`, `BURN_PROOF` | MUST wait for the satellite chain's finality | the reference chain applies a report once and cannot take it back; a receipt or a burn its chain later reorgs away would stay on the ledger for a movement that never happened |
| `MOVE_OUT`, `BRING_HOME` | MUST wait for finality | `delegationId` and `recallId` are counters, assigned by inclusion order; a reorg can give the same id to another instruction |

A Lite that executes a validation before finality owns the reorg exposure, and the reference chain bounds it to
that chain. Three things can happen to an issuance after the Lite acted on it, and each has one outcome:

- **Re-included in another order.** The id is the same, since it never depended on the order. Nothing to do.
- **Dropped.** The receipt reaches the reference chain under an id home has no record of: the delivery reverts
  and stays deliverable at the bridge, and no chain is blocked. The request sent again with the same terms and
  `salt` takes the same id; the body carries the `salt`, so an agent can send it on the requester's behalf from the
  Lite's copy. The receipt delivered again is then applied on the older terms it echoes, as below. When the request
  sent again waits for an `APPROVAL` module, the receipt waits under its half (`ReceiptWaiting`, `waitingReceiptOf`)
  and anyone applies it with `applyWaitingReceipt(halfKey, receipt)` once the approval sent the ticket; while a
  receipt for the ticket waits and can be applied, the ticket is not cancelled (`ApplyWaitingReceiptFirst`). When the request is refused
  this time, the receipt stays waiting and readable: nothing is applied and the ledger does not follow what the
  Lite executed. No function takes such a receipt in or sends it back today: that exit needs a contract change.
- **Mined again in another block.** The id is the same and the ask block hash is not: the copy home now holds may
  have another `amountMax` or `validUntil`. The ask block hash the receipt echoes tells the two cases apart. On
  home's own ask block hash the receipt must echo home's own terms and move an amount inside them. On another one it
  answers a copy from a block a reorg dropped (`ReceiptOnOlderTerms`): it is allowed up to `requestedMax` and the
  away chain's per-ticket cap, with an amount inside the range of the copy it echoes. Either way the receipt is
  applied as it happened, since the Lite's balances already moved; one that breaks its terms also blocks its chain.
  A receipt from a chain the ticket was not sent to, or for other wallets, is refused and blocks that chain.

The ask block hash holds the block number, the hash of the block before and the terms home narrows: two sibling
blocks at one height share number and parent, so the terms tell their copies apart. Home writes it at the ask and
only compares it later, so it never reads a block hash older than the chain serves (8,191 blocks, EIP-2935).

## Retries

Nothing is written off; a lost message is sent again.

| Lost | Who retries | How |
|---|---|---|
| ticket (an ask for its receipt) | anyone | `sendTicket(ticketId, chainKey, to, spender)`: while `Open`, three asks at most, the first one waiting time after the later of `validUntil` and `seenValidUntil`, each next one a waiting time later; rebuilt from the record, `to` and `spender` checked against the ones asked with, and the recorded ask block hash sent again; goes out on the ticket route when one is set and on the receipt route otherwise, to the pinned pair while it is the current pair or the former pair inside its window, and to the current pair otherwise; refused while that away chain is blocked or the token is paused; the Lite answers this later copy with its stored receipt, a zero receipt (`Expired`) or a still open answer |
| mint instruction | agent | `resend(0, delegationId, abi.encode(toWallet, amount, holder, peer))`, the fields from `DelegatedOut` and the peer at dispatch; checked against the stored commitment |
| recall instruction | agent | `resend(1, recallId, abi.encode(wallet))`; the admitted gateway moves to the current route, which delivers the resend |
| burn proof | Lite operator | resend the stored proof; the token settles it once |
| a proof delivered twice | nobody | the token recognises the settled proof and changes nothing (`BurnProofDuplicate`) |

A resend never retargets: it is refused (`PeerChanged`) once the chain's peer is no longer the one the instruction
was addressed to. A resend after a route switch is the expected way to recover a recall whose original gateway is gone.
A ticket is the exception: its receipt is taken from the bridge and the peer it was pinned to, so after a route
switch or a peer change an ask for its receipt still goes to the pinned pair while that pair is the former one inside
its window (the away token holding the ticket is the one that answers), and to the current pair after. Its
reservation comes back through a cancel once an ask for its receipt went unanswered.

## Changing a route or a peer

A planned change (`setReceiptRoute` on an open route, or `setPeer`) is made on home first. Home keeps the route and
peer the chain had as its former pair and takes every receipt from it for four waiting times of that away chain
(`FormerRouteKept`, the waiting time read from the compliance at the change). The Lite switches only after home's
change is final, early enough that its last receipts on the old pair land inside those four waiting times. A second
change of route or peer on that chain inside the window is refused (`RouteChangedTooRecently`): it would drop the
former pair. A receipt that came on the former pair inside the window and then waited (chain blocked, token stopped)
stays applicable after the window ends. The accepted cost: an old peer that turns hostile inside the window can have
home apply receipts it forges, for any ticket of that chain. When an away chain is first opened, set its peer before
its receipt route: a change on a chain that has a route starts a change window.

A hostile peer is replaced with `replaceHostilePeer`, never with `setPeer`. Home keeps no former pair, and for four
waiting times of that away chain no ask, no ticket send, no ask for a receipt and no cancel runs for it
(`HostileChangeNotOver`); receipts still land. Halves pinned to the hostile peer keep their receipt from it: for full
containment the operator also distrusts its bridge.

## What the reference chain does with a Lite that breaks a rule

| Broken rule | Reference-chain reaction |
|---|---|
| 3, 7: another receipt for a half that already has one, applied or waiting | `ReceiptRefused`, consumed, nothing applied, the compliance blocks that away chain (`blockAwayChain`) |
| the receipt home holds for a half, delivered again byte for byte (a bridge redelivery, or the Lite resending its receipt) | `ReceiptDuplicate`, consumed, nothing applied, nothing blocked; a chain blocked over the first delivery and reopened stays open |
| a receipt for an id home has no record of | reverts with `UnknownTicket` and stays deliverable; nothing is blocked; once the request is sent again with the same terms and salt, the receipt lands |
| a good receipt that cannot be applied yet: its ticket never sent, the token stopped, its away chain blocked, or the sender's away balance too low | `ReceiptWaiting`, consumed and kept under its half with the bridge and peer that brought it, nothing blocked; anyone applies it with `applyWaitingReceipt` once it can be, after the route check runs again on that bridge and peer; the same receipt delivered again then applies it too |
| 6: wrong wallets, a chain the ticket was not sent to, a half home never sent, or an expired answer that moved something | `ReceiptRefused`, consumed, nothing applied, the compliance blocks that away chain; the ticket stands |
| 5: an amount outside the range, or other terms echoed, under home's own ask block hash; or, under another ask block hash, a copy above `requestedMax` or the per-ticket cap | applied as it happened, then the compliance blocks that away chain |
| 10: proof above the instruction | `RecallAmountExceeded`, stays deliverable |
| 10: proof for another wallet | `RecallMismatch`, stays deliverable |
| 10: a different proof for a settled recall | `ReplayedBurnProof`, the compliance blocks that away chain |
| a proof for a recall never issued | reverts with `RecallNotPending` and stays deliverable; nothing stops |

A receipt for a ticket home knows never reverts for what it carries: it is applied as it happened or refused, and
consumed either way, see "Lanes". A receipt or a proof for an id home does not know reverts and stays deliverable,
blocking nobody. A reverted
delivery, from a tracker module for instance, can be redelivered once the cause is understood, on the assumption
that the ERC-7786 gateway keeps a reverted execution retryable; a gateway that marks it failed for good loses the
message, and its author has to send it again. The block of an away chain and the stop of the token are lifted by the
pauser after an investigation: `unblockAwayChain(chainKey)` on the compliance for one chain, `unpause` for the token.
While a chain is blocked its good receipts are consumed and wait at home, and its burn proofs revert with
`AwayChainBlocked` and wait at the gateway; a delegation toward it is refused, and the compliance neither issues a
ticket toward it nor asks for a receipt there, nor cancels any of its tickets, a ticket waiting for approval included, since the
waiting receipts may answer them and acting on their absence would release what they move. Native transfers, every
other chain, and recall instructions and instruction resends toward the blocked chain are unaffected; the proof
answering a recall lands once the block is lifted. To abandon a chain for good: distrust its gateway or close its
route, refuse the receipts it left waiting, then lift the block so its tickets can be cancelled.

Threat model, stated plainly. A trusted gateway, or the registered peer behind it, can stop its own chain's inbound
with one bad receipt, and a receipt can do little more: it is applied as it happened on its own chain, bounded by
`requestedMax` and the per-ticket cap on older terms, and a receipt for an id the token never issued reverts and
blocks nobody. Nothing a message says stops the whole token: a burn proof naming a recall never issued reverts and
stays deliverable too. The remedy against a peer abusing its chain is to distrust its gateway.

### The brakes

| Brake | Stops | Set by | Lifted by |
|---|---|---|---|
| token pause, `pause` | every balance movement between wallets, native or satellite; every inbound receipt waits at home and every proof reverts; new tickets, approvals into issuance and asks for receipts; cancels of tickets whose receipt may be waiting | the pauser | the pauser, `unpause` |
| block an away chain, `blockAwayChain` on the compliance | applying one chain's receipts (they wait at home) and its proofs; delegations, new tickets and asks for receipts toward it; cancels of its tickets | the pauser; the compliance itself on a bad receipt from that chain or a receipt that breaks its terms; the token on a conflicting proof from that chain | the pauser, `unblockAwayChain` |
| hostile peer replaced, `replaceHostilePeer` | asks, ticket sends, asks for receipts and cancels for one away chain, for four of its waiting times (`HostileChangeNotOver`); receipts still land | the identity manager | nobody: it ends by itself at `hostileChangeEndsAt` |
| receipt route close, `closeReceiptRoute` | every send toward one chain and every message from it, a receipt of a half already sent and a proof for an open recall included (`ChainNotOpen`); they stay deliverable and land once a route is set again; no ticket toward that chain is cancelled meanwhile | the identity manager | the identity manager, `setReceiptRoute` with a receipt bridge |
| bridge distrust, `distrustBridge` on `TrustedGatewayRegistry` | every message through that bridge, pinned or not, for every token; no ticket whose receipt route it is is cancelled meanwhile | the registry's interop manager | never: a distrusted bridge is never trusted again, so the receipt route is set to a new receipt bridge |

Before lifting the token pause or the block of a chain, the operator refuses the receipts that waited and should
never be applied, with `refuseWaitingReceipt(halfKey)` while the chain is still blocked, and has the gateway discard
the proofs refused meanwhile that should never land: once lifted, anyone applies what waits and every pending
delivery goes through. A waiting receipt is applied only after the route check runs again on the bridge and peer
that brought it, so one from a bridge distrusted meanwhile is never applied.

A peer replaced with `setPeer` while recalls are open keeps the authority to settle those recalls, through their
pinned gateway, for up to the instructed amounts: that is what lets a recall survive a planned peer change. When the
peer is replaced because it is hostile (`replaceHostilePeer`), the operator first distrusts its gateway in `TrustedGatewayRegistry`, since a
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

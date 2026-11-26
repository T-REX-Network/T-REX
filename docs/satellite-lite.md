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
| in | `MOVE_OUT` | `MoveOutMessage { ticketId, half, toWallet, amount, validUntil }` | the second half of a move: mints `amount` to `toWallet` once per half, strictly before the half's `validUntil`, then answers with a `RECEIPT` for that half |
| in | `BRING_HOME` | `BringHomeMessage { ticketId, half, wallet, amount, validUntil }` | the half of a bring home: burns `min(amount, balance)` of `wallet` once per half, strictly before the half's `validUntil`, then answers with a `RECEIPT` for that half |
| out | `RECEIPT` | `ReceiptMessage { ticketId, from, to, amount, askBlockHash, seenMax, seenValidUntil, half, answer }` | one per ticket it executed, echoing the copy it executed under: its `askBlockHash`, its `amountMax` as `seenMax` and its `validUntil` as `seenValidUntil`; `half` is 0 and `answer` is `Executed`. One per move out it answered: `half` is the move out's, `from` is empty, `to` is `toWallet`, the ticket fields are zero, and either `amount` is the move out's and `answer` is `Executed`, or `amount` is 0 and `answer` is `Expired`. One per bring home half it answered: `half` is the bring home's, `from` is `wallet`, `to` is empty, the ticket fields are zero, and either `amount` is what it burned, possibly 0, and `answer` is `Executed`, or `amount` is 0 and `answer` is `Expired` |

Every message carries the envelope version 2 (`MessageTypesLib.VERSION`); a message of any other version is refused,
on both sides.

The ticket id is built from the whole request: `keccak256(abi.encode(kind, fromKey, toKey, spenderKey, amountMin,
requestedMax, salt))`, where the keys are `keccak256` of the canonical envelopes (of empty bytes for no spender) and
`kind` is 0 for a move and 1 for a bring home. The same ask mined in any block gets the same id. The ask block hash,
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

A move out of an away wallet toward another chain is one ticket, to the sender's away chain only. The Lite burns and
sends its receipt; home puts the amount on hold, asks the rules again for the receiver and sends a `MOVE_OUT`, the
second half, to the receiver's chain, or back to the sender's wallet when the rules refuse it. A move toward a home
wallet is minted at home in the receipt's delivery. A home wallet that moves out to an away wallet is the same move
with no first half: home burns at the ask and sends the `MOVE_OUT`. Away tokens never talk to each other.

A bring home is a ticket too, of kind `BRING_HOME`, written by an agent with `bringHome(awayWallet, amount,
homeWallet, salt)` on the compliance for two wallets of one identity. It reserves `amount` on the away wallet in the
same table as every ticket, so no ticket and no bring home count on the same tokens, and at most one is open per
away wallet. Its half is a `BRING_HOME` with its own valid until, sent on the receipt route. The Lite's receipt for
that half is applied as any receipt: what was burned is minted at the home wallet, or sent back to the away wallet
by a `MOVE_OUT` when the home wallet is no longer the identity's; a zero answer ends the bring home with nothing
moved.

Every message travels through a gateway the network's `TrustedGatewayRegistry` trusts. The token accepts a receipt
from the pair its half was pinned to or from the chain's current peer. A move out's receipt must come from the chain of
the wallet it minted to, and a bring home's from the chain of the wallet it burned: the compliance refuses one from any
other chain, and blocks that chain.

## Rules

### Transport

1. **Act on each delivery once.** A gateway may redeliver; the Lite dedupes on a nonzero receive id, and also on
   the operation id, since a resend arrives under a new receive id: `ticketId` for a validation, see rule 3 for
   what a second body under a known id means, and the half of rules 9 and 10. A zero receive id names
   no delivery (ERC-7786 allows it) and is never recorded, or the first one would refuse every later message.
2. **Accept only the reference token as author**, through its own gateway; never act on a message from another away
   token.
2a. **Send every receipt on the receipt route, at full finality.** A chain may have two routes on the reference
   side: a ticket route, set with `setTicketRoute` to a ticket bridge, that carries tickets out ahead of finality and
   nothing else, and the receipt route, set with `setReceiptRoute` to a receipt bridge, that carries money messages out
   and is the only one receipts are taken from. The token takes deliveries from receipt bridges only,
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

### Instructions

Rule 8, the two-leg invariant, is gone: a receiving Lite no longer mints on the sending Lite's burn message. It
mints on home's move out only (rule 9), and never acts on a message from another away token (rule 2).

9. **A move out mints at most once per half**, keyed by `(ticketId, half)`, strictly before the half's `validUntil` on
   the Lite's own clock, and answers with one receipt for that half. A move out that arrives at or after its
   `validUntil`, never executed, is answered with a zero receipt (`Expired`), stored, and that half is never executed
   afterwards: home then sends a new half. The same half again is answered with the stored receipt, byte for byte.
   Home already holds the amount on hold; a Lite that mints twice has inflated its chain.
10. **A bring home burns at most once per half**, keyed by `(ticketId, half)`, strictly before the half's `validUntil`
    on the Lite's own clock. The Lite burns `min(amount, balance)`, down to zero, and answers with one receipt for that
    half naming the burned wallet. A bring home that arrives at or after its `validUntil`, never executed, is answered
    with a zero receipt (`Expired`), stored, and that half is never executed afterwards. The same half again is
    answered with the stored receipt, byte for byte. The Lite never burns more than `amount` and never burns for an
    older half: home holds `amount` reserved on the wallet until the receipt lands, so no ticket asked meanwhile
    draws on it, and mints at the home wallet the ticket recorded, not one the receipt could choose.

## Lanes

A message may be attested to a Lite before the reference chain reaches finality only when nothing it carries
depends on which block, or in which order, its transaction landed. That holds for one type:

| Type | Lane | Why |
|---|---|---|
| `TICKET` | may ride before finality | `ticketId` is built from the whole request, never from the chain's ordering or clock; a receipt never stops the token. A ticket an approval opened SHOULD wait for finality all the same: a reorg can drop the approval after the away token executed the ticket. Which route a ticket takes is the token's routing, not this table's |
| `RECEIPT` | MUST wait for the satellite chain's finality | the reference chain applies a report once and cannot take it back; a receipt or a burn its chain later reorgs away would stay on the ledger for a movement that never happened |
| `MOVE_OUT`, `BRING_HOME` | MUST wait for finality | they move value: home sends them only on its receipt route, at full finality |

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
| move out (a second half) | anyone | `sendSecondHalf(ticketId, wallet)`, `wallet` read off `SecondHalfSent`: an owed half (answered `Expired`, or its send failed inside the receipt's delivery) is sent as a new half with a fresh valid until, at most four halves per money on hold (`NoNewHalfLeft`); otherwise the latest half is sent again byte for byte, three sends at most, at fixed times: one waiting time of its chain after its valid until, then two more. A half whose pinned pair is no longer the chain's current pair goes to the current pair as a new half; otherwise it goes to the pinned pair only |
| bring home, or its receipt | anyone | `sendSecondHalf(ticketId, awayWallet)` while the bring home is open, at the same fixed times as a move out; the Lite answers with its stored receipt or a zero receipt (`Expired`), which ends the bring home with nothing moved. A half whose pinned pair is no longer the chain's current pair goes to the current pair as a new half |

A half sent again never retargets: the token refuses it (`PeerChanged`) once its pinned pair is no longer the
chain's current pair, and the compliance sends a new half to the current pair instead, past the old half's valid until.
A ticket's receipt is taken from the bridge and the peer it was pinned to, so after a route switch or a peer change an
ask for its receipt still goes to the pinned pair while that pair is the former one inside its window (the away token
holding the ticket is the one that answers), and to the current pair after. Its reservation comes back through a
cancel once an ask for its receipt went unanswered. A bring home is never cancelled: it ends on its receipt.

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
| 9: a move out's receipt from a chain the half was not sent to, naming a sender, minting another amount, or minting an older half | `ReceiptRefused`, consumed, nothing applied, the compliance blocks that away chain |
| a move out's receipt with less gas left than home's send of a new half needs, where one is sent | reverts with `NotEnoughGasForTheSecondHalf` and stays deliverable |
| 5: an amount outside the range, or other terms echoed, under home's own ask block hash; or, under another ask block hash, a copy above `requestedMax` or the per-ticket cap | applied as it happened, then the compliance blocks that away chain |
| 10: a bring home's receipt from another chain, for another wallet, naming a receiver, burning more than the bring home's amount, or burning for an older half | `ReceiptRefused`, consumed, nothing applied, the compliance blocks that away chain |

A receipt for a ticket home knows never reverts for what it carries: it is applied as it happened or refused, and
consumed either way, see "Lanes". A receipt for an id home does not know reverts and stays deliverable,
blocking nobody. A reverted
delivery, from a tracker module for instance, can be redelivered once the cause is understood, on the assumption
that the ERC-7786 gateway keeps a reverted execution retryable; a gateway that marks it failed for good loses the
message, and its author has to send it again. The block of an away chain and the stop of the token are lifted by the
pauser after an investigation: `unblockAwayChain(chainKey)` on the compliance for one chain, `unpause` for the token.
While a chain is blocked its good receipts are consumed and wait at home; a move out toward it is not sent (a move
to it is returned to the sender instead), no bring home is written or sent again toward it, and the compliance neither
issues a ticket toward it nor asks for a receipt there, nor cancels any of its tickets, a ticket waiting for approval
included, since the waiting receipts may answer them and acting on their absence would release what they move. Native
transfers and every other chain are unaffected. To abandon a chain for good: distrust its gateway or close its
route, refuse the receipts it left waiting, then lift the block so its tickets can be cancelled.

Threat model, stated plainly. A trusted gateway, or the registered peer behind it, can stop its own chain's inbound
with one bad receipt, and a receipt can do little more: it is applied as it happened on its own chain, bounded by
`requestedMax` and the per-ticket cap on older terms, and a receipt for an id the token never issued reverts and
blocks nobody. Nothing a message says stops the whole token. The remedy against a peer abusing its chain is to
distrust its gateway.

### The brakes

| Brake | Stops | Set by | Lifted by |
|---|---|---|---|
| token pause, `pause` | every balance movement between wallets, native or satellite; every inbound receipt waits at home; new tickets, bring homes, approvals into issuance and asks for receipts; cancels of tickets whose receipt may be waiting | the pauser | the pauser, `unpause` |
| block an away chain, `blockAwayChain` on the compliance | applying one chain's receipts (they wait at home); move outs, bring homes, new tickets and asks for receipts toward it; cancels of its tickets | the pauser; the compliance itself on a bad receipt from that chain or a receipt that breaks its terms | the pauser, `unblockAwayChain` |
| hostile peer replaced, `replaceHostilePeer` | asks, ticket sends, asks for receipts and cancels for one away chain, for four of its waiting times (`HostileChangeNotOver`); receipts still land | the identity manager | nobody: it ends by itself at `hostileChangeEndsAt` |
| receipt route close, `closeReceiptRoute` | every send toward one chain and every message from it, a receipt of a half already sent included (`ChainNotOpen`); they stay deliverable and land once a route is set again; no ticket toward that chain is cancelled meanwhile | the identity manager | the identity manager, `setReceiptRoute` with a receipt bridge |
| bridge distrust, `distrustBridge` on `TrustedGatewayRegistry` | every message through that bridge, pinned or not, for every token; no ticket whose receipt route it is is cancelled meanwhile | the registry's interop manager | never: a distrusted bridge is never trusted again, so the receipt route is set to a new receipt bridge |

Before lifting the token pause or the block of a chain, the operator refuses the receipts that waited and should
never be applied, with `refuseWaitingReceipt(halfKey)` while the chain is still blocked: once lifted, anyone applies
what waits and every pending delivery goes through. A waiting receipt is applied only after the route check runs again
on the bridge and peer that brought it, so one from a bridge distrusted meanwhile is never applied.

## Assumptions and accepted limitations

- **Sticky satellite bindings.** A satellite wallet's identity binding in the ONCHAINID IdentityFactory does not move
  to another identity while the wallet holds a position. The bridged ledger keeps no owner record for satellite
  wallets and relies on this.
- **Gateway fees.** The token forwards no value to the gateway, so only gateway adapters that require no value from
  the sender are supported in this release.
- **Permanent loss of a trusted gateway or peer** with instructions or validations outstanding needs a separately
  reviewed migration procedure; it is not covered here.
- **A home wallet unlinked or no longer verified after a bring home was written:** what the away token burned goes
  back to the away wallet by a `MOVE_OUT`; the agent brings it home again to a wallet of the identity. An identity
  deleted while a satellite position is outstanding is re-registered first.
- **A lost message is recovered by retry, not by write-off.** A bring home is not cancelled; it ends on its receipt.

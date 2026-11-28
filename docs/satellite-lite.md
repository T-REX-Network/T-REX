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
| in | `TICKET` | `TicketMessage { ticketId, kind, salt, from, to, spender, amountMin, amountMax, requestedMax, token, validUntil, askBlockHash }` | stores the first copy under `ticketId`; `kind` is hashed into the id with the other terms, and home sends only a move (`kind` 0) as a ticket; a later copy is an ask for the receipt, see rule 3 |
| in | `MOVE_OUT` | `MoveOutMessage { ticketId, half, toWallet, amount, validUntil }` | the second half of a move: mints `amount` to `toWallet` once per half, strictly before the half's `validUntil`, then answers with a `RECEIPT` for that half |
| in | `BRING_HOME` | `BringHomeMessage { ticketId, half, wallet, amount, validUntil }` | the half of a bring home: burns `min(amount, balance)` of `wallet` once per half, strictly before the half's `validUntil`, then answers with a `RECEIPT` for that half |
| out | `RECEIPT` | `ReceiptMessage { ticketId, from, to, amount, askBlockHash, seenMax, seenValidUntil, half, answer }` | one per ticket it executed, echoing the copy it executed under: its `askBlockHash`, its `amountMax` as `seenMax` and its `validUntil` as `seenValidUntil`; `half` is 0 and `answer` is `Executed`. One per move out it answered: `half` is the move out's, `from` is empty, `to` is `toWallet`, the ticket fields are zero, and either `amount` is the move out's and `answer` is `Executed`, or `amount` is 0 and `answer` is `Expired`. One per bring home half it answered: `half` is the bring home's, `from` is `wallet`, `to` is empty, the ticket fields are zero, and either `amount` is what it burned, possibly 0, and `answer` is `Executed`, or `amount` is 0 and `answer` is `Expired` |

Every message carries the envelope version 2 (`MessageTypesLib.VERSION`); a message of any other version is refused,
on both sides.

The ticket id is built from the whole request: `keccak256(abi.encode(kind, fromKey, toKey, spenderKey, amountMin,
requestedMax, salt))`, where the keys are `keccak256` of the canonical envelopes, `spenderKey` is zero when there is
no spender, and `kind` is 0 for a move and 1 for a bring home. The same ask mined in any block gets the same id. The ask block hash,
`keccak256(abi.encode(block.number, blockhash(block.number - 1), amountMax, validUntil))` read in the block that
issued the ticket, names the copy: two copies of one ask mined in two blocks share the id and differ in it.

`answer` says why a receipt says what it says, so a receipt of amount zero says why it is zero: `Executed` (the
copy echoed was executed, for `amount`, possibly zero), `Expired` (never executed and past its valid until) or
`StillOpen` (never executed, still before its valid until). A Lite reports `Executed` for every ticket it executed;
home reads the other two once it asks a Lite for a receipt. A still open answer is not an answer to an ask: home
raises the ticket's `seenValidUntil` up to its valid until plus the chain's full finality delivery and clock lead, and
cancels only after an ask went unanswered for one waiting time. A still open answer on home's own ask block hash must
echo home's own valid until: one echoing another is refused (`ReceiptRefused`, `AnotherValidUntil`), nothing is
applied, and the compliance blocks that away chain. The Lite must ignore a ticket whose valid until is
further ahead of its own clock than its valid until bound, so a forged far valid until is never held. The bound is
a setting of each away token, set per chain to home's longer validity window plus that chain's lag budget. Raise it
on every away token first, and only then raise a validity window at home (`setValidityWindows`): an away token
whose bound is below home's window ignores honest tickets, and their moves are cancelled after an unanswered ask.

A move out of an away wallet toward another chain is one ticket, to the sender's away chain only. The Lite burns and
sends its receipt; home puts the amount on hold, asks the rules again for the receiver and sends a `MOVE_OUT`, the
second half, to the receiver's chain, or back to the sender's wallet when the rules refuse it. A move toward a home
wallet is minted at home in the receipt's delivery. A home wallet that moves out to an away wallet is the same move
with no first half: home burns at the ask and sends the `MOVE_OUT`. Away tokens never talk to each other.

An ask is refused while asks are paused for the whole token or on any chain it involves, the sender's or the
receiver's (`setAsksPaused(chainKey, true)`, `AsksPaused`). The chain its first message goes to must be open, a
receipt route with a peer, checked at the ask itself, also when the ticket waits for an approval (`ChainNotOpen`).
A receiver on another away chain needs that chain unblocked, under no hostile change, with a waiting time and open
(`AwayChainBlocked`, `HostileChangeNotOver`, `WaitingTimeNotSet`, `ChainNotOpen`). Every later send, the first send
of an approved ticket, a resend or an ask for the receipt, needs that chain only unblocked (`AwayChainBlocked`): its
route may have closed, or its peer been replaced as hostile, since the ask, and the ticket and its answer travel
between home and the sender's chain only, so an unanswered ask can still cancel the ticket.

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

## Keys

Every wallet travels as an ERC-7930 interoperable address, version 1, and both sides hash the same bytes. For an EVM
chain (chain type `0x0000`) there is one spelling, the one `InteroperableAddress.formatEvmV1(chainId, account)` writes:

| Bytes | Field | Value |
|---|---|---|
| 2 | version | `0x0001` |
| 2 | chain type | `0x0000` |
| 1 | chain reference length | the length of the chain id written big-endian with no leading zero byte |
| that length | chain reference | the chain id, big-endian, no leading zero byte (Ethereum `0x01`, Base `0x2105`) |
| 1 | address length | `0x14` |
| 20 | address | the account |

A wallet on Base is `0x0001 0000 02 2105 14 <20 bytes>`. Its key is `keccak256` of those bytes
(`WalletKeyLib.canonicalKey`); an envelope with trailing bytes, a padded address, or an empty or zero-led chain
reference names the same wallet under another key and is refused (`NonCanonicalInteroperableAddress`). A spender's
key is `keccak256` of its envelope, and zero when the ticket names no spender. A chain's key is `keccak256` of the
envelope with an empty address, `0x0001 0000 02 2105 00` for Base (`MessageTypesLib.chainKey`). Home checks the
spelling of EVM envelopes only: no non-EVM chain type has its exact encoding listed here, so no receipt route is set
for a non-EVM chain until it is.

## Rules

### Transport

1. **Act on each delivery once.** A gateway may redeliver; the Lite dedupes on a nonzero receive id, and also on
   the operation id, since a resend arrives under a new receive id: `ticketId` for a ticket, see rule 3 for
   what a second body under a known id means, and `(type, halfKey)` for a move out or a bring home, rules 9 and 10,
   where `halfKey` is `ticketId` for half 0 and `keccak256(abi.encode(ticketId, half))` otherwise. A zero receive id names
   no delivery (ERC-7786 allows it) and is never recorded, or the first one would refuse every later message.
2. **Accept only the reference token as author, through two receivers.** The Lite has two receiver contracts: the
   away ticket bridge, which takes tickets, and the away receipt bridge, which takes tickets and every other message.
   It accepts a `MOVE_OUT` or a `BRING_HOME` from the away receipt bridge only, and never acts on a message from
   another away token.
2a. **Send every receipt on the receipt route, at full finality.** The Lite sends every `RECEIPT` through its away
   receipt bridge at full finality (`0x00000000`), a setting that is immutable, with the gas limit the receipt's
   delivery at home needs (see the reaction table). When that send fails, the whole delivery that asked for it
   reverts, so it stays deliverable and nothing executes without its receipt. The fee account that pays the sends is
   kept funded, with alarms before it runs dry. The away receipt bridge shares no reentrancy lock between the call
   that receives a message and the call that sends one, or the receipt sent inside a delivery would revert.
   On the reference side, a chain may have two routes: a ticket route, set with `setTicketRoute` to a trusted bridge, that carries tickets out ahead of finality and
   nothing else, and the receipt route, set with `setReceiptRoute` to a receipt bridge, that carries money messages out
   and is the only one receipts are taken from. A receipt bridge is a bridge the registry trusts at depth zero
   (`setTrustedGateway(bridge, true, 0)`, `depthOf`); the depth may be set again and is read on every send of a money
   message and every receipt. `depthOf` never reverts: an unknown bridge reads zero, so the token asks `isTrusted`
   first. The token takes deliveries from receipt bridges only,
   so a ticket bridge's delivery is refused (`ERC7786RecipientUnauthorizedGateway`, OZ's `WrongRoute`: the message stays
   deliverable through a receipt bridge), and it reads the receipt
   bridge's receiving policy for this chain's receipt bridge when the route is set and on every receipt, refusing
   one that admits less than full finality (`WrongFinality`). Every money message it sends, and every ticket it puts
   on the receipt route, reads the finality the receipt bridge itself requests (`requestedFinality()`) and is refused
   with `WrongFinality` when it is not full finality: the depth is only a label. Zero is full finality: a token takes
   its receipt route, and every money message and receipt, only from a trusted bridge at depth zero. A ticket rides
   the ticket route at that bridge's own depth, which the token does not check. Home cannot tell which away bridge
   sent a receipt, and does not need to: the home receipt bridge's receiving policy is immutable at full finality for
   every source, so a receipt it delivers was sent at full finality whichever away bridge sent it. Each half is
   pinned to the receipt route
   and the peer it left through (`pinOf`), and its receipt is taken from that pair or the current one, so a ticket
   that arrived on the ticket bridge is answered through the receipt route, not back through the bridge that
   delivered it.

### Validations

3. **Execute a ticket once, and keep the first copy per id.** A ticket delivered again under a known id is never
   held in place of the first, whether home sent it again or it is a copy of the same ask mined again in another
   block after a reorg (another `askBlockHash`, maybe another `amountMax` or `validUntil`): it is an ask for the
   receipt. The Lite answers it with the receipt it stored, with a stored zero receipt (`Expired`) once the first
   copy's valid until has passed, or with a still open answer before. A first copy that arrives at or after its
   valid until is answered with a stored zero receipt and never executed. The receipt echoes the copy held, and the
   reference chain tells which one it was. A ticket whose `ticketId` is not the id of its own terms (the formula
   above, under the copy's own `kind`) is refused (`TicketIdMismatch`) and never held, so nobody puts other terms under a known id.
   Answers that send a stored receipt again, to later copies or repeated halves, are rate limited per half: six in
   each answer window (`MAX_ANSWERS_PER_WINDOW`, `answerWindow`), not six for ever. Home sends at most three asks for
   a ticket's receipt and three sends of a half, so six cover home and a redelivery of each; past the limit the
   delivery is consumed and nothing is sent (`AnswerNotSent`), and the next window answers again. The window is set
   at deployment, and its setter refuses zero. The first send of a stored receipt is not counted, and neither is a
   still open answer: the first send is the receipt home waits for, and a still open answer that moves the ticket's
   valid until gives home's ask back, so home must hear every one. Counting them would use up the answers home needs
   once the ticket executed or passed its valid until.
4. Execute strictly before `validUntil`.
5. Execute an amount inside `[amountMin, amountMax]`.
6. Execute only for the named wallets, by `from`, or by the named `spender` only when it spends an ERC-20 allowance
   `from` gave it.
7. Report every ticket it executed, exactly once, in the transaction that executes it, echoing the copy it executed under (`askBlockHash`, `seenMax`,
   `seenValidUntil`) with `answer` `Executed`, and both wallets. A report lost on the way may be sent again byte for
   byte: the reference chain keeps one receipt per half, recognises the same one again and changes nothing; another
   receipt for a half that already has one blocks the Lite's chain. The Lite keeps one receipt per `(type, halfKey)`
   and exposes it (`storedReceipt(type, halfKey)`), where `type` is the message the receipt answers: `TICKET` for a
   ticket's own receipt, `MOVE_OUT` or `BRING_HOME` for a half. Anyone may ask the Lite to send a stored receipt
   again (`resendReceipt(type, halfKey)`), at most three times per half (`MAX_RECEIPT_RESENDS`), each one a flat
   `receiptResendWait` after the last send of that receipt: every send is paid from the bridge's fee balance. The wait
   is set at deployment, and its setter refuses zero. The resends are counted apart from the answers of rule 3, so a resend by anyone never
   uses up the answers home needs. A stored receipt is kept for good: it is never deleted, so a reconciler can always
   read it and have it sent again (see "Retries").

### Instructions

Rule 8, the two-leg invariant, is gone: a receiving Lite no longer mints on the sending Lite's burn message. It
mints on home's move out only (rule 9), and never acts on a message from another away token (rule 2).

9. **A move out mints at most once per half**, keyed by `(MOVE_OUT, halfKey)`, strictly before the half's `validUntil` on
   the Lite's own clock, and answers with one receipt for that half. A move out that arrives at or after its
   `validUntil`, never executed, is answered with a zero receipt (`Expired`), stored, and that half is never executed
   afterwards: home then sends a new half. The same half again is answered with the stored receipt, byte for byte.
   Home already holds the amount on hold; a Lite that mints twice has inflated its chain.
10. **A bring home burns at most once per half**, keyed by `(BRING_HOME, halfKey)`, strictly before the half's `validUntil`
    on the Lite's own clock. The Lite burns `min(amount, balance)`, down to zero, and answers with one receipt for that
    half naming the burned wallet. A bring home that arrives at or after its `validUntil`, never executed, is answered
    with a zero receipt (`Expired`), stored, and that half is never executed afterwards. The same half again is
    answered with the stored receipt, byte for byte. The Lite never burns more than `amount` and never burns for an
    older half: home holds `amount` reserved on the wallet until the receipt lands, so no ticket asked meanwhile
    draws on it, and mints at the home wallet the ticket recorded, not one the receipt could choose.

### What the Lite exposes

11. **Expose what close by hand reads.** The Lite exposes, as views any RPC reader can call on a final block, the
    receipt it stored for each `(type, halfKey)` (`storedReceipt(type, halfKey)`, rule 7) and the valid until of the
    ticket copy it holds for each `ticketId`, zero when it holds none. When a chain's receipt route is closed, home
    decides its tickets and halves from exactly these two reads and the block's timestamp (`closeByHand`, see "When a
    half is never answered"), never from its own clock.

## Lanes

A message may be attested to a Lite before the reference chain reaches finality only when nothing it carries
depends on which block, or in which order, its transaction landed. That holds for one type:

| Type | Lane | Why |
|---|---|---|
| `TICKET` | may ride before finality | `ticketId` is built from the whole request, never from the chain's ordering or clock; a receipt never stops the token. A ticket an approval opened, a ticket above the chain's per-ticket cap, and one that would take the ticket route above its per-window cap travel at full finality: a reorg could otherwise drop the approval after the away token executed the ticket, and the caps bound what a dropped block can cost. The compliance chooses the route at the ask and writes it on the ticket |
| `RECEIPT` | MUST wait for the satellite chain's finality | the reference chain applies a report once and cannot take it back; a receipt or a burn its chain later reorgs away would stay on the ledger for a movement that never happened |
| `MOVE_OUT`, `BRING_HOME` | MUST wait for finality | they move value: home sends them only on its receipt route, at full finality |

A Lite that executes a validation before finality owns the reorg exposure, and the reference chain bounds it to
that chain. Three things can happen to an issuance after the Lite acted on it, and each has one outcome:

- **Re-included in another order.** The id is the same, since it never depended on the order. Nothing to do.
- **Dropped.** The receipt reaches the reference chain under an id home has no record of. Home puts its amount on
  hold under the sender, with no destination (`ReceiptWithoutTicket`), and no chain is blocked; when the Lite moved
  the tokens to a wallet on its own chain, that wallet gets uncounted credit (the token's `uncountedCreditOf`): tokens it holds
  that home does not count for it yet and that it cannot ask to move. The request sent again with the same terms and
  `salt` takes the same id; the body carries the `salt`, so an agent can send it on the requester's behalf from the
  Lite's copy. That ask takes the money on hold and finishes the move, once the held receipt keeps the ask's terms and
  the per-ticket cap; no approval module may be bound. The take is an ask: it is refused over the identity's asks per
  window (`AskLimitReached`) and counted there, but not as an open ticket. If nobody takes it within four waiting
  times of the sender's chain, anyone starts its cancel (`cancelHold(ticketId)`), which sends nothing: the cancel's
  first half is owed, and anyone sends it, and every later half of the cancel, with `sendSecondHalf(ticketId,
  wallet)`, since home keeps no wallet's bytes for it. When the Lite moved the tokens to a wallet on its own chain,
  that half is a `BRING_HOME` on the receiver for at most its uncounted credit, sent even when that credit is zero,
  then a `MOVE_OUT` of what burned back to the sender; when the tokens left the sender's chain, it is a `MOVE_OUT`
  back to the sender. A bring home that burns less than it asked, zero included, leaves the rest on hold
  (`CancelHoldShort`) and is not sent again until credit comes back to the receiver. A cancel already started is not
  started again (`TicketNotCancellable`). A receipt for a ticket home
  wrote and never sent (waiting for approval, or cancelled before it left) is put on hold the same way, never applied
  as that ticket's move.
- **Mined again in another block.** The id is the same and the ask block hash is not: the copy home now holds may
  have another `amountMax` or `validUntil`. The ask block hash the receipt echoes tells the two cases apart. On
  home's own ask block hash the receipt must echo home's own terms and move an amount inside them. On another one it
  answers a copy from a block a reorg dropped (`ReceiptOnOlderTerms`): it is allowed up to `requestedMax` and the
  away chain's per-ticket cap, with an amount inside the range of the copy it echoes. A ticket that waited for an
  approval has one honest copy, home's own, sent at full finality: on such a ticket any other ask block hash breaks
  its terms. Either way the receipt is
  applied as it happened, since the Lite's balances already moved; one that breaks its terms also blocks its chain.
  A receipt from a chain the ticket was not sent to, or for other wallets, is refused and blocks that chain.

The ask block hash holds the block number, the hash of the block before and the terms home narrows: two sibling
blocks at one height share number and parent, so the terms tell their copies apart. Home writes it at the ask and
only compares it later, so it never reads a block hash older than the chain serves (8,191 blocks, EIP-2935).

## Retries

Nothing is written off; a lost message is sent again.

| Lost | Who retries | How |
|---|---|---|
| ticket (a resend, or an ask for its receipt) | anyone | `sendTicket(ticketId, to, spender)`: while `Open`, before `validUntil` a resend of a lost ticket that counts as no ask, and from one waiting time after the later of `validUntil` and `seenValidUntil` an ask, three asks at most; one send per waiting time either way; sent to the sender's chain read from the record; rebuilt from the record, `to` and `spender` checked against the ones asked with, and the recorded ask block hash sent again; goes out on the route chosen at the ask (the ticket route falls back to the receipt route when its bridge is no longer trusted), to the pinned pair while it is the current pair or the former pair inside its window, and to the current pair otherwise; refused while that away chain is blocked, under a hostile change, or the token is paused, and for a receiver on another away chain while that chain is blocked, not while it is closed or under a hostile change; the Lite answers this later copy with its stored receipt, a zero receipt (`Expired`) or a still open answer |
| move out (a second half) | anyone | `sendSecondHalf(ticketId, wallet)`, `wallet` read off `SecondHalfSent`: an owed half (answered `Expired`, or its send failed inside the receipt's delivery) is sent as a new half with a fresh valid until, at most four halves per money on hold (`NoNewHalfLeft`); every half of a cancel `cancelHold` started is sent here too, its first one included; otherwise the latest half is sent again byte for byte, three sends at most, at fixed times: one waiting time of its chain after its valid until, then two more. A half sent again goes only to its pinned peer: through the former pair inside the window of a planned change, or the current route while that peer is still the chain's (`PeerChanged` otherwise) |
| bring home, or its receipt | anyone | `sendSecondHalf(ticketId, awayWallet)` while the bring home is open, at the same fixed times as a move out; the Lite answers with its stored receipt or a zero receipt (`Expired`), which ends the bring home with nothing moved. Sent again only to its pinned peer, as a move out is |
| a receipt, when home no longer asks for it | the reconciler (anyone may) | `resendReceipt(type, halfKey)` on the Lite, rule 7. An off-chain reconciler compares home's records with every Lite's stored receipts, read over RPC (`storedReceipt`), and has a stored receipt sent again when home cancelled that ticket or has no record of its id (a ticket from a home block a reorg dropped, whose receipt was lost). Home then handles it by its own rules: a late receipt for a cancelled ticket is applied as it happened (a move inside one away chain) or taken onto hold and decided (a move to another chain), and one for an id it has no record of is booked on hold (`ReceiptWithoutTicket`). Each resend is paid from the Lite's fee account, within its quota per half |

The reconciler reaches back only as far as the stored receipts and the events that name them are kept, so a Lite
never deletes a stored receipt, and its operator keeps the Lite's events and the execution inputs of failed
deliveries archived for as long as a ticket of that chain can still be open, on hold or closed by hand.

A half sent again never retargets: it goes to the peer it was pinned to, which holds it, and the token refuses it
(`PeerChanged`) once that peer is gone. A new half is taken only after a zero answer or a failed send, never because a
route or a peer changed: the old half may still mint, and a new half would mint the same money twice. A half whose peer
was replaced as hostile keeps no former pair, so it is ended by closing its chain by hand. The old away token must stay
alive until every half pinned to it is answered.
A ticket's receipt is taken from the bridge and the peer it was pinned to, so after a route switch or a peer change an
ask for its receipt still goes to the pinned pair while that pair is the former one inside its window (the away token
holding the ticket is the one that answers), and to the current pair after. Its reservation comes back through a
cancel once an ask for its receipt went unanswered. A bring home is never cancelled: it ends on its receipt, or by
`closeByHand` while its chain is closed.

### When a half is never answered

Home bounds what it sends for one money on hold: three sends per half and four halves (`newHalves` on `ticketOf`
reads the halves taken, and `NoNewHalfLeft` refuses a fifth). Three cases leave the money on hold with nothing more to send: the
fourth half dies too (answered `Expired`), a half goes unanswered after its three sends, or an open bring home goes
unanswered after its three sends. So does a half whose pinned peer was replaced as hostile (`PeerChanged`). Nothing on
home's clock ends them: the away chain may still have minted or burned. The operator's exit:

1. Find why the away chain does not answer (its away token, its bridge, the fee balance) and fix it if it can be
   fixed: a half sent again inside its three sends, or a stored receipt sent again with `resendReceipt`, ends it the
   normal way.
2. Otherwise close the chain's receipt route (`closeReceiptRoute`, the identity manager). This stops every message
   from and to that chain, for every ticket on it.
3. Read the away token on that chain from one final block (rule 11): its stored receipt for the half, the valid
   until of the ticket copy it holds, and the block's timestamp, its clock. Call
   `closeByHand(ticketId, receiver, reading)` on the compliance (the identity manager). A stored receipt above zero is
   applied as if it had arrived, and nothing is returned; a stored receipt for an id home has no record of is booked
   on hold, as a delivered one would be. Without one, that chain's own clock decides: a receipt waiting at home on
   the closed route can never be applied there, so it does not hold the close. For:
   - an open move, or one waiting for approval: it is cancelled once that chain's clock is past the latest valid
     until its copies can carry: home's own plus the chain's reorg slot shift, the one a still open answer reported,
     and the stored copy's. This one is closed even while the chain is blocked, and, being a cancel, never while a
     hostile change runs on that chain (`HostileChangeNotOver`);
   - an open bring home: it ends with nothing moved once that chain's clock is past its half's valid until;
   - money on hold, its half going to the receiver or back to the sender: once that chain's clock is past the half's
     valid until, the money goes back to the sender by a new `MOVE_OUT` while the sender's own chain has a receipt
     route; otherwise it is minted at home at once, to a home sender or to the sender's identity contract;
   - money on hold with no ticket whose tokens left their chain, the closed one: the carried part of an earlier hold
     is applied first, then the money is minted at home to the sender's identity contract, once its cancel is due
     and, when a return half of its cancel is out, that chain's clock is past that half's valid until;
   - money on hold with no ticket, moved inside that chain (the cancel of the hold): what the receiver still holds
     as uncounted credit is applied as the move inside that chain it was, never minted to the sender, after the
     carried part of an earlier hold is applied first, last in, first out. The rules are asked again about each
     move; one they refuse is announced with `MoveBreachedRule`, never refused, since the away token already made it.
     When the cancel's bring home burned some of it and the `MOVE_OUT` of that part back to the sender, on the closed
     chain too, is out or owed, that half can no longer mint once that chain's clock is past its valid until, or when
     it never left: after the carried part of an earlier hold is applied first, only what burned is minted at home to
     the sender's identity contract, and the rest stays on hold, short, for the receiver's uncounted credit above.
   Every case but the open move needs that chain unblocked, and a bring home or money on hold the sender's chain
   too; none runs under a stop of the token. A hostile change holds only the cancel of an open move or of one
   waiting for approval; every other case, a stored receipt applied included, runs under it.
4. Set the receipt route again once every ticket of that chain is decided.

Nothing on chain announces a half that keeps dying. The operator's monitor alerts on the fourth `SecondHalfSent` of
one money on hold that is a new half (`ticketOf(ticketId).newHalves` reaches 4): its chain's waiting time is sized
too short for its delivery and clock lead, and the waiting time is raised before more halves die. It also alerts on
`CancelHoldShort`, a cancel of money on hold that burned less than it asked.

## Changing a route or a peer

There is one setter per change, and no event of its own for the former pair: `ReceiptRouteSet` and `PeerSet` say a
change happened.

A planned change (`setReceiptRoute` on an open route, or `setPeer(chainKey, peer, false)`) is made on home first.
Home keeps the route and peer the chain had as its former pair and takes every receipt from it for four waiting times
of that away chain: home keeps the time of the change and reads the waiting time from the compliance on every use,
so changing the waiting time moves the end of a window already running, and of a hostile change's freeze too. The
Lite switches only after home's change is final, early enough that its last receipts on the old pair land inside
those four waiting times. A second change of route or peer on that chain inside the window is not refused: it keeps
the pair the chain has then and drops the older one. So the operator plans changes of one chain at least four of its
waiting times apart; the token does not check it. A change while the route is closed keeps no former pair. A receipt
that came on the former pair inside the window and then waited (chain blocked, token stopped) stays applicable after
the window ends. The accepted cost: an old peer that turns hostile inside the window can have home apply receipts it
forges, for any ticket of that chain. When an away chain is first opened, set its peer before its receipt route: a
change on a chain that has a route starts a change window.

A hostile peer is replaced with the same setter, `setPeer(chainKey, peer, true)`. Home keeps no former pair, the one
of an earlier planned change included, and for four waiting times of that away chain (`hostileChangeEndsAt`) no ask,
no ticket send, no ask for a receipt and no cancel runs for it (`HostileChangeNotOver`): `cancelTickets`,
`cancelHold`, and the close by hand of an open move or one waiting for approval. An ask from another away chain to a
receiver on it is refused too, but a ticket already asked from the other chain is sent again, asked about and
cancelled there, since its copy and its receipt never reach the frozen chain. Receipts still land, halves still go
out (`sendSecondHalf`), bring homes are still written and sent, and every other close by hand runs. Halves pinned to
the hostile peer keep their receipt from it: for full containment the operator also distrusts its bridge.

Closing a receipt route that is already closed changes nothing and emits `ReceiptRouteClosed` again.

## What the reference chain does with a Lite that breaks a rule

| Broken rule | Reference-chain reaction |
|---|---|
| 3, 7: another receipt for a half that already has one, applied or waiting | `ReceiptRefused` (`AnotherBody`), consumed, nothing applied, the compliance blocks that away chain (`blockAwayChain`) |
| the receipt home holds for a half, delivered again byte for byte (a bridge redelivery, or the Lite resending its receipt) | `ReceiptDuplicate`, consumed, nothing applied, nothing blocked; a chain blocked over the first delivery and reopened stays open |
| a first-half receipt for an id home has no record of, or for a ticket home never sent | put on hold under the sender with no destination (`ReceiptWithoutTicket`), nothing blocked; refused and the chain blocked when its sender is not on that chain or, for a ticket home wrote, its wallets are not the ticket's; taken by the ask mined again, or cancelled with `cancelHold`, whose halves `sendSecondHalf` sends |
| a second-half receipt for an id home has no record of | `ReceiptUnknown`, consumed, nothing written, nothing blocked |
| a good receipt that cannot be applied yet: the token stopped, its away chain blocked, or the sender's away balance too low (for a receipt with no ticket, its away balance and the uncounted credit it may carry) | `ReceiptWaiting`, consumed and kept under its half with the bridge and peer that brought it, nothing blocked; anyone applies it with `applyWaitingReceipt` once it can be, after the route check runs again on that bridge and peer; the same receipt delivered again then applies it too |
| 6: wrong wallets, a chain the ticket was not sent to, or a half home never sent | `ReceiptRefused` (`WrongWallets`, `WrongChain`, `HalfNotSent`), consumed, nothing applied, the compliance blocks that away chain; the ticket stands |
| 9: a move out's receipt from a chain the half was not sent to, naming a sender, minting another amount, or minting an older half | `ReceiptRefused` (`WrongChain`, `WrongWallets`, `WrongMoveOut`, `HalfNotSent`, `AnotherBody`), consumed, nothing applied, the compliance blocks that away chain |
| a move out's receipt with less gas left than home's send of a new half needs, where one is sent | reverts with `NotEnoughGasForTheSecondHalf` and stays deliverable: home asks for 550,000 gas left before that send |
| a zero answer (`Expired`) that comes late for a half close by hand already decided, or for an older half, judged against the wallet that half was sent to | `ReceiptApplied`, consumed, nothing changes, nothing blocked |
| 5: a ticket's receipt that moved something, with an amount outside the range, or other terms echoed, under home's own ask block hash; or, under another ask block hash, a copy above `requestedMax` or the per-ticket cap, or any copy at all of a ticket that waited for an approval | applied as it happened, then the compliance blocks that away chain |
| 3: a still open answer on home's own ask block hash echoing another valid until | `ReceiptRefused` (`AnotherValidUntil`), consumed, nothing applied, the compliance blocks that away chain |
| 10: a bring home's receipt from another chain, for another wallet, naming a receiver, burning more than the bring home's amount, or burning for an older half | `ReceiptRefused` (`WrongChain`, `WrongWallets`, `AboveTheBringHome`, `HalfNotSent`), consumed, nothing applied, the compliance blocks that away chain |

A receipt for a ticket home knows never reverts for what it carries: it is applied as it happened or refused, and
consumed either way, see "Lanes". A receipt for an id home does not know blocks nobody: a first half is put on
hold under its sender, a second half is announced (`ReceiptUnknown`) and consumed. A delivery reverts after
admission only for two causes: too little gas for the second half it sends (above), or a module that reverts. A
reverted delivery stays deliverable, on the assumption that the ERC-7786 gateway keeps a reverted execution
retryable; a gateway that marks it failed for good loses the message, and its author has to send it again. When a
module reverts receipts, the steps are named: the pauser stops the token (`pause`), so every receipt that arrives
waits at home and no ticket it answers can be cancelled; the compliance owner removes the module
(`forceRemoveModule`); the pauser lifts the stop (`unpause`); then anyone applies the receipts that waited
(`applyWaitingReceipt`). The block of an away chain and the stop of the token are lifted by the
pauser after an investigation: `unblockAwayChain(chainKey)` on the compliance for one chain, `unpause` for the token.
While a chain is blocked its good receipts are consumed and wait at home; a move out toward it is not sent (a move
to it is returned to the sender instead), no bring home is written or sent again toward it, and the compliance neither
issues a ticket toward it nor asks for a receipt there, nor cancels any of its tickets on its own clock, a ticket
waiting for approval included, since the waiting receipts may answer them and acting on their absence would release
what they move. Native transfers and every other chain are unaffected. To abandon a chain for good: close its receipt
route (`closeReceiptRoute`), refuse the receipts it left waiting, and close what it holds by hand from a read of
that chain (`closeByHand`, see "When a half is never answered"): an open move is closed even while the chain is
blocked, everything else once the block is lifted. A distrusted gateway alone does not close a route: no ticket of
that chain is cancelled then, and only `closeReceiptRoute` opens close by hand.

Threat model, stated plainly. A trusted gateway, or the registered peer behind it, can stop its own chain's inbound
with one bad receipt, and a receipt can do little more: it is applied as it happened on its own chain, bounded by
`requestedMax` and the per-ticket cap on older terms, and a receipt for an id the token never issued is put on hold
under its sender, blocks nobody, and is cancelled after four waiting times if nobody takes it. Nothing a message says stops the whole token. The remedy against a peer abusing its chain is to
distrust its gateway.

### The brakes

| Brake | Stops | Set by | Lifted by |
|---|---|---|---|
| token pause, `pause` | every balance movement between wallets, native or satellite; every inbound receipt waits at home; new tickets, bring homes, approvals into issuance and asks for receipts; cancels of tickets whose receipt may be waiting | the pauser | the pauser, `unpause` |
| block an away chain, `blockAwayChain` on the compliance | applying one chain's receipts (they wait at home); move outs, bring homes, new tickets and asks for receipts toward it; cancels of its tickets on home's clock, and every close by hand on it but an open move's | the pauser; the compliance itself on a bad receipt from that chain or a receipt that breaks its terms | the pauser, `unblockAwayChain` |
| asks paused, `setAsksPaused(chainKey, true)` on the compliance | new asks that involve that chain, as the sender's or the receiver's; zero pauses every new ask; receipts, asks for receipts and cancels go on (`AsksPaused`) | the compliance manager | the compliance manager, `setAsksPaused(chainKey, false)` |
| hostile peer replaced, `setPeer(chainKey, peer, true)` | asks, ticket sends, asks for receipts and cancels for one away chain, for four of its waiting times (`HostileChangeNotOver`); receipts still land, halves and bring homes still go out | the identity manager | nobody: it ends by itself at `hostileChangeEndsAt` |
| receipt route close, `closeReceiptRoute` | every send toward one chain and every message from it, a receipt of a half already sent included (`ChainNotOpen`); they stay deliverable and land once a route is set again; no ticket toward that chain is cancelled on home's clock meanwhile: the identity manager closes it by hand, `closeByHand` on the compliance, from a read of that chain's stored receipt and clock in one final block | the identity manager | the identity manager, `setReceiptRoute` with a receipt bridge |
| bridge distrust, `setTrustedGateway(bridge, false, 0)` on `TrustedGatewayRegistry` | every message through that bridge, pinned or not, for every token; no ticket whose receipt route it is is cancelled on home's clock meanwhile: the route is closed, then the ticket is closed by hand from a read of its chain | the registry's interop manager | never: a distrusted bridge is never trusted again, so the receipt route is set to a new receipt bridge |

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
- **A lost message is recovered by retry, not by write-off.** A bring home is not cancelled; it ends on its receipt,
  or by close by hand while its chain is closed.
- **Lowering a per-ticket cap.** `setTicketLimits` lowers the cap at once, and a receipt is judged against the cap
  in force when it lands. A copy sent under the old cap can echo a maximum above the new one and block an honest
  chain. The operator lowers a chain's per-ticket cap only once every ticket sent to it under the old cap is past its
  valid until.

The residues OpenZeppelin's model accepts, which no rule here removes:

- **Two lost or late messages on one ticket.** One lost or late message is absorbed by the asks for the receipt.
  Two (the ask and its answer, say, while the receipt is lost), or a route that stops delivering for good, can make
  home cancel a ticket the away token already executed, and leave a ledger that does not settle until the
  reconciler has the stored receipt sent again. No waiting time absorbs two lost messages on one ticket.
- **The same-chain cap residue (S4b).** After a home reorg deeper than the ticket route's depth, a move inside one
  away chain can pass a compliance cap, bounded by what the dropped tickets carried.
- **A hostile away token or ticket bridge on its own chain (S8).** It can pass a cap on its own chain by up to the
  per-ticket cap per ticket without a block; above that, the receipt blocks its chain.
- **Reorg exposure across a window boundary (S12).** What a reorg deeper than the ticket route's depth can expose
  stays within the per-window cap, and reaches twice the per-window cap when the reorg spans the end of one window
  and the start of the next.
- **A hostile receipt bridge** in front of an honest away token breaks the ledger; every receipt bridge is trusted.
- **An old peer that turns hostile** inside the window of a planned change, see "Changing a route or a peer".

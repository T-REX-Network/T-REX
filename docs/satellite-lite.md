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
| in | `COMPLIANCE_VALIDATION` | `ComplianceValidation { validationId, salt, from, to, spender, amountMin, amountMax, token, expiry, reconciliationWindow }` | stores it under `validationId`, with `hashValidation` of it |
| in | `MINT_INSTRUCTION` | `MintInstruction { delegationId, toWallet, amount, holder }` | mints `amount` to `toWallet`, once per `delegationId` |
| in | `RECALL_INSTRUCTION` | `RecallInstruction { recallId, wallet, amount, nativeWallet }` | burns up to `amount` of `wallet` once, answers with a `BurnProof` |
| out | `SETTLEMENT_NOTIFICATION` | `SettlementNotification { validationId, from, to, amount, hash }` | one per leg it executed, `hash` being the hash of the body it executed under |
| out | `BURN_PROOF` | `BurnProof { recallId, burnedWallet, amount }` | one per recall id, resent unchanged on request |

Every message travels through a gateway the network's `TrustedGatewayRegistry` trusts. The token accepts a settlement
only from the chain's current peer, and a burn proof for an open recall only from the peer and through the gateway
that recall was dispatched to.

## Rules

### Transport

1. **Act on each delivery once.** A gateway may redeliver; the Lite dedupes on the receive id, and also on the
   operation id, since a resend arrives under a new receive id: `validationId` for a validation, see rule 3 for
   what a second body under a known id means, and the instruction ids of rules 9 and 10.
2. **Accept only the reference token as author**, through its own gateway.

### Validations

3. **Execute a validation once, and hold one body per id.** A validation delivered again under a known id with the
   same `hashValidation` is a resend, ignored. One with another hash, while the id is not yet consumed, replaces
   what the Lite holds: the reference chain re-issued it after a reorg, and the later body is the canonical one.
   Once consumed, nothing changes whatever arrives: the report already names the hash executed under.
4. Execute strictly before `expiry`.
5. Execute an amount inside `[amountMin, amountMax]`.
6. Execute only for the named wallets, by `from` or by the named `spender`.
7. Report every leg it executed, exactly once, carrying the `hashValidation` of the body it executed under. One-leg
   movements carry both wallets; on a two-leg movement the sending Lite reports the burn leg with `to` empty, the
   receiving Lite the mint leg with `from` empty.

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
    may be below `amount`, down to zero, when a validation executed first; stores the proof; sends it. A repeated
    instruction is answered with the stored proof, and the operator can resend it. The Lite never answers one id with
    two different proofs and never proves more than instructed. The token credits the native wallet the instruction
    recorded, not one the proof could choose.

## Lanes

A message may be attested to a Lite before the reference chain reaches finality only when nothing it carries
depends on which block, or in which order, its transaction landed. That holds for one type:

| Type | Lane | Why |
|---|---|---|
| `COMPLIANCE_VALIDATION` | may ride before finality | `validationId` is `keccak256(canonicalKey(from), salt)`, a function of the request and never of the chain's ordering or clock; the settlement path never halts the token |
| `MINT_INSTRUCTION`, `RECALL_INSTRUCTION` | MUST wait for finality | `delegationId` and `recallId` are counters, assigned by inclusion order; a reorg can give the same id to another instruction |

A Lite that executes a validation before finality owns the reorg exposure, and the reference chain bounds it to
that chain. Three things can happen to an issuance after the Lite acted on it, and each has one outcome:

- **Re-included in another order.** The id is the same, since it never depended on the order. Nothing to do.
- **Dropped.** The leg reaches the reference chain under an id nothing is issued under: the leg is parked
  (`SettlementParked`, `parkedLegOf`) and the chain's inbound is paused. Once the pause is lifted, the request
  sent again with the same `salt` issues the same id and sends no leg to the chain that already executed; the body
  carries the `salt`, so an agent can send it on the requester's behalf from the Lite's copy. Anyone then calls
  `settleParkedLeg(validationId, chainKey)`, which judges the leg as a delivery would (`ParkedLegSettled`, or one
  of the outcomes below); a leg that reverts there stays parked and is tried again, and once the keeper resolved
  the pair it ends as a replay.
- **Re-issued with another body.** The hash in the report tells the two cases apart. A leg inside the issued terms
  settles whatever hash it carries (`SettlementBodyDiverged` when it is not the issued one). A leg outside the
  terms with the issued hash is a Lite that broke rule 5 or 6 (`SettlementRejected`); one with another hash, from
  a chain the validation involves, executed a body this chain never canonically issued (`ValidationOrphaned`):
  while `Pending` the validation ends `Orphaned` and its reservation is released, otherwise it stands. A leg from
  any other chain is rejected whatever hash it names, since that chain could not have executed anything under the
  id. Nothing is applied either way, and the chain is paused.

The hash commits to the terms alone, the id, the wallets, the spender, the range and the token: `expiry` and
`reconciliationWindow` are read off the issuing block's clock and are left out, so a body re-issued after a drop
with the same terms hashes the same.

## Retries

Nothing is written off; a lost message is sent again.

| Lost | Who retries | How |
|---|---|---|
| validation leg | sender's identity, recipient's identity for the leg toward the recipient's chain, or agent | `resendValidation(validationId, chainKey, to, spender)`: either leg while `Pending` and before `expiry`; the receiving chain's leg also once the burn landed, before `releaseAt`, so the leg cannot land after the pair was resolved and the burned amount returned; rebuilt from the record and checked against the issued hash; goes through the gateway the issuance pinned; refused while issuance toward that chain is paused; nothing counts or spaces resends, the token forwards no value and the Lite ignores a leg it holds |
| mint instruction | agent | `resend(0, delegationId, abi.encode(toWallet, amount, holder, peer))`, the fields from `DelegatedOut` and the peer at dispatch; checked against the stored commitment |
| recall instruction | agent | `resend(1, recallId, abi.encode(wallet))`; the admitted gateway moves to the current route, which delivers the resend |
| burn proof | Lite operator | resend the stored proof; the token settles it once |
| a proof delivered twice | nobody | the token recognises the settled proof and changes nothing (`BurnProofDuplicate`) |

A resend never retargets: it is refused (`PeerChanged`) once the chain's peer is no longer the one the instruction
was addressed to. A resend after a route switch is the expected way to recover a recall whose original gateway is gone.
A validation leg is the exception: its settlement is matched against the pinned gateway, so after a route switch the
leg is not resent (`ValidationAlreadyRouted`). While `Pending`, the reservation comes back through discard at
`releaseAt` and a new validation is requested. Once the burn landed, the pair cannot be discarded: its exit is
`resolveStuckValidation` after the second window, which returns the burned amount to the sender. A validation leg
goes to the chain's current peer, as an issuance does, since only the current peer's settlement is accepted; a
peer change with validations in flight is to be avoided as a route change is.

## What the reference chain does with a Lite that breaks a rule

| Broken rule | Reference-chain reaction |
|---|---|
| 3, 7: a settlement leg delivered again, a leg for a pair the keeper already resolved, or a second leg from one chain for a parked id | `ReplayedSettlement`, the token stops taking that chain's messages (`setInboundPaused`) |
| a settlement for a validation never issued, or recorded but never sent | `SettlementParked`, the leg kept under its id, the token stops taking that chain's messages; once the request is sent again with the same salt, `settleParkedLeg` settles it |
| 5, 6: amount outside the range, wrong wallets or chain, under the issued hash | `SettlementRejected`, consumed, the token stops taking that chain's messages; the validation stands |
| 5, 6 under another hash: a body the reference chain never canonically issued | `ValidationOrphaned`, consumed, the token stops taking that chain's messages; `Orphaned` while no leg had landed |
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
`ChainInboundPaused` and wait at the gateway; a delegation toward it is refused, and the compliance neither issues a
validation toward it nor resends one, nor discards or resolves a validation still awaiting that chain's leg, since
the held reports may answer it and acting on their absence would release or return what they move. Native transfers,
every other chain, and recall instructions and instruction resends toward the paused chain are unaffected; the proof
answering a recall lands once the pause is lifted. To abandon a chain for good: distrust its gateway or close its
route, then lift the pause so its validations can be discarded and resolved.

Threat model, stated plainly. A trusted gateway, or the registered peer behind it, can stop its own chain's inbound
with one message, and that is all a settlement can do: a validation id is a function of the request, so a leg for
an id the token never issued is the leg's chain's problem, a reorg's or the peer's, and is parked under the chain
pause rather than halting the token. A burn proof naming a recall never issued still pauses the whole token, with
its price: recall ids are counters and wait for finality, so an unknown one has two readings the token cannot tell
apart, the peer invented it, or the token's own records are out of step with what it dispatched, which is local
and must not keep running. The remedy against a peer abusing either is to distrust its gateway.

### The brakes

| Brake | Stops | Set by | Lifted by |
|---|---|---|---|
| token pause, `pause` | every balance movement between wallets, native or satellite, and every inbound settlement and proof | the pauser; the token itself on a proof for a recall it never issued | the pauser, `unpause` |
| chain inbound pause, `setInboundPaused` | every message from one chain; delegations, new validations and validation resends toward it; discards and resolutions of validations still awaiting its leg | the pauser; the token itself on every settlement leg from that chain it cannot account for (replayed, parked, rejected, orphaned) and on a conflicting proof from that chain | the pauser, `setInboundPaused(chainKey, false)` |
| chain issuance pause, `setIssuancePaused` on the compliance | new validations and validation resends toward one chain | the compliance manager; the compliance itself on a late settlement that breaches a rule, or a stuck pair resolved with the burn still owed | the compliance manager |
| route close, `setRoute(..., 0)` | new sends toward one chain and new admissions from it; a settlement pinned to the old gateway and a proof for a recall dispatched through it still land while that gateway stays trusted | the identity manager | the identity manager, with a trusted gateway |
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

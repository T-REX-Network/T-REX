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
| in | `COMPLIANCE_VALIDATION` | `ComplianceValidation` | stores it under `validationId` |
| in | `MINT_INSTRUCTION` | `MintInstruction { delegationId, toWallet, amount, holder }` | mints `amount` to `toWallet`, once per `delegationId` |
| in | `RECALL_INSTRUCTION` | `RecallInstruction { recallId, wallet, amount, nativeWallet }` | burns up to `amount` of `wallet` once, answers with a `BurnProof` |
| out | `SETTLEMENT_NOTIFICATION` | `SettlementNotification { validationId, from, to, amount }` | one per leg it executed |
| out | `BURN_PROOF` | `BurnProof { recallId, burnedWallet, amount }` | one per recall id, resent unchanged on request |

Every message travels through a gateway the network's `TrustedGatewayRegistry` trusts. The token accepts a settlement
only from the chain's current peer, and a burn proof for an open recall only from the peer and through the gateway
that recall was dispatched to.

## Rules

### Transport

1. **Act on each delivery once.** A gateway may redeliver; the Lite dedupes on the receive id, and also on the
   operation id, since a resend arrives under a new receive id: `validationId` for a validation, which delivered
   again, before or after it was consumed, is ignored (a resend repeats the issuance byte for byte), and the
   instruction ids of rules 9 and 10.
2. **Accept only the reference token as author**, through its own gateway.

### Validations

3. Execute a validation once.
4. Execute strictly before `expiry`.
5. Execute an amount inside `[amountMin, amountMax]`.
6. Execute only for the named wallets, by `from` or by the named `spender`.
7. Report every leg it executed, exactly once. One-leg movements carry both wallets; on a two-leg movement the sending
   Lite reports the burn leg with `to` empty, the receiving Lite the mint leg with `from` empty.

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

## Retries

Nothing is written off; a lost message is sent again.

| Lost | Who retries | How |
|---|---|---|
| validation leg | sender's identity or agent | `redispatchValidation(validationId, chainKey, to, spender)`: either leg while `Pending` and before `expiry`; the receiving chain's leg also once the burn landed, with no deadline; rebuilt from the record and checked against the issued hash; goes through the gateway the issuance pinned; refused while issuance toward that chain is paused |
| mint instruction | agent | `resend(0, delegationId, abi.encode(toWallet, amount, holder, peer))`, the fields from `DelegatedOut` and the peer at dispatch; checked against the stored commitment |
| recall instruction | agent | `resend(1, recallId, abi.encode(wallet))`; the admitted gateway moves to the current route, which delivers the resend |
| burn proof | Lite operator | resend the stored proof; the token settles it once |
| a proof delivered twice | nobody | the token recognises the settled proof and changes nothing (`BurnProofDuplicate`) |

A resend never retargets: it is refused (`PeerChanged`) once the chain's peer is no longer the one the instruction
was addressed to. A resend after a route switch is the expected way to recover a recall whose original gateway is gone.
A validation leg is the exception: its settlement is matched against the pinned gateway, so after a route switch the
leg is not resent (`ValidationAlreadyRouted`); the reservation comes back through discard at `releaseAt` and a new
validation is requested.

## What the reference chain does with a Lite that breaks a rule

| Broken rule | Reference-chain reaction |
|---|---|
| 3, 7: a settlement leg delivered again, or a leg for a pair the keeper already resolved | `ReplayedSettlement`, the token stops taking that chain's messages (`setInboundPaused`) |
| a settlement for a validation never issued | `ReplayedSettlement`, the token pauses itself |
| 5: amount outside the range | `SettlementOutOfBounds`, stays deliverable |
| 6: wrong wallets or chain | `SettlementLegMismatch`, stays deliverable |
| 8: two legs with two amounts | `SettlementAmountMismatch` on the second; the keeper resolves the pair after the second window |
| 10: proof above the instruction | `RecallAmountExceeded`, stays deliverable |
| 10: proof for another wallet | `RecallMismatch`, stays deliverable |
| 10: a different proof for a settled recall | `ReplayedBurnProof`, the token stops taking that chain's messages |
| a proof for a recall never issued | `ReplayedBurnProof`, the token pauses itself |

A reverted delivery can be redelivered once the cause is understood, on the assumption that the ERC-7786 gateway
keeps a reverted execution retryable; a gateway that marks it failed for good loses the message, and its author has
to send it again. Either pause is lifted by the pauser after an investigation: `setInboundPaused(chainKey, false)`
for one chain, `unpause` for the token. While a chain's inbound is paused its deliveries revert with
`ChainInboundPaused` and wait at the gateway; a delegation toward it is refused, and the compliance neither issues a
validation toward it nor resends one, nor discards or resolves a validation still awaiting that chain's leg, since
the held reports may answer it and acting on their absence would release or return what they move. Native transfers,
every other chain, and recall instructions and instruction resends toward the paused chain are unaffected; the proof
answering a recall lands once the pause is lifted. To abandon a chain for good: distrust its gateway or close its
route, then lift the pause so its validations can be discarded and resolved.

Threat model, stated plainly. A trusted gateway, or the registered peer behind it, can stop its own chain's inbound
with one message. It can also pause the whole token with one message naming an id the token never issued. That halt
is kept, with its price, because an unknown id on an attributed message has two readings the token cannot tell
apart: the peer invented it, which a chain pause would contain, or the token's own records are out of step with what
it dispatched (a compliance replaced or reset with legs in flight), which is local, taints what every chain reports,
and must not keep running. The remedy against a peer abusing it is to distrust its gateway.

### The brakes

| Brake | Stops | Set by | Lifted by |
|---|---|---|---|
| token pause, `pause` | every balance movement between wallets, native or satellite, and every inbound settlement and proof | the pauser; the token itself on a settlement or proof for an id it never issued | the pauser, `unpause` |
| chain inbound pause, `setInboundPaused` | every message from one chain; delegations, new validations and validation resends toward it; discards and resolutions of validations still awaiting its leg | the pauser; the token itself on a replayed settlement or a conflicting proof from that chain | the pauser, `setInboundPaused(chainKey, false)` |
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

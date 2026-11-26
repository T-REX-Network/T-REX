// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.30;

import { ISettlementHandler } from "../../interop/ISettlementHandler.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedgerLib } from "./ComplianceLedgerLib.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { ModuleSetLib } from "./ModuleSetLib.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { TransferValidationLib } from "./TransferValidationLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title TransferSettlementLib
 * @dev How an issued validation ends, deployed once and linked: {handleSettlement} applies what a satellite
 * executed, or parks a leg reported under an id nothing is issued under, which {settleParkedLeg} settles once
 * that id is issued; {discardExpiredValidations} rolls back what a satellite never did;
 * {resolveStuckValidation} closes a pair of which one leg never arrived. The states a validation moves through on the way, and what each move gives back,
 * are at the end of this file, in one place.
 *
 * These run once per cross-chain movement, never on a native transfer, and their bytecode is what kept the
 * compliance over EIP-170. The compliance reaches them by DELEGATECALL, so the storage is its own namespaces at
 * the slots they always had, the token and the modules see the compliance as their caller, and every event is
 * the compliance's. Who the caller is stays the compliance's to establish: its entry points check it, or pass
 * what they found, before they reach this.
 */
library TransferSettlementLib {

    /// @dev A leg is one satellite chain's half of a movement, and the notification it sends back once it has
    ///  executed.
    ///
    ///  A movement inside one satellite chain, or from a satellite to this one, is done by a single chain: one
    ///  leg, one notification, and the movement is complete when it arrives. A movement between two different
    ///  satellite chains is done by two chains that cannot act atomically: the sending chain destroys the
    ///  tokens on its side, the receiving chain creates them on its side, and each reports its own half. The
    ///  movement is complete only when both have reported.
    ///
    ///  This says which half a notification is.
    enum Leg {
        /// The whole movement, reported by the only chain involved.
        Single,
        /// The sending chain destroyed its side. The tokens are now in transit, belonging to nobody.
        Burn,
        /// The receiving chain created its side.
        Mint
    }

    /// @dev What a leg judged against the issued terms comes to, see {_judge}.
    enum Judgement {
        /// Inside the issued terms, from the chain recorded for its side: it is applied.
        Apply,
        /// Outside them: nothing is applied, the chain is paused, the validation stands.
        Refuse,
        /// Outside them, under another hash, from a chain the validation involves, while `Pending`: nothing is
        /// applied, the chain is paused, and the validation ends `Orphaned` with its reservation released.
        Orphan
    }

    /* ----- Settlement ----- */

    /// @dev Classifies an attributed settlement against the stored validation and applies it when it fits. Nothing
    ///  here reverts on the leg itself: a leg the record cannot account for is consumed with a verdict, see
    ///  {ISettlementHandler-handleSettlement} for the cases and {_classify} for the order they are told apart in.
    ///  The notification is announced first, whatever becomes of it. A delivery this chain has already consumed
    ///  from that chain, whatever its outcome was, is a duplicate and is told apart next, see {_recordDelivery}:
    ///  it is not classified again, so it applies nothing and pauses nothing. A leg parked earlier is not a
    ///  delivery and goes straight to {_classify}, through {settleParkedLeg}.
    /// @param token the token the compliance is bound to
    function handleSettlement(
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification calldata notification,
        address token
    ) external returns (ISettlementHandler.Verdict verdict) {
        emit EventsLib.SettlementNotified(
            originChainKey, notification.validationId, notification.from, notification.to, notification.amount
        );
        if (_recordDelivery(originChainKey, notification)) return ISettlementHandler.Verdict.None;
        return _classify(originChainKey, notification, token);
    }

    /// @dev Records a settlement delivery before it is classified, and tells whether this very delivery, the same
    ///  leg byte for byte from the same chain, was consumed before: a gateway redelivery, or a Lite's resend, which
    ///  repeats its settlement unchanged. A duplicate changes nothing and pauses nothing (`SettlementDuplicate`),
    ///  whatever the first delivery came to: a chain paused over a leg and reopened by the pauser is not paused
    ///  again by a copy of that leg. The record is one write per consumed delivery, and a revert while the leg is
    ///  classified undoes it with the rest, so the message stays deliverable.
    /// @return duplicate whether the delivery was consumed before
    function _recordDelivery(bytes32 chainKey, MessageTypesLib.SettlementNotification calldata notification)
        private
        returns (bool duplicate)
    {
        TransferValidationLib.ValidationStorage storage store = TransferValidationLib.layout();
        bytes32 deliveryKey = keccak256(abi.encode(chainKey, notification));
        duplicate = store.reportedLegs[deliveryKey];
        if (duplicate) emit EventsLib.SettlementDuplicate(notification.validationId, chainKey);
        else store.reportedLegs[deliveryKey] = true;
    }

    /// @dev See {ITransferValidation-settleParkedLeg}. The leg is judged as it would have been at delivery, and its
    ///  verdict applied on the token as it would have been then: settled, it is announced; refused, the brake
    ///  reaches the token through {IToken-applyVerdict}. A revert anywhere below leaves the leg parked, as a
    ///  revert at delivery leaves the message deliverable; the next call tries again.
    /// @param token the token the compliance is bound to
    function settleParkedLeg(bytes32 validationId, bytes32 chainKey, address token) external {
        MessageTypesLib.SettlementNotification memory parked = _takeParkedLeg(validationId, chainKey, token);
        ISettlementHandler.Verdict verdict = _classify(chainKey, parked, token);
        if (verdict == ISettlementHandler.Verdict.None) emit EventsLib.ParkedLegSettled(validationId, chainKey);
        else IToken(token).applyVerdict(chainKey, verdict);
    }

    /// @dev The one classification, for a leg delivered now and for a leg parked earlier and settled once its id
    ///  is issued. In order: no body issued under the id, so the leg is parked; the substantive gate, wallets and
    ///  amount against the issued terms, failed, so the leg is refused with the hash as the evidence of why; a
    ///  leg already accounted for, so a replay; and only then the leg is applied, late or not.
    function _classify(
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification memory notification,
        address token
    ) private returns (ISettlementHandler.Verdict) {
        ITransferValidation.Validation storage validation =
            TransferValidationLib.layout().validations[notification.validationId];
        // The hash is written when a validation is issued and sent, so a record without one was never sent
        // anywhere: an id never taken, or a request still awaiting approval, refused, or left unanswered. The
        // satellite executed a body this chain did not issue, which a reorg explains as well as a hostile Lite.
        if (validation.hash == bytes32(0)) {
            _park(originChainKey, notification);
            return ISettlementHandler.Verdict.PauseChain;
        }

        // 1. Which leg this is, and whether it sits inside the issued terms, see {_judge}.
        (Judgement judgement, Leg leg) = _judge(validation, originChainKey, notification);
        if (judgement != Judgement.Apply) {
            if (judgement == Judgement.Orphan) {
                _moveTo(validation, ITransferValidation.ValidationStatus.Orphaned, false, token);
            }
            return ISettlementHandler.Verdict.PauseChain;
        }
        if (_alreadyAccountedFor(validation.status, leg)) {
            emit EventsLib.ReplayedSettlement(notification.validationId, originChainKey);
            return ISettlementHandler.Verdict.PauseChain;
        }

        // 2. Take in what this chain reported: complete the movement, or wait for the other chain.
        bool late = _wasDiscarded(validation.status);
        bool breachesRule = _applyChainReport(validation, leg, notification, originChainKey, late, token);

        // 3. A late leg always warns; the chain pauses only when the recorded state breaches a rule, since late
        //    delivery is cheap to force and pausing on it would be a denial of service.
        if (late) {
            emit EventsLib.LateReconciliation(notification.validationId, originChainKey);
            if (breachesRule) TransferValidationLib.setIssuancePaused(originChainKey, true);
        }
        return ISettlementHandler.Verdict.None;
    }

    /// @dev Takes in what one chain reported and moves the validation on.
    ///
    ///  When one chain was doing the whole movement, its report completes it. When two chains are involved,
    ///  the first report to arrive is recorded and the validation waits, keeping that report's amount and
    ///  wallet for the other chain to match; the second report completes the movement.
    ///
    ///  Only the report that completes the movement consults the rules, so a validation can produce at most
    ///  one finding.
    function _applyChainReport(
        ITransferValidation.Validation storage validation,
        Leg leg,
        MessageTypesLib.SettlementNotification memory notification,
        bytes32 originChainKey,
        bool late,
        address token
    ) private returns (bool breachesRule) {
        bool isBurnLeg = leg == Leg.Burn;
        bool isSingleLeg = leg == Leg.Single;
        (ITransferValidation.ValidationStatus next, bool completesMovement) =
            _stateAfterLeg(validation.status, isBurnLeg, isSingleLeg);

        if (!completesMovement) {
            _recordFirstLeg(
                validation,
                isBurnLeg ? notification.from : notification.to,
                isBurnLeg,
                notification,
                originChainKey,
                next,
                token
            );
            return false;
        }

        // The movement completes here. On a pair, the wallet the first leg carried is the far side of it.
        bytes memory from = notification.from;
        bytes memory to = notification.to;
        if (!isSingleLeg) {
            _requireRepeatsFirstLeg(validation, notification);
            if (isBurnLeg) to = validation.legWallet;
            else from = validation.legWallet;
        }
        return _settleValidation(validation, from, to, notification, originChainKey, late, next, token);
    }

    /// @dev Judges a leg against the issued terms: the wallets it carries and the chain it comes from say which
    ///  leg it is, and its amount must sit inside the range. Inside the terms it is applied whatever hash it
    ///  names (`SettlementBodyDiverged` when not the issued one): the hash is evidence, never the gate.
    ///
    ///  Outside the terms nothing is applied and the chain is paused; the hash and the origin say which event
    ///  records it. A chain the validation does not involve could not have executed anything under it, whatever
    ///  hash it names: rejected. The issued hash from an involved chain: the Lite broke rule 5 or 6 on the body
    ///  this chain issued; rejected, and the validation stands, so the discard and the resolution still have
    ///  their say. Another hash from an involved chain: the Lite executed a body this chain never canonically
    ///  issued, which a reorg orphaned. While `Pending` the validation ends `Orphaned` and what it reserved comes
    ///  back, since the tokens moved under terms this chain never reserved for and the ledger cannot absorb an
    ///  amount outside them. In any other state it stands: a leg already landed and the keeper resolves the pair
    ///  after the second window, or the discard already gave the reservation back.
    ///
    ///  The hash is the Lite's word, which is why the orphaned reading is confined to the chains the validation
    ///  names. On one leg, the most a lying Lite gets is ending its own validation early, on its own chain, which
    ///  is paused for it. On a pair, the honest leg from the other chain then lands as a replay and pauses that
    ///  chain too: a hostile involved peer, answered as any hostile peer is, by distrusting its gateway.
    function _judge(
        ITransferValidation.Validation storage validation,
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification memory notification
    ) private returns (Judgement judgement, Leg leg) {
        bool matches;
        (leg, matches) = _matchLeg(validation, originChainKey, notification);
        bool inRange = validation.amountMin <= notification.amount && notification.amount <= validation.amountMax;
        if (matches && inRange) {
            if (notification.hash != validation.hash) {
                emit EventsLib.SettlementBodyDiverged(notification.validationId, originChainKey, notification.hash);
            }
            return (Judgement.Apply, leg);
        }

        bool chainHoldsALeg = originChainKey == validation.fromChainKey
            || (validation.twoLegs && originChainKey == validation.toChainKey);
        bool executedTheIssuedBody = notification.hash == validation.hash;
        // The chain could not have executed anything under this id, or it executed the very body this chain
        // issued and left its terms.
        bool noReorgExplainsTheLeg = !chainHoldsALeg || executedTheIssuedBody;
        if (noReorgExplainsTheLeg) {
            emit EventsLib.SettlementRejected(
                notification.validationId, originChainKey, notification.amount, notification.hash
            );
            return (Judgement.Refuse, leg);
        }
        emit EventsLib.ValidationOrphaned(
            notification.validationId, originChainKey, notification.amount, notification.hash
        );
        bool pending = validation.status == ITransferValidation.ValidationStatus.Pending;
        return (pending ? Judgement.Orphan : Judgement.Refuse, leg);
    }

    /// @dev A leg is matched by the wallets it carries and the chain it comes from. A one-leg validation expects
    ///  both wallets, the issued ones, from `from`'s chain. A two-leg validation expects the burn leg, `to` empty,
    ///  from `from`'s chain, and the mint leg, `from` empty, from `to`'s chain; a leg carrying both wallets is
    ///  neither. Whether it matched is returned, not required: the caller decides what a mismatch means.
    function _matchLeg(
        ITransferValidation.Validation storage validation,
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification memory notification
    ) private view returns (Leg leg, bool matches) {
        bool fromMatches = notification.from.length != 0 && keccak256(notification.from) == validation.fromKey;
        bool toMatches = notification.to.length != 0 && keccak256(notification.to) == validation.toKey;
        if (!validation.twoLegs) {
            return (Leg.Single, fromMatches && toMatches && originChainKey == validation.fromChainKey);
        }
        if (fromMatches && notification.to.length == 0 && originChainKey == validation.fromChainKey) {
            return (Leg.Burn, true);
        }
        if (toMatches && notification.from.length == 0 && originChainKey == validation.toChainKey) {
            return (Leg.Mint, true);
        }
        return (Leg.Single, false);
    }

    /* ----- Parked legs ----- */

    /// @dev Keeps a leg reported for an id nothing was issued under, one per origin chain, so that once the
    ///  request is sent again with the same salt it can be settled, see {settleParkedLeg}. A second leg from the
    ///  same chain is a replay; the parked leg delivered again never reaches here, see {_recordDelivery}. Either
    ///  way the caller pauses the chain: it executed what this chain never sent.
    function _park(bytes32 originChainKey, MessageTypesLib.SettlementNotification memory notification) private {
        ITransferValidation.ParkedLeg storage parked =
            TransferValidationLib.layout().parkedLegs[notification.validationId][originChainKey];
        if (parked.exists) {
            emit EventsLib.ReplayedSettlement(notification.validationId, originChainKey);
            return;
        }
        parked.from = notification.from;
        parked.to = notification.to;
        parked.amount = notification.amount;
        parked.hash = notification.hash;
        parked.exists = true;
        emit EventsLib.SettlementParked(
            notification.validationId, originChainKey, notification.amount, notification.hash
        );
    }

    /// @dev Takes the leg parked under `(validationId, chainKey)` out of storage and hands it back as the
    ///  notification it was, to be judged and applied as a delivery, see {ITransferValidation-settleParkedLeg}
    ///  for the requirements. A revert further on undoes the take.
    function _takeParkedLeg(bytes32 validationId, bytes32 chainKey, address token)
        private
        returns (MessageTypesLib.SettlementNotification memory notification)
    {
        TransferValidationLib.ValidationStorage storage store = TransferValidationLib.layout();
        ITransferValidation.ParkedLeg memory parked = store.parkedLegs[validationId][chainKey];
        // A leg is parked under the id for this chain.
        require(parked.exists, ErrorsLib.ParkedLegNotSettleable(validationId, chainKey));
        // The id is issued: a record without a hash was never sent anywhere, and there is nothing to judge against.
        require(
            store.validations[validationId].hash != bytes32(0), ErrorsLib.ParkedLegNotSettleable(validationId, chainKey)
        );
        require(!IToken(token).paused(), ErrorsLib.TokenPaused());
        // A delivered leg from a paused chain waits at the gateway; a parked one from it waits here, for the same
        // investigation. The re-request is refused under the pause too, see
        // {TransferValidationLib-requireInboundOpen}.
        TransferValidationLib.requireInboundOpen(token, chainKey);
        delete store.parkedLegs[validationId][chainKey];
        notification = MessageTypesLib.SettlementNotification({
            validationId: validationId, from: parked.from, to: parked.to, amount: parked.amount, hash: parked.hash
        });
    }

    /// @dev The first of the two chains to report, whichever it is: the amount and the wallet it carries are
    ///  kept for the other one, and the validation is pinned. A first burn leg is proof the sender's satellite position is gone, so
    ///  the amount leaves that position and waits in transit on the ledger, and the wallet's pending amount stops
    ///  counting it; a first mint leg moves nothing until the burn leg lands, and the pair is then applied
    ///  atomically. A late first leg stays `Discarded`, its flag set, and holds all the same: the burn is final
    ///  either way.
    function _recordFirstLeg(
        ITransferValidation.Validation storage validation,
        bytes memory wallet,
        bool burn,
        MessageTypesLib.SettlementNotification memory notification,
        bytes32 originChainKey,
        ITransferValidation.ValidationStatus next,
        address token
    ) private {
        validation.executedAmount = notification.amount;
        validation.legWallet = wallet;

        // A burn leg takes the tokens out of the wallet, and the hold gives back whatever this validation had
        // reserved against it at the same time. So when there is something to give back, the hold carries it
        // and `_moveTo` leaves the wallet's half alone; otherwise `_moveTo` releases it the usual way.
        uint256 releasedByTheHold = 0;
        if (burn && _stillReservesWallet(validation.status)) {
            releasedByTheHold = validation.amountMax;
        }

        _moveTo(validation, next, releasedByTheHold > 0, token);

        if (burn) {
            IToken(token).holdInTransit(wallet, notification.amount, notification.validationId, releasedByTheHold);
        }

        emit EventsLib.ValidationLegConfirmed(notification.validationId, originChainKey, notification.amount);
    }

    /// @dev The movement a settled validation turns out to be, as the modules are asked about it. Its own
    ///  function because the settlement path holds enough live values without it, and the legacy pipeline runs
    ///  out of stack there under `forge coverage`.
    ///
    ///  A native recipient may have changed owner since issuance, so it is resolved again here, through the
    ///  registry; a wallet the registry no longer names keeps the identity it was issued to. The token has not
    ///  been credited yet at this point, which is why nothing is adjusted for this very movement.
    function _settledMovement(
        ITransferValidation.Validation storage validation,
        bytes memory from,
        bytes memory to,
        uint256 amount,
        address token
    ) private returns (IModule.TransferContext memory) {
        address toIdentity = validation.toIdentity;
        (bool toNative, address toWallet) = WalletKeyLib.isReferenceChain(to);
        if (toNative) {
            ITREXRegistry registry = ITREXRegistry(address(IToken(token).identityRegistry()));
            address registryIdentity = address(registry.identity(toWallet));
            if (registryIdentity == address(0)) registryIdentity = toIdentity;
            toIdentity = ComplianceLedgerLib.currentOwner(token, toWallet, registryIdentity, 0);
        }

        return TransferContextLib.settlement(
            address(this),
            validation.fromIdentity,
            toIdentity,
            WalletKeyLib.walletId(from),
            WalletKeyLib.walletId(to),
            amount,
            validation.spender
        );
    }

    /// @dev Every expected leg is in, so the movement completes: release whatever is still reserved, move the
    ///  positions and the token's ledger, mark the validation, announce it, then tell the tracker modules.
    ///
    ///  A late settlement is applied all the same, since the satellite already executed it and nothing on this
    ///  chain can undo that. What a late one additionally produces is a verdict, see {_exceedsWhatRulesAllowNow},
    ///  and that verdict is what decides whether the chain that sent it stops issuing.
    ///
    ///  A tracker that reverts here reverts the delivery, and the delivery stays deliverable. That is deliberate:
    ///  swallowing the revert would leave that module's counter silently wrong, which no later message can
    ///  repair, while a refused delivery is repaired by `forceRemoveModule` and a redelivery.
    function _settleValidation(
        ITransferValidation.Validation storage validation,
        bytes memory from,
        bytes memory to,
        MessageTypesLib.SettlementNotification memory notification,
        bytes32 originChainKey,
        bool late,
        ITransferValidation.ValidationStatus next,
        address token
    ) private returns (bool breachesRule) {
        validation.executedAmount = notification.amount;
        _moveTo(validation, next, false, token);

        IModule.TransferContext memory ctx = _settledMovement(validation, from, to, notification.amount, token);
        breachesRule = late && _exceedsWhatRulesAllowNow(ctx, notification.amount);

        ComplianceLedgerLib.movePosition(
            ctx.fromIdentity, ctx.toIdentity, ctx.fromWallet, ctx.toWallet, notification.amount
        );
        IToken(token).settleValidation(from, to, notification.amount, notification.validationId);

        emit EventsLib.ValidationSettled(notification.validationId, originChainKey, notification.amount);
        ModuleSetLib.callAfterTransfer(ctx);
    }

    /// @dev Both chains must report the same amount: the first one to arrive recorded it, the second has to
    ///  repeat it. A mismatch means the two chains executed different movements under one id, which no ledger
    ///  can reconcile, so it is refused.
    function _requireRepeatsFirstLeg(
        ITransferValidation.Validation storage validation,
        MessageTypesLib.SettlementNotification memory notification
    ) private view {
        require(
            notification.amount == validation.executedAmount,
            ErrorsLib.SettlementAmountMismatch(
                notification.validationId, validation.executedAmount, notification.amount
            )
        );
    }

    /// @dev Whether an amount a satellite already executed is more than the rules would allow today.
    ///
    ///  Asked only of a settlement that arrives after its validation was discarded. The tokens moved on the
    ///  other chain regardless, so this is not permission, it is a finding: the answer decides whether the
    ///  chain that sent it is stopped from issuing until someone looks into it.
    ///
    ///  Asked once the reservation is released, so the rules judge the state the movement actually lands on. A
    ///  relocation between two wallets of one identity moves no position, so no distribution rule applies to it.
    function _exceedsWhatRulesAllowNow(IModule.TransferContext memory ctx, uint256 amount) private view returns (bool) {
        if (ComplianceLedgerLib.isRelocation(ctx.fromIdentity, ctx.toIdentity)) return false;
        return amount > ModuleSetLib.callCheckTransfer(ctx);
    }

    /* ----- Discard ----- */

    /// @dev The way out of a pair of which one leg never arrived. The gate is a second reconciliation window
    ///  past `releaseAt`, the same length as the first, so a leg that is merely slow still lands as a late
    ///  reconciliation and never as a resolution.
    ///
    ///  When the burn leg is the one that landed, the tokens it burned are waiting in transit: they go back to
    ///  the wallet they left. When it was the mint leg, nothing on this chain can be returned, so the chain
    ///  that owes the burn stops being issued to instead and an operator investigates. Either way the
    ///  validation ends in `Resolved`, where any leg arriving afterwards pauses its chain's inbound. While the
    ///  chain owing the leg has its inbound paused on the token the leg may be waiting at its gateway, so the
    ///  pair is not resolved under the pause, see {TransferValidationLib-requireAwaitedInboundOpen}.
    /// @param token the token the compliance is bound to
    function resolveStuckValidation(bytes32 validationId, address token) external {
        TransferValidationLib.ValidationStorage storage store = TransferValidationLib.layout();
        require(TransferValidationLib.isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
        ITransferValidation.Validation storage validation = store.validations[validationId];
        require(
            _awaitingOtherLeg(validation.status), ErrorsLib.ValidationNotStuck(validationId, uint8(validation.status))
        );

        uint64 resolvableAt = _secondWindowEnd(validation);
        require(block.timestamp > resolvableAt, ErrorsLib.ValidationNotYetResolvable(validationId, resolvableAt));
        TransferValidationLib.requireAwaitedInboundOpen(token, validation);

        uint256 returnedAmount = 0;
        if (_burnArrived(validation.status)) {
            returnedAmount = validation.executedAmount;
            // A validation issued with a zero minimum may burn nothing, and a burn of nothing held nothing in
            // transit: there is nothing to give back, and the token refuses to return an empty hold.
            if (returnedAmount != 0) IToken(token).returnHeldInTransit(validation.legWallet, validationId);
        } else {
            TransferValidationLib.setIssuancePaused(validation.fromChainKey, true);
        }

        _moveTo(validation, ITransferValidation.ValidationStatus.Resolved, false, token);

        emit EventsLib.ValidationResolved(validationId, returnedAmount);
    }

    /// @dev Each id must be stored `Pending` and past `releaseAt`; one still awaiting a leg is refused whatever
    ///  the clock says. One refused id reverts the whole batch.
    /// @dev Who may: the keeper from `releaseAt`, anyone from the end of the second window. A discard turns a
    ///  leg that lands afterwards into a late reconciliation, which can pause its chain's issuance, so during the
    ///  first window the keeper alone judges that a leg is late rather than slow. Past the second window a pair
    ///  would be resolvable anyway, so whoever is left waiting on the reservation may release it, keeper or not.
    ///  Nor is a validation discarded while a chain it awaits has its inbound paused on the token: its leg may be
    ///  waiting at that gateway, see {TransferValidationLib-requireAwaitedInboundOpen}. Nor while a leg is parked
    ///  under its id: that report waits here instead, see {_requireNoParkedLeg}.
    /// @param token the token the compliance is bound to
    /// @param keeper whether the AccessManager binds the caller to this selector's role
    function discardExpiredValidations(bytes32[] calldata validationIds, address token, bool keeper) external {
        TransferValidationLib.ValidationStorage storage store = TransferValidationLib.layout();
        for (uint256 i = 0; i < validationIds.length; i++) {
            bytes32 validationId = validationIds[i];
            require(TransferValidationLib.isRecorded(store, validationId), ErrorsLib.UnknownValidation(validationId));
            ITransferValidation.Validation storage validation = store.validations[validationId];
            // Nothing was sent for a validation still awaiting approval, so no leg can be in flight: anyone may
            // discard it once its deadline passed, and the reservation comes back.
            if (validation.status == ITransferValidation.ValidationStatus.AwaitingApproval) {
                TransferValidationLib.discardUnanswered(validationId, token);
                continue;
            }
            require(
                validation.status == ITransferValidation.ValidationStatus.Pending,
                ErrorsLib.ValidationNotDiscardable(validationId, uint8(validation.status))
            );
            require(
                block.timestamp > validation.releaseAt,
                ErrorsLib.ValidationNotReleasable(validationId, validation.releaseAt)
            );
            if (!keeper) {
                uint64 publicAt = _secondWindowEnd(validation);
                require(block.timestamp > publicAt, ErrorsLib.ValidationNotPubliclyDiscardable(validationId, publicAt));
            }
            TransferValidationLib.requireAwaitedInboundOpen(token, validation);
            _requireNoParkedLeg(store, validationId, validation.fromChainKey);
            if (validation.twoLegs) _requireNoParkedLeg(store, validationId, validation.toChainKey);

            _moveTo(validation, ITransferValidation.ValidationStatus.Discarded, false, token);

            emit EventsLib.ValidationDiscarded(validationId);
        }
    }

    /// @dev A validation is not discarded over a leg parked under its id. The leg was reported while nothing was
    ///  issued and waits for {settleParkedLeg}; discarding first would release the reservation of a movement this
    ///  chain already holds the report of, and turn that report into a late reconciliation. From `Pending` the
    ///  parked leg is always consumed, applied or refused, so this never leaves a validation without a way out.
    function _requireNoParkedLeg(
        TransferValidationLib.ValidationStorage storage store,
        bytes32 validationId,
        bytes32 chainKey
    ) private view {
        require(
            !store.parkedLegs[validationId][chainKey].exists,
            ErrorsLib.ParkedLegAwaitsSettlement(validationId, chainKey)
        );
    }

    /// @dev The end of the second reconciliation window: one more window past `releaseAt`, the same length as
    ///  the first. Resolution and the public discard both open here.
    function _secondWindowEnd(ITransferValidation.Validation storage validation) private view returns (uint64) {
        return validation.releaseAt + (validation.releaseAt - validation.expiry);
    }

    /* ----- The lifecycle, in one place ----- */

    /// @dev Whether the burn leg has arrived in this state.
    function _burnArrived(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.AwaitingMint
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingMint
            || status == ITransferValidation.ValidationStatus.Settled
            || status == ITransferValidation.ValidationStatus.LateReconciled;
    }

    /// @dev Whether the mint leg has arrived in this state.
    function _mintArrived(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.AwaitingBurn
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingBurn
            || status == ITransferValidation.ValidationStatus.Settled
            || status == ITransferValidation.ValidationStatus.LateReconciled;
    }

    /// @dev Whether this leg has nothing left to do: either its own half already arrived, the keeper gave up
    ///  on the pair and sent the tokens back, or the validation ended `Orphaned` on a leg this chain could not
    ///  account for. All mean the amount it carries is already accounted for somewhere else, or never can be,
    ///  so applying it would move tokens twice. The caller pauses the leg's chain.
    function _alreadyAccountedFor(ITransferValidation.ValidationStatus status, Leg leg) private pure returns (bool) {
        if (
            status == ITransferValidation.ValidationStatus.Resolved
                || status == ITransferValidation.ValidationStatus.Orphaned
        ) return true;
        if (leg == Leg.Mint) return _mintArrived(status);
        return _burnArrived(status);
    }

    /// @dev Whether the keeper has given up on this validation, in any of the states that say so.
    function _wasDiscarded(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.Discarded
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingMint
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingBurn;
    }

    /// @dev Whether exactly one leg of a pair has arrived and the other is still owed. Such a validation can be
    ///  neither discarded nor derived `Expired`: one satellite has already executed irreversibly.
    function _awaitingOtherLeg(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.AwaitingMint
            || status == ITransferValidation.ValidationStatus.AwaitingBurn
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingMint
            || status == ITransferValidation.ValidationStatus.DiscardedAwaitingBurn;
    }

    /// @dev Whether the validation still counts in the ledger's pending amounts in this state: the total for
    ///  every validation, the identities' rows for every one that is not a relocation.
    function _stillReservesPending(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.Pending
            || status == ITransferValidation.ValidationStatus.AwaitingMint
            || status == ITransferValidation.ValidationStatus.AwaitingBurn
            || status == ITransferValidation.ValidationStatus.AwaitingApproval;
    }

    /// @dev Whether the sender wallet's pending amount is still reserved in this state. Once the burn leg has
    ///  arrived the tokens are in transit, so the wallet's cap must stop counting them.
    function _stillReservesWallet(ITransferValidation.ValidationStatus status) private pure returns (bool) {
        return status == ITransferValidation.ValidationStatus.Pending
            || status == ITransferValidation.ValidationStatus.AwaitingBurn
            || status == ITransferValidation.ValidationStatus.AwaitingApproval;
    }

    /// @dev Where a validation goes when a leg lands on it, and whether that leg completes the movement.
    ///
    ///  A single-leg validation settles outright. A pair in `Pending` records the first leg and waits for the
    ///  other; the same pair already discarded waits in the matching `Discarded*` state instead, so that when
    ///  the second leg lands it reconciles late rather than settling. Any state this is not called for is a leg
    ///  for a leg already arrived, which the caller has refused as a replay.
    ///
    /// @param status where the validation stands
    /// @param burnLeg the leg that landed is the one from the sender's chain
    /// @param singleLeg the validation expects one leg, not two
    /// @return next where it stands afterwards
    /// @return completesMovement whether the movement is now complete, so positions move and rules are asked
    function _stateAfterLeg(ITransferValidation.ValidationStatus status, bool burnLeg, bool singleLeg)
        private
        pure
        returns (ITransferValidation.ValidationStatus next, bool completesMovement)
    {
        bool discarded = _wasDiscarded(status);

        if (singleLeg) {
            return (
                discarded
                    ? ITransferValidation.ValidationStatus.LateReconciled
                    : ITransferValidation.ValidationStatus.Settled,
                true
            );
        }
        if (status == ITransferValidation.ValidationStatus.Pending) {
            return (
                burnLeg
                    ? ITransferValidation.ValidationStatus.AwaitingMint
                    : ITransferValidation.ValidationStatus.AwaitingBurn,
                false
            );
        }
        if (status == ITransferValidation.ValidationStatus.Discarded) {
            return (
                burnLeg
                    ? ITransferValidation.ValidationStatus.DiscardedAwaitingMint
                    : ITransferValidation.ValidationStatus.DiscardedAwaitingBurn,
                false
            );
        }
        // One leg was already in and the other has now landed: the pair is complete.
        return (
            discarded
                ? ITransferValidation.ValidationStatus.LateReconciled
                : ITransferValidation.ValidationStatus.Settled,
            true
        );
    }

    /// @dev Moves a validation to `next` and gives back whatever `next` no longer reserves. Because the
    ///  reservations are read off the status, a release happens exactly when the move stops reserving something,
    ///  and arriving twice at the same state gives nothing back twice. A validation `AwaitingApproval` is
    ///  released in `TransferValidationLib._release` instead, which mirrors this: keep the two in step.
    /// @param heldByTheHold true when the caller is about to take an in-transit hold, which gives the wallet's
    ///  reservation back itself; this function then leaves that half alone rather than releasing it twice.
    function _moveTo(
        ITransferValidation.Validation storage validation,
        ITransferValidation.ValidationStatus next,
        bool heldByTheHold,
        address token
    ) private {
        ITransferValidation.ValidationStatus current = validation.status;

        if (_stillReservesPending(current) && !_stillReservesPending(next)) {
            ComplianceLedgerLib.releasePendingTotal(validation.amountMax);
            // A relocation never wrote the identities' rows, so there is nothing to give back there.
            bool identitiesWereReserved = !validation.relocation;
            if (identitiesWereReserved) {
                ComplianceLedgerLib.releasePendingOfIdentities(
                    validation.fromIdentity, validation.toIdentity, validation.amountMax
                );
            }
        }
        if (_stillReservesWallet(current) && !_stillReservesWallet(next) && !heldByTheHold) {
            IToken(token).releaseFromValidation(validation.fromWallet, validation.amountMax);
        }

        validation.status = next;
    }

}

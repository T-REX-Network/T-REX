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
/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
pragma solidity 0.8.30;

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { MessageTypesLib } from "../../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../registry/interface/ITREXRegistry.sol";
import { IToken } from "../../token/IToken.sol";
import { ComplianceLedger } from "./ComplianceLedger.sol";
import { ITransferValidation } from "./ITransferValidation.sol";
import { TransferContextLib } from "./TransferContextLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title TransferValidation
 * @dev The compliance's issuance layer for satellite movements: the two windows, the per-chain pause, the record
 * of every issued validation, the issuance itself, the pending reservation it writes, settlement, discard and the
 * late-reconciliation surface. Own ERC-7201 namespace, so the module registry's layout is untouched.
 *
 * Three flows, each readable top to bottom: `requestTransferValidation` issues, `_handleSettlement` applies what
 * a satellite executed, `_discardExpiredValidations` rolls back what it never did. The reservation involves no
 * module: issuance writes the pending amounts into the ledger and the other two flows release them once.
 *
 * `from` is always a satellite wallet, never a native one: the Lite that executes a validation has to physically
 * hold the position it moves, where a native balance stays free to leave between issuance and settlement. A native
 * position reaches a satellite through delegation-out instead, which burns before it instructs.
 *
 * `expiry` is the satellite's hard deadline; `expiry + reconciliationWindow` is when T-REX may release the
 * reservation, never a refusal of a late leg. Validations expire; settlements never do.
 */
abstract contract TransferValidation is ITransferValidation, ComplianceLedger {

    /// @custom:storage-location erc7201:erc3643.storage.TransferValidation
    struct ValidationStorage {
        /// Added to the issuance timestamp to compute `expiry`. Zero blocks issuance.
        uint64 defaultValidityWindow;
        /// Per-chain worst-case reconciliation latency. Zero blocks issuance toward that chain.
        mapping(bytes32 chainKey => uint64 window) reconciliationWindows;
        /// Per-chain issuance pause, set by the manager or a breaching late reconciliation, lifted by the manager
        /// only.
        mapping(bytes32 chainKey => bool paused) issuancePaused;
        /// The last id issued. Ids start at 1.
        uint256 lastValidationId;
        /// Every issued validation, kept forever.
        mapping(uint256 validationId => Validation validation) validations;
    }

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

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TransferValidation")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VALIDATION_STORAGE_LOCATION =
        0x518dcda4927033bd42da8dd6047b92b4a950cebbc5bdd8461a5e9bb9c0545400;

    /// @dev What issuance works out before the first write, in memory so the flow stays one function.
    struct Draft {
        bytes32 fromChainKey;
        bytes32 toChainKey;
        bool twoLegs;
        address fromIdentity;
        address toIdentity;
        bytes32 fromKey;
        uint256 amountMin;
        uint256 amountMax;
        uint64 expiry;
        uint64 reconciliationWindow;
    }

    /* ----- Issuance ----- */

    /// @inheritdoc ITransferValidation
    /// @dev Five questions, in order: where is this going, may the caller ask for it, by when must it happen,
    ///  how much may actually move, and may the named spender execute it. Only then is anything written.
    function requestTransferValidation(
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender
    ) external returns (uint256 validationId) {
        require(requestedMin <= requestedMax, ErrorsLib.InvalidRequestedRange(requestedMin, requestedMax));

        Draft memory draft;
        draft.amountMin = requestedMin;
        draft.amountMax = requestedMax;
        _resolveRoute(draft, from, to, spender);
        _requireCallerOwnsTheWallet(draft, from);
        _setExpiryAndRelease(draft);
        _narrowAmountRange(draft, from, to);
        _requireSpenderAllowed(draft, to, spender);

        validationId = _issueValidation(from, to, spender, draft);
    }

    /// @dev Where the movement goes: both envelopes parse, the sender sits on a satellite, and the legs are
    ///  two when the wallets are on two different satellite chains. The spender is parsed here and judged in
    ///  {_requireSpenderAllowed}, once the range is known.
    function _resolveRoute(Draft memory draft, bytes calldata from, bytes calldata to, bytes calldata spender)
        private
        view
    {
        (bool fromNative,) = WalletKeyLib.isReferenceChain(from);
        require(!fromNative, ErrorsLib.SenderNotOnSatellite(from));
        (bool toNative,) = WalletKeyLib.isReferenceChain(to);
        draft.fromChainKey = _chainKeyOf(from);
        draft.toChainKey = _chainKeyOf(to);
        draft.twoLegs = !toNative && draft.fromChainKey != draft.toChainKey;
        if (spender.length != 0) WalletKeyLib.parse(spender);
    }

    /// @dev Who may ask: the identity the sending wallet is linked to, or an address the AccessManager
    ///  authorised for this selector. A satellite wallet never matches its own bytes, so a wallet can never
    ///  request a validation for itself; its identity does that.
    function _requireCallerOwnsTheWallet(Draft memory draft, bytes calldata from) private view {
        draft.fromIdentity = address(_boundRegistry().resolveIdentity(from));
        require(draft.fromIdentity != address(0), ErrorsLib.UnverifiedWallet(from));
        require(
            msg.sender == draft.fromIdentity || _canCallSelector(msg.sender, this.requestTransferValidation.selector),
            ErrorsLib.NotAuthorizedForWallet(msg.sender, from)
        );
    }

    /// @dev By when: the satellite's deadline from the validity window, and the reservation's from the larger
    ///  reconciliation window of the chains involved. Every chain involved must be open and configured.
    function _setExpiryAndRelease(Draft memory draft) private view {
        ValidationStorage storage store = _validationStorage();
        require(store.defaultValidityWindow != 0, ErrorsLib.ValidityWindowNotSet());
        draft.reconciliationWindow = _openChainWindow(store, draft.fromChainKey);
        if (draft.twoLegs) {
            uint64 toWindow = _openChainWindow(store, draft.toChainKey);
            if (toWindow > draft.reconciliationWindow) draft.reconciliationWindow = toWindow;
        }
        draft.expiry = uint64(block.timestamp) + store.defaultValidityWindow;
    }

    /// @dev How much may move. The range only ever narrows: first to what the sending wallet still has free,
    ///  then to the smallest amount the rules allow.
    function _narrowAmountRange(Draft memory draft, bytes calldata from, bytes calldata to) private view {
        ITREXRegistry registry = _boundRegistry();
        require(registry.isWalletVerified(to), ErrorsLib.UnverifiedWallet(to));
        draft.toIdentity = address(registry.resolveIdentity(to));
        draft.fromKey = WalletKeyLib.canonicalKey(from);

        _capAtWhatTheWalletCanSend(draft, from);
        _capAtWhatTheRulesAllow(draft, to);
        require(draft.amountMax != 0, ErrorsLib.ZeroValue());
    }

    /// @dev Caps the range at what the sending wallet can still send: its bridged balance less what earlier
    ///  validations may still draw from it.
    function _capAtWhatTheWalletCanSend(Draft memory draft, bytes calldata from) private view {
        uint256 free = _boundToken().availableOf(from);
        if (free < draft.amountMax) draft.amountMax = free;
        require(draft.amountMin <= draft.amountMax, ErrorsLib.EmptyValidationRange(draft.amountMin, draft.amountMax));
    }

    /// @dev Caps the range at the smallest amount the rules allow. Skipped when both wallets belong to one
    ///  identity, since relocating your own tokens changes no position and no distribution rule applies.
    function _capAtWhatTheRulesAllow(Draft memory draft, bytes calldata to) private view {
        if (_isRelocation(draft.fromIdentity, draft.toIdentity)) return;
        IModule.TransferContext memory ctx = TransferContextLib.issuance(
            address(this),
            draft.fromIdentity,
            draft.toIdentity,
            draft.fromKey,
            WalletKeyLib.walletId(to),
            draft.amountMin,
            draft.amountMax,
            ""
        );
        uint256 allowed = _minAllowedAmount(ctx);
        if (allowed < draft.amountMax) draft.amountMax = allowed;
        require(draft.amountMin <= draft.amountMax, ErrorsLib.EmptyValidationRange(draft.amountMin, draft.amountMax));
    }

    /// @dev Who may execute: every `SPENDER` module must accept the named spender, since no module runs on the
    ///  satellite and this is the only place it can be refused. A validation the sender executes itself names
    ///  no spender and asks nobody. Asked on a relocation too: who executes is not about distribution.
    function _requireSpenderAllowed(Draft memory draft, bytes calldata to, bytes calldata spender) private view {
        if (spender.length == 0) return;
        IModule.TransferContext memory ctx = TransferContextLib.issuance(
            address(this),
            draft.fromIdentity,
            draft.toIdentity,
            draft.fromKey,
            WalletKeyLib.walletId(to),
            draft.amountMin,
            draft.amountMax,
            spender
        );
        require(_spenderAllowed(ctx), ErrorsLib.ValidationSpenderRefused(spender));
    }

    /// @dev Turns a settled draft into an issued validation: take the next id, build the object the satellite
    ///  will execute against, keep its terms, reserve the amount, then announce it and send one leg per
    ///  satellite chain involved.
    function _issueValidation(bytes calldata from, bytes calldata to, bytes calldata spender, Draft memory draft)
        private
        returns (uint256 validationId)
    {
        validationId = ++_validationStorage().lastValidationId;

        MessageTypesLib.ComplianceValidation memory issued =
            _buildIssuedValidation(validationId, from, to, spender, draft);
        _recordValidation(validationId, issued, from, to, draft);

        emit EventsLib.TransferValidationIssued(
            validationId, from, to, spender, draft.amountMin, draft.amountMax, draft.expiry, draft.reconciliationWindow
        );

        bytes memory body = abi.encode(issued);
        _dispatchLeg(draft.fromChainKey, validationId, body);
        if (draft.twoLegs) _dispatchLeg(draft.toChainKey, validationId, body);
    }

    /// @dev The object a satellite executes against, and the one this contract hashes: the terms of the
    ///  movement plus the token they belong to.
    function _buildIssuedValidation(
        uint256 validationId,
        bytes calldata from,
        bytes calldata to,
        bytes calldata spender,
        Draft memory draft
    ) private view returns (MessageTypesLib.ComplianceValidation memory) {
        return MessageTypesLib.ComplianceValidation({
            validationId: validationId,
            from: from,
            to: to,
            spender: spender,
            amountMin: draft.amountMin,
            amountMax: draft.amountMax,
            expiry: draft.expiry,
            reconciliationWindow: draft.reconciliationWindow,
            token: address(_boundToken())
        });
    }

    /// @dev Keeps the validation forever and reserves its amount. Everything written here is the issuance half
    ///  of {Validation}; the lifecycle half stays at its zero value until a settlement or a discard moves it.
    function _recordValidation(
        uint256 validationId,
        MessageTypesLib.ComplianceValidation memory issued,
        bytes calldata from,
        bytes calldata to,
        Draft memory draft
    ) private {
        Validation storage stored = _validationStorage().validations[validationId];
        stored.hash = MessageTypesLib.hashValidation(issued);
        stored.amountMin = draft.amountMin;
        stored.amountMax = draft.amountMax;
        stored.expiry = draft.expiry;
        stored.releaseAt = draft.expiry + draft.reconciliationWindow;
        stored.fromChainKey = draft.fromChainKey;
        stored.toChainKey = draft.toChainKey;
        stored.fromKey = draft.fromKey;
        stored.fromWallet = from;
        stored.toKey = WalletKeyLib.canonicalKey(to);
        stored.twoLegs = draft.twoLegs;
        stored.fromIdentity = draft.fromIdentity;
        stored.toIdentity = draft.toIdentity;
        // `_reservePending` returns whether it reserved against the identities; it does not on a relocation.
        stored.relocation = !_reservePending(draft.fromIdentity, draft.toIdentity, draft.fromKey, draft.amountMax);
        _reserveOnToken(from, draft.amountMax);
    }

    /* ----- Settlement ----- */

    /// @dev Classifies an attributed settlement against the stored validation. Reverts on a leg that does not
    ///  match; returns `true` on the two emergencies (a replayed leg, a never-issued id), which write nothing and
    ///  halt the token; reconciles a `Discarded` validation late, with the warning and the per-chain pause on a
    ///  breach. See {ISettlementHandler}.
    function _handleSettlement(bytes32 originChainKey, MessageTypesLib.SettlementNotification calldata notification)
        internal
        returns (bool halt)
    {
        ValidationStorage storage store = _validationStorage();
        if (!_isIssued(store, notification.validationId)) {
            emit EventsLib.ReplayedSettlement(notification.validationId, originChainKey);
            return true;
        }
        Validation storage validation = store.validations[notification.validationId];

        // 1. Which leg this is, and that its amount is inside the issued range.
        Leg leg = _matchLeg(validation, originChainKey, notification);
        require(
            validation.amountMin <= notification.amount && notification.amount <= validation.amountMax,
            ErrorsLib.SettlementOutOfBounds(notification.validationId, notification.amount)
        );
        if (_alreadyAccountedFor(validation.status, leg)) {
            emit EventsLib.ReplayedSettlement(notification.validationId, originChainKey);
            return true;
        }

        // 2. Take in what this chain reported: complete the movement, or wait for the other chain.
        bool late = _wasDiscarded(validation.status);
        bool breachesRule = _applyChainReport(validation, leg, notification, originChainKey, late);

        // 3. A late leg always warns; the chain pauses only when the recorded state breaches a rule, since late
        //    delivery is cheap to force and pausing on it would be a denial of service.
        if (late) {
            emit EventsLib.LateReconciliation(notification.validationId, originChainKey);
            if (breachesRule) _setIssuancePaused(originChainKey, true);
        }
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
        Validation storage validation,
        Leg leg,
        MessageTypesLib.SettlementNotification calldata notification,
        bytes32 originChainKey,
        bool late
    ) private returns (bool breachesRule) {
        bool isBurnLeg = leg == Leg.Burn;
        bool isSingleLeg = leg == Leg.Single;
        (ValidationStatus next, bool completesMovement) = _stateAfterLeg(validation.status, isBurnLeg, isSingleLeg);

        if (!completesMovement) {
            _recordFirstLeg(
                validation,
                isBurnLeg ? notification.from : notification.to,
                isBurnLeg,
                notification,
                originChainKey,
                next
            );
            return false;
        }

        // The movement completes here. On a pair, the wallet the first leg carried is the far side of it.
        bytes memory from = notification.from;
        bytes memory to = notification.to;
        if (!isSingleLeg) {
            if (isBurnLeg) to = validation.legWallet;
            else from = validation.legWallet;
        }
        return _settleValidation(validation, from, to, notification, originChainKey, late, next, !isSingleLeg);
    }

    /// @dev A leg is matched by the wallets it carries and the chain it comes from. A one-leg validation expects
    ///  both wallets, the issued ones, from `from`'s chain. A two-leg validation expects the burn leg, `to` empty,
    ///  from `from`'s chain, and the mint leg, `from` empty, from `to`'s chain; a leg carrying both wallets is
    ///  neither.
    function _matchLeg(
        Validation storage validation,
        bytes32 originChainKey,
        MessageTypesLib.SettlementNotification calldata notification
    ) private view returns (Leg) {
        bool fromMatches = notification.from.length != 0 && keccak256(notification.from) == validation.fromKey;
        bool toMatches = notification.to.length != 0 && keccak256(notification.to) == validation.toKey;
        if (!validation.twoLegs) {
            bool originMatches = originChainKey == validation.fromChainKey;
            require(
                fromMatches && toMatches && originMatches, ErrorsLib.SettlementLegMismatch(notification.validationId)
            );
            return Leg.Single;
        }
        if (fromMatches && notification.to.length == 0 && originChainKey == validation.fromChainKey) return Leg.Burn;
        if (toMatches && notification.from.length == 0 && originChainKey == validation.toChainKey) return Leg.Mint;
        revert ErrorsLib.SettlementLegMismatch(notification.validationId);
    }

    /// @dev The first of the two chains to report, whichever it is: the amount and the wallet it carries are
    ///  kept for the other one, and the validation is pinned. A first burn leg is proof the sender's satellite position is gone, so
    ///  the amount leaves that position and waits in transit on the ledger, and the wallet's pending amount stops
    ///  counting it; a first mint leg moves nothing until the burn leg lands, and the pair is then applied
    ///  atomically. A late first leg stays `Discarded`, its flag set, and holds all the same: the burn is final
    ///  either way.
    function _recordFirstLeg(
        Validation storage validation,
        bytes calldata wallet,
        bool burn,
        MessageTypesLib.SettlementNotification calldata notification,
        bytes32 originChainKey,
        ValidationStatus next
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

        _moveTo(validation, next, releasedByTheHold > 0);

        if (burn) _holdOnToken(wallet, notification.amount, notification.validationId, releasedByTheHold);

        emit EventsLib.ValidationLegConfirmed(notification.validationId, originChainKey, notification.amount);
    }

    /// @dev The movement a settled validation turns out to be, as the modules are asked about it. Its own
    ///  function because the settlement path holds enough live values without it, and the legacy pipeline runs
    ///  out of stack there under `forge coverage`.
    ///
    ///  A native recipient may have changed owner since issuance, so it is resolved again here. The token has
    ///  not been credited yet at this point, which is why nothing is adjusted for this very movement.
    function _settledMovement(Validation storage validation, bytes memory from, bytes memory to, uint256 amount)
        private
        returns (IModule.TransferContext memory)
    {
        address toIdentity = validation.toIdentity;
        (bool toNative, address toWallet) = WalletKeyLib.isReferenceChain(to);
        if (toNative) toIdentity = _currentOwner(toWallet, toIdentity, 0);

        return TransferContextLib.settlement(
            address(this),
            validation.fromIdentity,
            toIdentity,
            WalletKeyLib.walletId(from),
            WalletKeyLib.walletId(to),
            amount
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
        Validation storage validation,
        bytes memory from,
        bytes memory to,
        MessageTypesLib.SettlementNotification calldata notification,
        bytes32 originChainKey,
        bool late,
        ValidationStatus next,
        bool secondLeg
    ) private returns (bool breachesRule) {
        if (secondLeg) _requireRepeatsFirstLeg(validation, notification);

        validation.executedAmount = notification.amount;
        _moveTo(validation, next, false);

        IModule.TransferContext memory ctx = _settledMovement(validation, from, to, notification.amount);
        breachesRule = late && _exceedsWhatRulesAllowNow(ctx, notification.amount);

        _movePosition(ctx.fromIdentity, ctx.toIdentity, ctx.fromWallet, ctx.toWallet, notification.amount);
        _settleOnToken(from, to, notification.amount, notification.validationId);

        emit EventsLib.ValidationSettled(notification.validationId, originChainKey, notification.amount);
        _callAfterTransfer(ctx);
    }

    /// @dev Both chains must report the same amount: the first one to arrive recorded it, the second has to
    ///  repeat it. A mismatch means the two chains executed different movements under one id, which no ledger
    ///  can reconcile, so it is refused.
    function _requireRepeatsFirstLeg(
        Validation storage validation,
        MessageTypesLib.SettlementNotification calldata notification
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
        if (_isRelocation(ctx.fromIdentity, ctx.toIdentity)) return false;
        return amount > _minAllowedAmount(ctx);
    }

    /* ----- Discard ----- */

    /// @dev The keeper's batch. Each id must be stored `Pending` and past `releaseAt`; a one still awaiting a leg is
    ///  refused whatever the clock says. One refused id reverts the whole batch.
    /// @dev The way out of a pair of which one leg never arrived. The gate is a second reconciliation window
    ///  past `releaseAt`, the same length as the first, so a leg that is merely slow still lands as a late
    ///  reconciliation and never as a resolution.
    ///
    ///  When the burn leg is the one that landed, the tokens it burned are waiting in transit: they go back to
    ///  the wallet they left. When it was the mint leg, nothing on this chain can be returned, so the chain
    ///  that owes the burn stops being issued to instead and an operator investigates. Either way the
    ///  validation ends in `Resolved`, where any leg arriving afterwards halts the token.
    function _resolveStuckValidation(uint256 validationId) internal {
        ValidationStorage storage store = _validationStorage();
        require(_isIssued(store, validationId), ErrorsLib.UnknownValidation(validationId));
        Validation storage validation = store.validations[validationId];
        require(
            _awaitingOtherLeg(validation.status), ErrorsLib.ValidationNotStuck(validationId, uint8(validation.status))
        );

        uint64 resolvableAt = validation.releaseAt + (validation.releaseAt - validation.expiry);
        require(block.timestamp > resolvableAt, ErrorsLib.ValidationNotYetResolvable(validationId, resolvableAt));

        uint256 returnedAmount = 0;
        if (_burnArrived(validation.status)) {
            returnedAmount = validation.executedAmount;
            _returnHeldOnToken(validation.legWallet, validationId);
        } else {
            _setIssuancePaused(validation.fromChainKey, true);
        }

        _moveTo(validation, ValidationStatus.Resolved, false);

        emit EventsLib.ValidationResolved(validationId, returnedAmount);
    }

    function _discardExpiredValidations(uint256[] calldata validationIds) internal {
        ValidationStorage storage store = _validationStorage();
        for (uint256 i = 0; i < validationIds.length; i++) {
            uint256 validationId = validationIds[i];
            require(_isIssued(store, validationId), ErrorsLib.UnknownValidation(validationId));
            Validation storage validation = store.validations[validationId];
            require(
                validation.status == ValidationStatus.Pending,
                ErrorsLib.ValidationNotDiscardable(validationId, uint8(validation.status))
            );
            require(
                block.timestamp > validation.releaseAt,
                ErrorsLib.ValidationNotReleasable(validationId, validation.releaseAt)
            );

            _moveTo(validation, ValidationStatus.Discarded, false);

            emit EventsLib.ValidationDiscarded(validationId);
        }
    }

    /* ----- Views ----- */

    /// @inheritdoc ITransferValidation
    function defaultValidityWindow() public view returns (uint64) {
        return _validationStorage().defaultValidityWindow;
    }

    /// @inheritdoc ITransferValidation
    function reconciliationWindowOf(bytes32 chainKey) public view returns (uint64) {
        return _validationStorage().reconciliationWindows[chainKey];
    }

    /// @inheritdoc ITransferValidation
    function isIssuancePaused(bytes32 chainKey) public view returns (bool) {
        return _validationStorage().issuancePaused[chainKey];
    }

    /// @inheritdoc ITransferValidation
    function lastValidationId() public view returns (uint256) {
        return _validationStorage().lastValidationId;
    }

    /// @inheritdoc ITransferValidation
    function validationOf(uint256 validationId) public view returns (Validation memory) {
        return _validationStorage().validations[validationId];
    }

    /// @inheritdoc ITransferValidation
    function statusOf(uint256 validationId) public view returns (ValidationStatus) {
        ValidationStorage storage store = _validationStorage();
        require(_isIssued(store, validationId), ErrorsLib.UnknownValidation(validationId));
        Validation storage validation = store.validations[validationId];
        // `Expired` is the one status never stored: it is `Pending` once the clock has passed `releaseAt`. Every
        // other state is returned as it stands, including which leg a pair is still waiting for.
        if (validation.status == ValidationStatus.Pending && block.timestamp > validation.releaseAt) {
            return ValidationStatus.Expired;
        }
        return validation.status;
    }

    /* ----- Settings ----- */

    function _setDefaultValidityWindow(uint64 duration) internal {
        require(duration != 0, ErrorsLib.ZeroDuration());
        _validationStorage().defaultValidityWindow = duration;
        emit EventsLib.DefaultValidityWindowSet(duration);
    }

    function _setReconciliationWindow(bytes32 chainKey, uint64 duration) internal {
        require(duration != 0, ErrorsLib.ZeroDuration());
        _validationStorage().reconciliationWindows[chainKey] = duration;
        emit EventsLib.ReconciliationWindowSet(chainKey, duration);
    }

    /// @dev Idempotent: the same state again changes nothing and emits nothing.
    function _setIssuancePaused(bytes32 chainKey, bool paused) internal {
        ValidationStorage storage store = _validationStorage();
        if (store.issuancePaused[chainKey] == paused) return;
        store.issuancePaused[chainKey] = paused;
        if (paused) emit EventsLib.ValidationIssuancePaused(chainKey);
        else emit EventsLib.ValidationIssuanceUnpaused(chainKey);
    }

    /* ----- What the compliance provides ----- */

    /// @dev The token this compliance is bound to.
    function _boundToken() internal view virtual returns (IToken);

    /// @dev The registry of the bound token.
    function _boundRegistry() internal view virtual returns (ITREXRegistry);

    /// @dev Whether the AccessManager lets `caller` call `selector` on this contract now.
    function _canCallSelector(address caller, bytes4 selector) internal view virtual returns (bool);

    /// @dev The smallest amount any `RULE` module allows for `ctx`, `type(uint256).max` when none is bound.
    ///  Evaluated under `staticcall`: the ledger still describes the state before the move.
    function _minAllowedAmount(IModule.TransferContext memory ctx) internal view virtual returns (uint256);

    /// @dev Whether every `SPENDER` module accepts `ctx.spender`, `true` when none is bound. A view: the
    ///  modules are called under `staticcall`.
    function _spenderAllowed(IModule.TransferContext memory ctx) internal view virtual returns (bool);

    /// @dev Calls `afterTransfer` on every `TRACKER` module, once the positions have been updated.
    function _callAfterTransfer(IModule.TransferContext memory ctx) internal virtual;

    /// @dev Sends one leg of a validation toward `chainKey`, through the token.
    function _dispatchLeg(bytes32 chainKey, uint256 validationId, bytes memory body) internal virtual;

    /// @dev Applies a settled validation to the ledger, through the token, once.
    function _settleOnToken(bytes memory from, bytes memory to, uint256 amount, uint256 validationId) internal virtual;

    /// @dev Takes the burned amount out of `from`'s position and holds it in transit, through the token, when
    ///  the burn leg of a two-leg validation lands before the mint leg. `reserved` is what this validation had
    ///  reserved against the wallet, which the token gives back as it takes the hold.
    function _holdOnToken(bytes memory from, uint256 amount, uint256 validationId, uint256 reserved) internal virtual;

    /// @dev Reserves part of a satellite wallet's bridged balance for a validation being issued, on the token.
    function _reserveOnToken(bytes memory wallet, uint256 amount) internal virtual;

    /// @dev Gives back what this validation reserved against a satellite wallet, on the token.
    function _releaseOnToken(bytes memory wallet, uint256 amount) internal virtual;

    /// @dev Puts the amount held for `validationId` back on the wallet it was burned from, on the token.
    function _returnHeldOnToken(bytes memory to, uint256 validationId) internal virtual;

    /* ----- Shared by the three flows ----- */

    /* ----- The lifecycle, in one place ----- */

    /// @dev Whether the burn leg has arrived in this state.
    function _burnArrived(ValidationStatus status) internal pure returns (bool) {
        return status == ValidationStatus.AwaitingMint || status == ValidationStatus.DiscardedAwaitingMint
            || status == ValidationStatus.Settled || status == ValidationStatus.LateReconciled;
    }

    /// @dev Whether the mint leg has arrived in this state.
    function _mintArrived(ValidationStatus status) internal pure returns (bool) {
        return status == ValidationStatus.AwaitingBurn || status == ValidationStatus.DiscardedAwaitingBurn
            || status == ValidationStatus.Settled || status == ValidationStatus.LateReconciled;
    }

    /// @dev Whether this leg has nothing left to do: either its own half already arrived, or the keeper gave up
    ///  on the pair and sent the tokens back. Both mean the amount it carries is already accounted for
    ///  somewhere else, so applying it again would move tokens twice. The caller treats it as an emergency.
    function _alreadyAccountedFor(ValidationStatus status, Leg leg) internal pure returns (bool) {
        if (status == ValidationStatus.Resolved) return true;
        if (leg == Leg.Mint) return _mintArrived(status);
        return _burnArrived(status);
    }

    /// @dev Whether the keeper has given up on this validation, in any of the states that say so.
    function _wasDiscarded(ValidationStatus status) internal pure returns (bool) {
        return status == ValidationStatus.Discarded || status == ValidationStatus.DiscardedAwaitingMint
            || status == ValidationStatus.DiscardedAwaitingBurn;
    }

    /// @dev Whether exactly one leg of a pair has arrived and the other is still owed. Such a validation can be
    ///  neither discarded nor derived `Expired`: one satellite has already executed irreversibly.
    function _awaitingOtherLeg(ValidationStatus status) internal pure returns (bool) {
        return status == ValidationStatus.AwaitingMint || status == ValidationStatus.AwaitingBurn
            || status == ValidationStatus.DiscardedAwaitingMint || status == ValidationStatus.DiscardedAwaitingBurn;
    }

    /// @dev Whether the identities' pending amounts are still reserved in this state. A relocation never
    ///  reserved them, which is the one thing the status cannot answer by itself.
    function _stillReservesIdentities(ValidationStatus status, bool relocation) internal pure returns (bool) {
        if (relocation) return false;
        return status == ValidationStatus.Pending || status == ValidationStatus.AwaitingMint
            || status == ValidationStatus.AwaitingBurn;
    }

    /// @dev Whether the sender wallet's pending amount is still reserved in this state. Once the burn leg has
    ///  arrived the tokens are in transit, so the wallet's cap must stop counting them.
    function _stillReservesWallet(ValidationStatus status) internal pure returns (bool) {
        return status == ValidationStatus.Pending || status == ValidationStatus.AwaitingBurn;
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
    function _stateAfterLeg(ValidationStatus status, bool burnLeg, bool singleLeg)
        internal
        pure
        returns (ValidationStatus next, bool completesMovement)
    {
        bool discarded = _wasDiscarded(status);

        if (singleLeg) {
            return (discarded ? ValidationStatus.LateReconciled : ValidationStatus.Settled, true);
        }
        if (status == ValidationStatus.Pending) {
            return (burnLeg ? ValidationStatus.AwaitingMint : ValidationStatus.AwaitingBurn, false);
        }
        if (status == ValidationStatus.Discarded) {
            return (burnLeg ? ValidationStatus.DiscardedAwaitingMint : ValidationStatus.DiscardedAwaitingBurn, false);
        }
        // One leg was already in and the other has now landed: the pair is complete.
        return (discarded ? ValidationStatus.LateReconciled : ValidationStatus.Settled, true);
    }

    /// @dev Moves a validation to `next` and gives back whatever `next` no longer reserves. Because the
    ///  reservations are read off the status, a release happens exactly when the move stops reserving something,
    ///  and arriving twice at the same state gives nothing back twice.
    /// @param heldByTheHold true when the caller is about to take an in-transit hold, which gives the wallet's
    ///  reservation back itself; this function then leaves that half alone rather than releasing it twice.
    function _moveTo(Validation storage validation, ValidationStatus next, bool heldByTheHold) private {
        ValidationStatus current = validation.status;
        bool relocation = validation.relocation;

        if (_stillReservesIdentities(current, relocation) && !_stillReservesIdentities(next, relocation)) {
            _releasePendingOfIdentities(validation.fromIdentity, validation.toIdentity, validation.amountMax);
        }
        if (_stillReservesWallet(current) && !_stillReservesWallet(next) && !heldByTheHold) {
            _releaseOnToken(validation.fromWallet, validation.amountMax);
        }

        validation.status = next;
    }

    /// @dev Who a native wallet's tokens belong to now, with its balance moved over when the registry changed its
    ///  mind. `adjustment` is what this very movement already did to the wallet's balance on the token, so that
    ///  what moves is what the wallet held before it: `+amount` for a sender the token already debited,
    ///  `-amount` for a recipient it already credited, zero when the token has not moved yet.
    function _currentOwner(address wallet, address resolved, int256 adjustment) internal returns (address owner) {
        address previous;
        (owner, previous) = _followOwner(wallet, resolved);
        if (previous == address(0)) return owner;
        uint256 balance = uint256(int256(_boundToken().balanceOf(wallet)) + adjustment);
        _moveWalletBalance(wallet, previous, owner, balance);
    }

    /// @dev The reconciliation window of a chain that is open and configured.
    function _openChainWindow(ValidationStorage storage store, bytes32 chainKey) private view returns (uint64 window) {
        require(!store.issuancePaused[chainKey], ErrorsLib.ValidationIssuancePaused(chainKey));
        window = store.reconciliationWindows[chainKey];
        require(window != 0, ErrorsLib.ReconciliationWindowNotSet(chainKey));
    }

    function _chainKeyOf(bytes calldata wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

    /// @dev Ids start at 1 and `lastValidationId` is the last one issued.
    function _isIssued(ValidationStorage storage store, uint256 validationId) private view returns (bool) {
        return validationId != 0 && validationId <= store.lastValidationId;
    }

    function _validationStorage() internal pure returns (ValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VALIDATION_STORAGE_LOCATION
        }
    }

}

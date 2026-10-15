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

import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import { WalletKeyLib } from "../../../libraries/WalletKeyLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../../../utils/AccessManagedOwnableUpgradeable.sol";
import { ITransferValidation } from "../ITransferValidation.sol";
import { MovementKindLib } from "../MovementKindLib.sol";
import { AbstractModuleUpgradeable } from "./AbstractModuleUpgradeable.sol";
import { IApprovalModule } from "./IApprovalModule.sol";
import { IModule } from "./IModule.sol";

/// @dev Told by {AsyncApprovalModule} that a request waits for this approver's answer. Optional: an approver
///  without code, or one that does not implement it, is simply not told and reads the module's events.
interface IAsyncApprover {

    /// @dev `validationId`, requested on `compliance`, now waits for the caller's approver. An FHE rule starts
    ///  its computation here and answers from its decryption callback.
    function approvalAsked(address compliance, uint256 validationId) external;

}

/// @dev Decides, for a token, whether a requested cross-chain movement is issued, through answers that may come
///  later: an institution's backend, a rule computed with FHE that answers from its decryption callback, any
///  address. The compliance keeps the request `AwaitingApproval`, reserved, while the approvers answer.
///
///  The compliance owner lists the approvers with {setApprovers}. They answer in that order, each on the request
///  id, never on terms of their own: approve, possibly with a lower maximum, or refuse. Nobody can change the
///  recipient or the spender, or widen the range. When the last approver approves, the module answers the
///  compliance, which issues the validation at the lowest maximum approved; the first refusal refuses it. A
///  request nobody finished answering is refused by anyone past its deadline, on the compliance.
///
///  A native transfer cannot wait: the investor executes it in one call. An approver stores an approval of that
///  exact transfer instead, with an expiry, under an id of its own so a decision delivered twice approves one
///  transfer; {checkTransfer} answers from it and {afterTransfer} uses it up.
///
///  Not judged: mints, the issuer's own action; relocations between one identity's wallets, which change no
///  position; and every agent movement, which never reaches a `TRANSFER_CHECK` module.
contract AsyncApprovalModule is AbstractModuleUpgradeable, AccessManagedOwnableUpgradeable, IApprovalModule {

    /// @dev Where a request awaiting approval stands in this module.
    struct Request {
        /// How many approvers approved so far: the next one to answer is `approvers[approved]`.
        uint64 approved;
        /// The requested minimum: an approver's maximum below it refuses.
        uint256 amountMin;
        /// The lowest maximum approved so far, the requested maximum to start with.
        uint256 amountMax;
    }

    /// @dev How many identical native transfers are approved, and until when.
    struct Approval {
        uint64 count;
        /// Unix seconds; the approval is usable strictly before it.
        uint64 expiry;
    }

    /// @custom:storage-location erc7201:erc3643.storage.AsyncApprovalModule
    struct AsyncApprovalStorage {
        /// The approvers per compliance, in the order they answer, scoped by the bind nonce.
        mapping(address compliance => mapping(uint256 nonce => address[])) approvers;
        /// The requests awaiting approval per compliance, by validation id. Deleted once answered.
        mapping(address compliance => mapping(uint256 validationId => Request)) requests;
        /// Native-transfer approvals per compliance, scoped by the bind nonce, keyed by
        /// `keccak256(abi.encode(fromWallet, toWallet, amount))` with the wallet keys the compliance builds.
        mapping(address compliance => mapping(uint256 nonce => mapping(bytes32 transferKey => Approval))) approvals;
        /// Every native approval id an approver used, per compliance. Not scoped by the bind nonce, so a
        /// decision retried after a rebind is still refused.
        mapping(address compliance => mapping(bytes32 approvalId => bool)) usedApprovalIds;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.AsyncApprovalModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ASYNC_APPROVAL_STORAGE_LOCATION =
        0x8e132769c339aa4b7063edecd97a34a6fcabe204f7e6adaf81c9a125d1e53f00;

    event ApproversSet(address indexed compliance, address[] approvers);
    event ApprovalRequested(address indexed compliance, uint256 indexed validationId, address indexed approver);
    event ValidationApproved(
        address indexed compliance, uint256 indexed validationId, address indexed approver, uint256 amountMax
    );
    event ValidationRefused(address indexed compliance, uint256 indexed validationId, address indexed approver);
    event TransferApproved(
        address indexed compliance,
        address indexed from,
        address indexed to,
        bytes32 approvalId,
        uint256 amount,
        uint64 expiry,
        uint64 count
    );
    event ApprovalRevoked(
        address indexed compliance, address indexed from, address indexed to, uint256 amount, uint64 count
    );
    event ApprovalUsed(
        address indexed compliance, bytes32 indexed fromWallet, bytes32 indexed toWallet, uint256 amount, uint64 count
    );

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the module behind its proxy.
    /// @param accessManagerAddress authority gating the implementation upgrade
    function initialize(address accessManagerAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());

        __AbstractModule_init();
        __AccessManaged_init(accessManagerAddress);
    }

    /* ----- The compliance owner ----- */

    /// @dev Sets who answers the calling compliance's requests, in the order they answer. Requests already
    ///  waiting continue with the new list from where they stand. Emits `ApproversSet`.
    /// @param approvers backend keys, approver contracts, any address; at least one, none zero
    function setApprovers(address[] calldata approvers) external onlyComplianceCall {
        require(approvers.length != 0, ErrorsLib.ApproversNotSet());
        for (uint256 i = 0; i < approvers.length; i++) {
            require(approvers[i] != address(0), ErrorsLib.ZeroAddress());
        }
        _getAsyncApprovalStorage().approvers[msg.sender][getNonce(msg.sender)] = approvers;
        emit ApproversSet(msg.sender, approvers);
    }

    /// @dev The approvers of `compliance`, in the order they answer.
    function approversOf(address compliance) public view returns (address[] memory) {
        return _getAsyncApprovalStorage().approvers[compliance][getNonce(compliance)];
    }

    /* ----- The compliance ----- */

    /// @inheritdoc IApprovalModule
    /// @dev Keeps the request and tells the first approver. Reverts with no approver set, which refuses the
    ///  request: a request nobody could approve would only hold its reservation until the deadline.
    function approvalRequested(uint256 validationId, IModule.TransferContext calldata ctx, uint64)
        external
        onlyComplianceCall
    {
        address[] storage approvers = _getAsyncApprovalStorage().approvers[msg.sender][getNonce(msg.sender)];
        require(approvers.length != 0, ErrorsLib.ApproversNotSet());
        _getAsyncApprovalStorage().requests[msg.sender][validationId] =
            Request({ approved: 0, amountMin: ctx.amountMin, amountMax: ctx.amountMax });
        _ask(msg.sender, validationId, approvers[0]);
    }

    /* ----- The approvers ----- */

    /// @dev Approves a request awaiting approval, at most at `amountMax`. Only the approver whose turn it is
    ///  may answer. A maximum below the requested minimum refuses. The last approval answers the compliance,
    ///  which issues the validation at the lowest maximum approved. Emits `ValidationApproved`.
    function approveValidation(address compliance, uint256 validationId, uint256 amountMax)
        external
        onlyBoundCompliance(compliance)
    {
        (Request storage request, address[] storage approvers) = _requestForCaller(compliance, validationId);
        if (amountMax < request.amountMax) request.amountMax = amountMax;
        if (request.amountMax == 0 || request.amountMax < request.amountMin) {
            _refuse(compliance, validationId);
            return;
        }
        request.approved++;
        emit ValidationApproved(compliance, validationId, _msgSender(), request.amountMax);

        if (request.approved < approvers.length) {
            _ask(compliance, validationId, approvers[request.approved]);
            return;
        }
        uint256 approvedMax = request.amountMax;
        delete _getAsyncApprovalStorage().requests[compliance][validationId];
        ITransferValidation(compliance).answerApproval(validationId, approvedMax);
    }

    /// @dev Refuses a request awaiting approval. Only the approver whose turn it is may answer. Emits
    ///  `ValidationRefused`.
    function refuseValidation(address compliance, uint256 validationId) external onlyBoundCompliance(compliance) {
        _requestForCaller(compliance, validationId);
        _refuse(compliance, validationId);
    }

    /// @dev Approves one native transfer of exactly `amount` from `from` to `to`, usable until `expiry`, by
    ///  any approver of `compliance`. Approving the same transfer again, under another `approvalId`, adds one
    ///  to its count, and the newest expiry applies to all of them. Emits `TransferApproved`.
    /// @param approvalId the approver's own id for this decision, refused if it was used before, so a decision
    ///  delivered twice approves one transfer, not two
    function approveTransfer(
        address compliance,
        bytes32 approvalId,
        address from,
        address to,
        uint256 amount,
        uint64 expiry
    ) external onlyBoundCompliance(compliance) {
        _requireApprover(compliance);
        require(amount != 0, ErrorsLib.ZeroValue());
        require(expiry > block.timestamp, ErrorsLib.ExpiryInPast(expiry));
        mapping(bytes32 => bool) storage usedIds = _getAsyncApprovalStorage().usedApprovalIds[compliance];
        require(!usedIds[approvalId], ErrorsLib.ApprovalIdAlreadyUsed(approvalId));
        usedIds[approvalId] = true;

        Approval storage approval =
            _approval(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to), amount);
        approval.count++;
        approval.expiry = expiry;

        emit TransferApproved(compliance, from, to, approvalId, amount, expiry, approval.count);
    }

    /// @dev Withdraws one approval of a native transfer, expired or not, by any approver of `compliance`.
    ///  Emits `ApprovalRevoked`.
    function revokeApproval(address compliance, address from, address to, uint256 amount) external {
        _requireApprover(compliance);
        Approval storage approval =
            _approval(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to), amount);
        require(approval.count != 0, ErrorsLib.TransferNotApproved(from, to, amount));
        approval.count--;

        emit ApprovalRevoked(compliance, from, to, amount, approval.count);
    }

    /// @dev Where a request awaiting approval stands in this module; all zeros once answered.
    function requestOf(address compliance, uint256 validationId) external view returns (Request memory) {
        return _getAsyncApprovalStorage().requests[compliance][validationId];
    }

    /// @dev The approvals stored for a native transfer of exactly `amount` from `from` to `to`.
    function approvalOf(address compliance, address from, address to, uint256 amount)
        external
        view
        returns (Approval memory)
    {
        return _approval(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to), amount);
    }

    /// @dev Whether an approver already used `approvalId` with `compliance`, so a service can tell a retry from
    ///  a new decision.
    function isApprovalIdUsed(address compliance, bytes32 approvalId) external view returns (bool) {
        return _getAsyncApprovalStorage().usedApprovalIds[compliance][approvalId];
    }

    /* ----- Native transfers ----- */

    /// @inheritdoc IModule
    /// @dev A native transfer between two identities passes on an unexpired approval for its exact amount. An
    ///  issuance is not judged here: it waits for the approvers instead.
    function checkTransfer(TransferContext calldata ctx) external view override returns (uint256) {
        if (!_needsStoredApproval(ctx)) return type(uint256).max;
        Approval storage approval = _approval(ctx.compliance, ctx.fromWallet, ctx.toWallet, ctx.amountMax);
        if (approval.count == 0 || approval.expiry <= block.timestamp) return 0;
        return type(uint256).max;
    }

    /// @inheritdoc IModule
    /// @dev Uses up one approval of the native transfer that just moved. Never reverts: on a transfer a revert
    ///  here is a veto, and {checkTransfer} already decided.
    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        if (!_needsStoredApproval(ctx)) return;
        Approval storage approval = _approval(msg.sender, ctx.fromWallet, ctx.toWallet, ctx.amountMax);
        if (approval.count == 0) return;
        approval.count--;

        emit ApprovalUsed(msg.sender, ctx.fromWallet, ctx.toWallet, ctx.amountMax, approval.count);
    }

    /// @inheritdoc IModule
    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](3);
        types[0] = ModuleType.TRANSFER_CHECK;
        types[1] = ModuleType.AFTER;
        types[2] = ModuleType.APPROVAL;
    }

    /// @inheritdoc IModule
    /// @dev Nothing to verify: the approvers are set with `addAndSetModule`.
    /// @return always true
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    /// @dev Binds anywhere, in any order. Bound without approvers, it refuses every cross-chain request and
    ///  every native transfer between two identities until they are set.
    /// @return always true
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    /// @return _name the name of the module
    function name() external pure returns (string memory _name) {
        return "AsyncApprovalModule";
    }

    /// @inheritdoc AccessManagedOwnableBase
    /// @param interfaceId the interface identifier, as specified in ERC-165
    /// @return true if the contract implements `interfaceId`
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AbstractModuleUpgradeable, AccessManagedOwnableBase)
        returns (bool)
    {
        return interfaceId == type(IApprovalModule).interfaceId
            || AbstractModuleUpgradeable.supportsInterface(interfaceId)
            || AccessManagedOwnableBase.supportsInterface(interfaceId);
    }

    /// @dev Gated through the shared authority.
    function _authorizeUpgrade(address) internal override restricted { }

    /// @dev The waiting request, and the approvers of `compliance`, once checked that the caller is the
    ///  approver whose turn it is.
    function _requestForCaller(address compliance, uint256 validationId)
        private
        view
        returns (Request storage request, address[] storage approvers)
    {
        AsyncApprovalStorage storage $ = _getAsyncApprovalStorage();
        request = $.requests[compliance][validationId];
        require(request.amountMax != 0, ErrorsLib.UnknownApprovalRequest(validationId));
        approvers = $.approvers[compliance][getNonce(compliance)];
        address expected = request.approved < approvers.length ? approvers[request.approved] : address(0);
        require(_msgSender() == expected, ErrorsLib.NotTheNextApprover(_msgSender(), expected));
    }

    /// @dev Forgets the request and refuses it on the compliance, which releases its reservation.
    function _refuse(address compliance, uint256 validationId) private {
        delete _getAsyncApprovalStorage().requests[compliance][validationId];
        emit ValidationRefused(compliance, validationId, _msgSender());
        ITransferValidation(compliance).answerApproval(validationId, 0);
    }

    /// @dev Announces whose turn it is, and tells that approver when it is a contract. Telling is best
    ///  effort: an approver that does not implement {IAsyncApprover} reads the event instead, and its failure
    ///  never refuses the request.
    function _ask(address compliance, uint256 validationId, address approver) private {
        emit ApprovalRequested(compliance, validationId, approver);
        if (approver.code.length == 0) return;
        try IAsyncApprover(approver).approvalAsked(compliance, validationId) { } catch { }
    }

    function _requireApprover(address compliance) private view {
        address[] storage approvers = _getAsyncApprovalStorage().approvers[compliance][getNonce(compliance)];
        address caller = _msgSender();
        for (uint256 i = 0; i < approvers.length; i++) {
            if (approvers[i] == caller) return;
        }
        revert ErrorsLib.NotAnApprover(caller);
    }

    /// @dev A native transfer between two identities: the one movement an approval is stored for.
    function _needsStoredApproval(TransferContext calldata ctx) private pure returns (bool) {
        return ctx.kind == MovementKindLib.TRANSFER && !ctx.isIssuance && ctx.fromIdentity != ctx.toIdentity;
    }

    function _approval(address compliance, bytes32 fromWallet, bytes32 toWallet, uint256 amount)
        private
        view
        returns (Approval storage)
    {
        bytes32 transferKey = keccak256(abi.encode(fromWallet, toWallet, amount));
        return _getAsyncApprovalStorage().approvals[compliance][getNonce(compliance)][transferKey];
    }

    function _getAsyncApprovalStorage() private pure returns (AsyncApprovalStorage storage $) {
        assembly ("memory-safe") {
            $.slot := _ASYNC_APPROVAL_STORAGE_LOCATION
        }
    }

}

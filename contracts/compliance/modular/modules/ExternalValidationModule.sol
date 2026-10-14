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

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { IERC3643 } from "../../../ERC-3643/IERC3643.sol";
import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import { WalletKeyLib } from "../../../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../../../registry/interface/ITREXRegistry.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../../../utils/AccessManagedOwnableUpgradeable.sol";
import { IModularCompliance } from "../IModularCompliance.sol";
import { ITransferValidation } from "../ITransferValidation.sol";
import { MovementKindLib } from "../MovementKindLib.sol";
import { AbstractModuleUpgradeable } from "./AbstractModuleUpgradeable.sol";
import { IModule } from "./IModule.sol";

/// @dev Lets a service outside the chain approve every transfer of a token: an institution's backend, an
///  oracle adapter, anything holding the validator role on this module. The module only learns "allowed or
///  not", never what was checked.
///
///  A satellite movement is approved by requesting it. The sender's identity calls {ask}, which only emits
///  an event; the service runs its check and calls {approveAndRequest}, in which this module marks the
///  movement, requests the validation from the compliance itself, and clears the mark before returning. The
///  approval never outlives that transaction, so it cannot be replayed and nothing is left to clean up. Any
///  other request, the sender's identity's or an agent's, finds no mark and is refused.
///
///  A native transfer cannot be requested on the investor's behalf, since the investor executes it. The
///  service stores an approval for that exact transfer instead, with a count and an expiry; {checkTransfer}
///  answers from it and {afterTransfer} uses one up.
///
///  The module requests validations, so it must hold the role the compliance's AccessManager binds to
///  `requestTransferValidation`, with no execution delay: {canComplianceBind} refuses the binding otherwise.
///
///  Not judged: mints, the issuer's own action; relocations between one identity's wallets, which change no
///  position; and every agent movement, which never reaches a `TRANSFER_CHECK` module.
contract ExternalValidationModule is AbstractModuleUpgradeable, AccessManagedOwnableUpgradeable {

    /// @dev How many identical native transfers are approved, and until when.
    struct Approval {
        uint64 count;
        /// Unix seconds; the approval is usable strictly before it.
        uint64 expiry;
    }

    /// @custom:storage-location erc7201:erc3643.storage.ExternalValidationModule
    struct ExternalValidationStorage {
        /// Native-transfer approvals per compliance, scoped by the bind nonce so an unbind discards them, keyed
        /// by `keccak256(abi.encode(fromWallet, toWallet, amount))` with the wallet keys the compliance builds.
        mapping(address compliance => mapping(uint256 nonce => mapping(bytes32 transferKey => Approval))) approvals;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.ExternalValidationModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _EXTERNAL_VALIDATION_STORAGE_LOCATION =
        0xa1120db406459129af0bc428bdf0309aeb35a1c3107edebc9481e947179c7700;

    /// @dev The satellite movement this module is requesting, set for the duration of {approveAndRequest}
    ///  only. Transient, so it can never persist past the transaction, and outside the namespace on purpose.
    bytes32 private transient _inFlight;

    event ValidationAsked(
        address indexed compliance,
        address indexed fromIdentity,
        bytes from,
        bytes to,
        bytes spender,
        uint256 amountMin,
        uint256 amountMax
    );
    event ValidationApproved(
        address indexed compliance,
        uint256 indexed validationId,
        bytes from,
        bytes to,
        uint256 amountMin,
        uint256 amountMax
    );
    event TransferApproved(
        address indexed compliance,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint64 expiry,
        uint64 count
    );
    event TransferApprovalRevoked(
        address indexed compliance, address indexed from, address indexed to, uint256 amount, uint64 count
    );
    event TransferApprovalConsumed(
        address indexed compliance, bytes32 indexed fromWallet, bytes32 indexed toWallet, uint256 amount, uint64 count
    );

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the module behind its proxy.
    /// @param accessManagerAddress authority gating the validator functions and the implementation upgrade
    function initialize(address accessManagerAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());

        __AbstractModule_init();
        __AccessManaged_init(accessManagerAddress);
    }

    /* ----- The investor ----- */

    /// @dev Asks the service to approve a movement out of `from`. Emits `ValidationAsked` and stores nothing,
    ///  so an ask nobody answers leaves nothing behind and asking twice is two events. Only the identity
    ///  `from` is linked to may ask: the event says whose movement it is, and the service trusts that. `to`
    ///  and `spender` are taken as given; the service checks them, and the compliance checks everything again
    ///  when the movement is requested or executed. For a native transfer, ask with both bounds at the amount.
    /// @param compliance the compliance of the token, which must have bound this module
    /// @param from ERC-7930 envelope of the sending wallet, native or satellite
    /// @param to ERC-7930 envelope of the receiving wallet
    /// @param requestedMin inclusive lower bound
    /// @param requestedMax inclusive upper bound
    /// @param spender ERC-7930 envelope of who executes on the sender's behalf, or empty
    function ask(
        address compliance,
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender
    ) external onlyBoundCompliance(compliance) {
        require(requestedMin <= requestedMax, ErrorsLib.InvalidRequestedRange(requestedMin, requestedMax));
        address fromIdentity = address(_identityRegistry(compliance).resolveIdentity(from));
        require(fromIdentity == msg.sender, ErrorsLib.NotAuthorizedForWallet(msg.sender, from));

        emit ValidationAsked(compliance, fromIdentity, from, to, spender, requestedMin, requestedMax);
    }

    /* ----- The service ----- */

    /// @dev Approves a satellite movement by requesting its validation, in one transaction: marks it, calls
    ///  `requestTransferValidation` on the compliance, clears the mark. The compliance asks every rule inside
    ///  that call, this one included; a rule that leaves the range empty reverts the whole transaction, so
    ///  nothing is approved that the other rules refuse. Emits `ValidationApproved`.
    /// @return validationId the validation the compliance issued
    function approveAndRequest(
        address compliance,
        bytes calldata from,
        bytes calldata to,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes calldata spender
    ) external restricted onlyBoundCompliance(compliance) returns (uint256 validationId) {
        require(_inFlight == bytes32(0), ErrorsLib.ApprovalInFlight());
        _inFlight = _inFlightKey(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to));
        validationId =
            ITransferValidation(compliance).requestTransferValidation(from, to, requestedMin, requestedMax, spender);
        _inFlight = bytes32(0);

        emit ValidationApproved(compliance, validationId, from, to, requestedMin, requestedMax);
    }

    /// @dev Approves one native transfer of exactly `amount` from `from` to `to`, usable until `expiry`.
    ///  Approving the same transfer again adds one to its count, and the newest expiry applies to all of them.
    ///  Emits `TransferApproved`.
    function approve(address compliance, address from, address to, uint256 amount, uint64 expiry)
        external
        restricted
        onlyBoundCompliance(compliance)
    {
        require(amount != 0, ErrorsLib.ZeroValue());
        require(expiry > block.timestamp, ErrorsLib.ApprovalExpired(expiry));
        Approval storage approval =
            _approval(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to), amount);
        approval.count++;
        approval.expiry = expiry;

        emit TransferApproved(compliance, from, to, amount, expiry, approval.count);
    }

    /// @dev Withdraws one approval of a native transfer, expired or not. Emits `TransferApprovalRevoked`.
    function revoke(address compliance, address from, address to, uint256 amount) external restricted {
        Approval storage approval =
            _approval(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to), amount);
        require(approval.count != 0, ErrorsLib.TransferNotApproved(from, to, amount));
        approval.count--;

        emit TransferApprovalRevoked(compliance, from, to, amount, approval.count);
    }

    /// @dev The approvals stored for a native transfer of exactly `amount` from `from` to `to`.
    function approvalOf(address compliance, address from, address to, uint256 amount)
        external
        view
        returns (Approval memory)
    {
        return _approval(compliance, WalletKeyLib.walletId(from), WalletKeyLib.walletId(to), amount);
    }

    /* ----- The compliance ----- */

    /// @inheritdoc IModule
    /// @dev An issuance passes only while this module is requesting that very movement; the requested range
    ///  is not part of the mark, since the compliance caps it at the wallet's free balance before asking. A
    ///  native transfer passes on an unexpired approval for its exact amount. Mints and relocations pass.
    function checkTransfer(TransferContext calldata ctx) external view override returns (uint256) {
        if (ctx.isIssuance) {
            if (_inFlight == _inFlightKey(ctx.compliance, ctx.fromWallet, ctx.toWallet)) return type(uint256).max;
            return 0;
        }
        if (!_judgesNativeTransfer(ctx)) return type(uint256).max;
        Approval storage approval = _approval(ctx.compliance, ctx.fromWallet, ctx.toWallet, ctx.amountMax);
        if (approval.count == 0 || approval.expiry <= block.timestamp) return 0;
        return type(uint256).max;
    }

    /// @inheritdoc IModule
    /// @dev Uses up one approval of the native transfer that just moved. Never reverts: on a transfer a revert
    ///  here is a veto, and {checkTransfer} already decided. A settlement has nothing to use up, since its
    ///  mark was cleared when the validation was issued.
    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        if (!_judgesNativeTransfer(ctx)) return;
        Approval storage approval = _approval(msg.sender, ctx.fromWallet, ctx.toWallet, ctx.amountMax);
        if (approval.count == 0) return;
        approval.count--;

        emit TransferApprovalConsumed(msg.sender, ctx.fromWallet, ctx.toWallet, ctx.amountMax, approval.count);
    }

    /// @inheritdoc IModule
    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](2);
        types[0] = ModuleType.TRANSFER_CHECK;
        types[1] = ModuleType.AFTER;
    }

    /// @inheritdoc IModule
    /// @dev Binds only where this module may request validations: it must hold, with no execution delay, the
    ///  role the compliance's AccessManager binds to `requestTransferValidation`, since it calls it directly
    ///  and cannot schedule. Grant it a role bound to that function alone rather than AGENT, which also mints,
    ///  forces transfers and edits the registry.
    /// @return true when the module holds that role
    function canComplianceBind(address _compliance) external view returns (bool) {
        IAccessManager manager = IAccessManager(IAccessManaged(_compliance).authority());
        uint64 roleId =
            manager.getTargetFunctionRole(_compliance, ITransferValidation.requestTransferValidation.selector);
        (bool isMember, uint32 executionDelay) = manager.hasRole(roleId, address(this));
        return isMember && executionDelay == 0;
    }

    /// @inheritdoc IModule
    /// @dev Not plug and play: the module needs the request role first, see {canComplianceBind}.
    /// @return always false
    function isPlugAndPlay() external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IModule
    /// @return _name the name of the module
    function name() external pure returns (string memory _name) {
        return "ExternalValidationModule";
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
        return AbstractModuleUpgradeable.supportsInterface(interfaceId)
            || AccessManagedOwnableBase.supportsInterface(interfaceId);
    }

    /// @dev Gated through the shared authority.
    function _authorizeUpgrade(address) internal override restricted { }

    /// @dev A native transfer between two identities: the one movement an approval is stored for.
    function _judgesNativeTransfer(TransferContext calldata ctx) private pure returns (bool) {
        return ctx.kind == MovementKindLib.TRANSFER && ctx.fromIdentity != ctx.toIdentity;
    }

    function _inFlightKey(address compliance, bytes32 fromWallet, bytes32 toWallet) private pure returns (bytes32) {
        return keccak256(abi.encode(compliance, fromWallet, toWallet));
    }

    function _approval(address compliance, bytes32 fromWallet, bytes32 toWallet, uint256 amount)
        private
        view
        returns (Approval storage)
    {
        bytes32 transferKey = keccak256(abi.encode(fromWallet, toWallet, amount));
        return _getExternalValidationStorage().approvals[compliance][getNonce(compliance)][transferKey];
    }

    /// @dev Resolves the registry of the token bound to a compliance.
    function _identityRegistry(address _compliance) private view returns (ITREXRegistry) {
        return ITREXRegistry(address(IERC3643(IModularCompliance(_compliance).getTokenBound()).identityRegistry()));
    }

    function _getExternalValidationStorage() private pure returns (ExternalValidationStorage storage $) {
        assembly ("memory-safe") {
            $.slot := _EXTERNAL_VALIDATION_STORAGE_LOCATION
        }
    }

}

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

import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../../../utils/AccessManagedOwnableUpgradeable.sol";
import { AbstractModuleUpgradeable } from "./AbstractModuleUpgradeable.sol";
import { IModule } from "./IModule.sol";

/// @dev Lets an institution decide every satellite transfer from data it keeps offchain. Bound, it refuses a
///  validation unless its requester holds the approver role, a role of the compliance's AccessManager: the
///  institution's backend. The sender's identity asks with `askTransferValidation`, the backend reads the event,
///  runs its private check and requests the amount it allows. The waiting happens in the backend, never on
///  chain, so nothing is reserved, expires or has to be cleaned up while the check runs.
///
///  The guarantee is the module's own: whatever else the AccessManager lets call `requestTransferValidation`,
///  AGENT included, only an approver's request passes. The requester asks, it does not execute: the validation
///  still has to be executed by the sending wallet, or by the spender it names, on the satellite.
///
///  Not judged: a relocation between one identity's wallets, which never reaches `checkTransfer` at issuance
///  and changes no position, and native movements, which have no requester and cannot wait. A rule over an
///  investor's total holdings therefore holds over satellite movements only.
contract AuthorizedRequesterModule is AbstractModuleUpgradeable, AccessManagedOwnableUpgradeable {

    /// @custom:storage-location erc7201:erc3643.storage.AuthorizedRequesterModule
    struct AuthorizedRequesterStorage {
        /// The approver role per compliance, scoped by the bind nonce so an unbind discards it. Zero means
        /// never set, which refuses every issuance: bind with `addAndSetModule`.
        mapping(address compliance => mapping(uint256 nonce => uint64)) approverRole;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.AuthorizedRequesterModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _AUTHORIZED_REQUESTER_STORAGE_LOCATION =
        0xd15d50848072e33707d17a2f5ed411d4764b7e781faec1fe520c380d3c475900;

    event ApproverRoleSet(address indexed compliance, uint64 indexed roleId);

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

    /// @dev Sets the approver role for the calling compliance, a role of its AccessManager. Zero is refused: it
    ///  is the AccessManager's admin role, and it is what an unset role reads as. Emits `ApproverRoleSet`.
    /// @param roleId the role whose members may request validations
    function setApproverRole(uint64 roleId) external onlyComplianceCall {
        require(roleId != 0, ErrorsLib.ZeroValue());
        _getAuthorizedRequesterStorage().approverRole[msg.sender][getNonce(msg.sender)] = roleId;
        emit ApproverRoleSet(msg.sender, roleId);
    }

    /// @dev The approver role configured for `_compliance`, zero when unset.
    function approverRoleOf(address _compliance) public view returns (uint64) {
        return _getAuthorizedRequesterStorage().approverRole[_compliance][getNonce(_compliance)];
    }

    /// @inheritdoc IModule
    /// @dev Allows an issuance whose requester holds the approver role in the compliance's AccessManager, and
    ///  refuses every other, the sender's identity included. Anything but an issuance is not judged.
    function checkTransfer(TransferContext calldata ctx) external view override returns (uint256) {
        if (!ctx.isIssuance) return type(uint256).max;
        uint64 roleId = approverRoleOf(ctx.compliance);
        if (roleId == 0) return 0;
        address requester = abi.decode(ctx.data, (address));
        IAccessManager manager = IAccessManager(IAccessManaged(ctx.compliance).authority());
        (bool isApprover,) = manager.hasRole(roleId, requester);
        if (!isApprover) return 0;
        return type(uint256).max;
    }

    /// @inheritdoc IModule
    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.TRANSFER_CHECK;
    }

    /// @inheritdoc IModule
    /// @dev Nothing to verify: the approver role is set with `addAndSetModule`.
    /// @return always true
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    /// @dev Binds anywhere, in any order. Bound without a role, it refuses every issuance until one is set.
    /// @return always true
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    /// @return _name the name of the module
    function name() external pure returns (string memory _name) {
        return "AuthorizedRequesterModule";
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

    function _getAuthorizedRequesterStorage() private pure returns (AuthorizedRequesterStorage storage $) {
        assembly ("memory-safe") {
            $.slot := _AUTHORIZED_REQUESTER_STORAGE_LOCATION
        }
    }

}

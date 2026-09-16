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

import { ERC3643IdentityRegistryStorage } from "../../ERC-3643/base/ERC3643IdentityRegistryStorage.sol";
import { IERC3643IdentityRegistryStorage } from "../../ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { AccessManagedOwnableUpgradeable } from "../../utils/AccessManagedOwnableUpgradeable.sol";
import { IIdentityRegistryStorage } from "../interface/IIdentityRegistryStorage.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

/// @title IdentityRegistryStorage
/// @notice T-REX identity registry storage: the standard ERC-3643 storage plus T-REX authorization and
///  the extra notification T-REX operators rely on.
/// @dev Layer 3 of the ERC-3643 / T-REX split (see issue #65). The standard surface and all standard
///  state live in {ERC3643IdentityRegistryStorage}; this contract adds only what T-REX needs on top:
///
///  - AccessManager-based authorization, supplied through the two `_authorize*` hooks;
///  - the `onlySharedAuthority` misconfiguration guard on registry binding;
///  - `EventsLib.InvestorIdentityChanged`, a T-REX-only notification emitted alongside the standard
///    `IdentityModified` event;
///  - ERC-165 support.
///
///  Nothing here writes the base namespace directly; every write goes through a base internal function.
contract IdentityRegistryStorage is
    IIdentityRegistryStorage,
    ERC3643IdentityRegistryStorage,
    AccessManagedOwnableUpgradeable
{

    constructor() {
        _disableInitializers();
    }

    function init(address accessManagerAddress, address initialIRAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());
        __AccessManaged_init(accessManagerAddress);

        if (initialIRAddress != address(0)) {
            _bindIdentityRegistry(initialIRAddress);
        }
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    /// @dev Adds `EventsLib.InvestorIdentityChanged` to the standard behavior: T-REX operators watch it
    ///  to reconcile off-chain investor records when an identity contract is replaced.
    function modifyStoredIdentity(address _userAddress, IIdentity _identity) external override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage) {
        _authorizeIdentityWrite();
        _modifyStoredIdentity(_userAddress, _identity);
        emit EventsLib.InvestorIdentityChanged(_userAddress);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    /// @dev `onlySharedAuthority` is a misconfiguration guard only: `authority()` is spoofable.
    function bindIdentityRegistry(address identityRegistry)
        external
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        restricted
        onlySharedAuthority(identityRegistry)
    {
        _bindIdentityRegistry(identityRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function unbindIdentityRegistry(address _identityRegistry)
        external
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        restricted
    {
        _unbindIdentityRegistry(_identityRegistry);
    }

    /// @inheritdoc IERC3643IdentityRegistryStorage
    function storedIdentity(address _userAddress)
        external
        view
        override(ERC3643IdentityRegistryStorage, IERC3643IdentityRegistryStorage)
        returns (IIdentity)
    {
        return _storedIdentity(_userAddress);
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC3643IdentityRegistryStorage).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev T-REX authorization for the identity-writing functions: the configured AccessManager role.
    function _authorizeIdentityWrite() internal override {
        _checkCanCall(_msgSender(), msg.data);
    }

    /// @dev Binding is authorized by the two dedicated external overrides above, which apply `restricted`
    ///  and `onlySharedAuthority` directly. This hook is therefore never the sole gate on the public path;
    ///  it exists so any future internal caller still passes through the role check.
    function _authorizeRegistryBinding(address) internal override {
        _checkCanCall(_msgSender(), msg.data);
    }

}

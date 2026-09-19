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

import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { SuiteTargetsLib } from "../libraries/SuiteTargetsLib.sol";
import { IERC173 } from "../vendor/IERC173.sol";

contract SuiteAuthorityMigrator {

    function migrateSuite(address token, IERC173[] calldata extraTargets, address newAuthority, bool rotateIdentity)
        external
    {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        _migrate(tokens, _addresses(extraTargets), newAuthority, rotateIdentity);
    }

    function migrateSuites(
        address[] calldata tokens,
        IERC173[] calldata extraTargets,
        address newAuthority,
        bool rotateIdentities
    ) external {
        require(tokens.length != 0, ErrorsLib.ZeroAddress());
        _migrate(tokens, _addresses(extraTargets), newAuthority, rotateIdentities);
    }

    function _migrate(
        address[] memory tokens,
        address[] memory extraTargets,
        address newAuthority,
        bool rotateIdentities
    ) private {
        require(tokens[0] != address(0) && newAuthority != address(0), ErrorsLib.ZeroAddress());
        IAccessManager oldAuthority = IAccessManager(IERC173(tokens[0]).owner());
        require(msg.sender == address(oldAuthority), ErrorsLib.OnlyAuthorityCanCall());
        require(address(oldAuthority) != newAuthority, ErrorsLib.SameAuthority());

        address[] memory targets = SuiteTargetsLib.targets(tokens, extraTargets);

        if (rotateIdentities) {
            for (uint256 i = 0; i < tokens.length; i++) {
                _addManagementKey(oldAuthority, IERC3643(tokens[i]).onchainID(), newAuthority);
            }
        }

        for (uint256 i = 0; i < targets.length; i++) {
            IERC173 target = IERC173(targets[i]);
            require(target.owner() == address(oldAuthority), ErrorsLib.AuthorityMismatch());
            oldAuthority.execute(targets[i], abi.encodeCall(IERC173.transferOwnership, (newAuthority)));
            require(target.owner() == newAuthority, ErrorsLib.AuthorityMismatch());
        }

        if (rotateIdentities) {
            for (uint256 i = 0; i < tokens.length; i++) {
                _removeManagementKey(oldAuthority, IERC3643(tokens[i]).onchainID());
            }
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            emit EventsLib.SuiteAuthorityMigrated(tokens[i], address(oldAuthority), newAuthority, rotateIdentities);
        }
    }

    function _addManagementKey(IAccessManager oldAuthority, address identity, address newAuthority) private {
        require(
            identity != address(0) && _isManager(identity, address(oldAuthority)),
            ErrorsLib.IdentityNotManagedByAuthority(identity, address(oldAuthority))
        );
        if (_isManager(identity, newAuthority)) {
            return;
        }
        bytes memory signerData = abi.encodePacked(newAuthority);
        oldAuthority.execute(
            identity,
            abi.encodeCall(
                KeyManager.addKeyWithData,
                (keccak256(signerData), KeyPurposes.MANAGEMENT, KeyTypes.ECDSA, signerData, bytes(""))
            )
        );
        require(_isManager(identity, newAuthority), ErrorsLib.IdentityRotationFailed(identity));
    }

    function _removeManagementKey(IAccessManager oldAuthority, address identity) private {
        oldAuthority.execute(
            identity, abi.encodeCall(IERC734.removeKey, (_keyHash(address(oldAuthority)), KeyPurposes.MANAGEMENT))
        );
        require(!_isManager(identity, address(oldAuthority)), ErrorsLib.IdentityRotationFailed(identity));
    }

    function _isManager(address identity, address account) private view returns (bool) {
        return IERC734(identity).keyHasPurpose(_keyHash(account), KeyPurposes.MANAGEMENT);
    }

    function _keyHash(address account) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    function _addresses(IERC173[] calldata targets) private pure returns (address[] memory addresses) {
        addresses = new address[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            addresses[i] = address(targets[i]);
        }
    }

}

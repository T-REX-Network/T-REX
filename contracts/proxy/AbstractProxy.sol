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

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { ITREXImplementationAuthority } from "./authority/ITREXImplementationAuthority.sol";
import { IProxy } from "./interface/IProxy.sol";

abstract contract AbstractProxy is IProxy, Initializable {

    constructor(address implementationAuthority) {
        require(implementationAuthority != address(0), ErrorsLib.ZeroAddress());
        _storeImplementationAuthority(implementationAuthority);
        emit EventsLib.ImplementationAuthoritySet(implementationAuthority);
    }

    /**
     *  @dev See {IProxy-setImplementationAuthority}.
     */
    function setImplementationAuthority(address _newImplementationAuthority) external {
        require(msg.sender == getImplementationAuthority(), ErrorsLib.OnlyCurrentImplementationAuthorityCanCall());
        require(_newImplementationAuthority != address(0), ErrorsLib.ZeroAddress());
        require(
            (ITREXImplementationAuthority(_newImplementationAuthority)).getTokenImplementation() != address(0)
                && (ITREXImplementationAuthority(_newImplementationAuthority)).getCTRImplementation() != address(0)
                && (ITREXImplementationAuthority(_newImplementationAuthority)).getIRImplementation() != address(0)
                && (ITREXImplementationAuthority(_newImplementationAuthority)).getIRSImplementation() != address(0)
                && (ITREXImplementationAuthority(_newImplementationAuthority)).getMCImplementation() != address(0)
                && (ITREXImplementationAuthority(_newImplementationAuthority)).getTIRImplementation() != address(0),
            ErrorsLib.InvalidImplementationAuthority()
        );
        _storeImplementationAuthority(_newImplementationAuthority);
        emit EventsLib.ImplementationAuthoritySet(_newImplementationAuthority);
    }

    /**
     *  @dev See {IProxy-getImplementationAuthority}.
     */
    function getImplementationAuthority() public view returns (address) {
        address implemAuth;
        assembly ("memory-safe") {
            implemAuth := sload(0x821f3e4d3d679f19eacc940c87acf846ea6eae24a63058ea750304437a62aafc)
        }
        return implemAuth;
    }

    /**
     *  @dev store the implementationAuthority contract address using the ERC-3643 implementation slot in storage
     *  the slot storage is the result of `keccak256("ERC-3643.proxy.beacon")`
     */
    function _storeImplementationAuthority(address implementationAuthority) internal {
        assembly ("memory-safe") {
            sstore(0x821f3e4d3d679f19eacc940c87acf846ea6eae24a63058ea750304437a62aafc, implementationAuthority)
        }
    }

    function getLogic() internal view virtual returns (address);

    fallback() external payable {
        address logic = getLogic();

        assembly {
            calldatacopy(0x0, 0x0, calldatasize())
            let success := delegatecall(gas(), logic, 0x0, calldatasize(), 0, 0)
            let retSz := returndatasize()
            returndatacopy(0, 0, retSz)
            switch success
            case 0 {
                revert(0, retSz)
            }
            default {
                return(0, retSz)
            }
        }
    }

    receive() external payable { }

}

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

import { LowLevelCall } from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";
import { IModule } from "./modules/IModule.sol";

/**
 * @title ModuleSetLib
 * @dev The compliance's module lifecycle, deployed once and linked: binding a module, removing it, filing it
 * under its types again, and forwarding a configuration call to it.
 *
 * These are owner operations, run rarely, and their bytecode is what kept the compliance over EIP-170. The
 * compliance reaches them by DELEGATECALL, so the storage is its own `erc3643.storage.TREXCompliance`
 * namespace at the slot it always had, every module sees the compliance as its caller, and every event is
 * the compliance's. Reading the lists, which every transfer does, stays in the compliance itself.
 *
 * Nothing here checks a caller: the compliance's entry points do, before they reach this.
 */
library ModuleSetLib {

    using EnumerableSet for EnumerableSet.AddressSet;

    /// @custom:storage-location erc7201:erc3643.storage.TREXCompliance
    /// @dev One list of every bound module, plus one list per type. A module sits in `modules` and in the
    ///  list of each type it named, so every dispatch is a loop over exactly the modules that answer it.
    ///  Keying the lists by the type rather than naming one field each means a type added later needs a new
    ///  enum member and its dispatch, and nothing else here.
    struct ModuleSet {
        /// Every bound module, at most 25. What `getModules` returns.
        EnumerableSet.AddressSet modules;
        /// The modules of each type, in the order they were bound.
        mapping(IModule.ModuleType moduleType => EnumerableSet.AddressSet) byType;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXCompliance")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant STORAGE_LOCATION = 0xbd2da5c5fcdced9ef28c358fe4e316978613e6ee5dda1f35de5eca5813787500;

    /// @dev Binds a module: zero check, duplicate check, cap of 25, plug-and-play / canComplianceBind
    ///  requirement, then it is sorted into the list of every type it names. Everything is validated before
    ///  any state is written, so `canComplianceBind` sees the module as not yet bound.
    function addModule(address _module) external {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        ModuleSet storage moduleSet = layout();
        require(moduleSet.modules.length() < 25, ErrorsLib.MaxModulesReached(25));
        require(!moduleSet.modules.contains(_module), ErrorsLib.ModuleAlreadyBound());
        IModule module = IModule(_module);
        require(
            module.isPlugAndPlay() || module.canComplianceBind(address(this)),
            ErrorsLib.ComplianceNotSuitableForBindingToModule(_module)
        );

        moduleSet.modules.add(_module);
        _addToItsTypeLists(moduleSet, _module);

        module.bindCompliance(address(this));

        emit EventsLib.ModuleAdded(_module);
    }

    /// @dev Takes a module out of every list it sits in, without calling into it.
    function removeModule(address _module) external {
        require(_module != address(0), ErrorsLib.ZeroAddress());
        ModuleSet storage moduleSet = layout();
        require(moduleSet.modules.remove(_module), ErrorsLib.ModuleNotBound());
        _removeFromItsTypeLists(moduleSet, _module);
    }

    /// @dev Re-reads what the module says it is and files it again, as a rebind would, without touching the
    ///  module's own state.
    function resyncModuleTypes(address _module) external {
        ModuleSet storage moduleSet = layout();
        require(moduleSet.modules.contains(_module), ErrorsLib.ModuleNotBound());
        _removeFromItsTypeLists(moduleSet, _module);
        _addToItsTypeLists(moduleSet, _module);
    }

    /// @dev Forwards `callData` to a bound `_module` via low-level call and emits the interaction event.
    ///  Reverts when `_module` is not bound or when the underlying call fails.
    function callModuleFunction(bytes calldata callData, address _module) external {
        require(layout().modules.contains(_module), ErrorsLib.ModuleNotBound());

        if (!LowLevelCall.callNoReturn(_module, callData)) {
            LowLevelCall.bubbleRevert();
        }

        emit EventsLib.ModuleInteraction(_module, callData);
    }

    /// @dev The compliance's module namespace. Internal, so the reads every transfer makes stay in the
    ///  compliance itself.
    function layout() internal pure returns (ModuleSet storage moduleSet) {
        assembly ("memory-safe") {
            moduleSet.slot := STORAGE_LOCATION
        }
    }

    /// @dev Adds the module to the list of every type it names. A module that names nothing would never be
    ///  called, and one that names a type twice has a declaration its author did not mean; both are refused.
    function _addToItsTypeLists(ModuleSet storage moduleSet, address _module) private {
        IModule.ModuleType[] memory moduleTypes = IModule(_module).moduleTypes();
        require(moduleTypes.length != 0, ErrorsLib.ModuleHasNoType());

        for (uint256 i = 0; i < moduleTypes.length; i++) {
            IModule.ModuleType moduleType = moduleTypes[i];
            require(moduleSet.byType[moduleType].add(_module), ErrorsLib.DuplicateModuleType(uint8(moduleType)));
        }

        emit EventsLib.ModuleTypesRecorded(_module, moduleTypes);
    }

    /// @dev Removes the module from the list of every type, whichever ones it was in. It walks all the types
    ///  rather than asking the module what it names now, so a module whose declaration changed since it was
    ///  bound still leaves the lists it really sits in.
    function _removeFromItsTypeLists(ModuleSet storage moduleSet, address _module) private {
        for (uint256 i = 0; i <= uint256(type(IModule.ModuleType).max); i++) {
            moduleSet.byType[IModule.ModuleType(i)].remove(_module);
        }
    }

}

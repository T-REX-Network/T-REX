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
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { MulticallUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../../libraries/EventsLib.sol";
import { IModularCompliance } from "../IModularCompliance.sol";
import { IModule } from "./IModule.sol";

/**
 * @dev Base for every compliance module: the binding handshake, the bind nonce, and a default for every
 * question so a module writes only what it answers.
 *
 * A module overrides {moduleTypes} to say what it is, then overrides the functions of those types. The
 * defaults here are the neutral answer: no limit, spender allowed, nothing recorded. A module that names a
 * type and forgets to override its function therefore lets everything through rather than reverting, which is
 * why {moduleTypes} and the overrides are reviewed together.
 *
 * What a module names is read at binding. An upgrade that changes it takes effect once each bound compliance
 * calls `resyncModuleTypes`.
 */
abstract contract AbstractModuleUpgradeable is
    IModule,
    Initializable,
    UUPSUpgradeable,
    MulticallUpgradeable,
    ERC165Upgradeable
{

    /// @custom:storage-location erc7201:erc3643.storage.AbstractModuleUpgradeable
    struct AbstractModuleStorage {
        /// Compliance contract binding status
        mapping(address compliance => bool) complianceBound;

        /// Bind nonce per compliance, incremented on every unbind.
        /// @dev A module that keys its own per-compliance storage by this nonce drops all of it in a single
        /// write when the compliance unbinds, instead of iterating and clearing entry by entry. The old
        /// entries are never read again and stay behind as harmless orphans.
        mapping(address compliance => uint256) nonces;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.AbstractModuleUpgradeable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ABSTRACT_MODULE_STORAGE_LOCATION =
        0x444fa4c260ed0f6b1ae0af41fab4e6d2db0fa3e7e1fd34f89c069636d02e9200;

    /**
     * @dev Throws if `_compliance` is not a bound compliance contract address.
     */
    modifier onlyBoundCompliance(address _compliance) {
        require(_getAbstractModuleStorage().complianceBound[_compliance], ErrorsLib.ComplianceNotBound());
        _;
    }

    /**
     * @dev Throws if called from an address that is not a bound compliance contract.
     */
    modifier onlyComplianceCall() {
        require(_getAbstractModuleStorage().complianceBound[msg.sender], ErrorsLib.OnlyBoundComplianceCanCall());
        _;
    }

    /**
     * @dev prevents use of the implementation contracts
     */
    constructor() {
        _disableInitializers();
    }

    /**
     *  @dev See {IModule-bindCompliance}.
     */
    function bindCompliance(address _compliance) external onlyProxy {
        AbstractModuleStorage storage s = _getAbstractModuleStorage();
        require(_compliance != address(0), ErrorsLib.ZeroAddress());
        require(!s.complianceBound[_compliance], ErrorsLib.ComplianceAlreadyBound());
        require(msg.sender == _compliance, ErrorsLib.OnlyComplianceContractCanCall());
        s.complianceBound[_compliance] = true;
        emit EventsLib.ComplianceBound(_compliance);
    }

    /**
     *  @dev See {IModule-unbindCompliance}.
     *  Increments the bind nonce of `_compliance`, which invalidates any module storage keyed by it.
     */
    function unbindCompliance(address _compliance) external onlyComplianceCall onlyProxy {
        AbstractModuleStorage storage s = _getAbstractModuleStorage();
        require(_compliance != address(0), ErrorsLib.ZeroAddress());
        require(msg.sender == _compliance, ErrorsLib.OnlyComplianceContractCanCall());
        require(!IModularCompliance(_compliance).isModuleBound(address(this)), ErrorsLib.ModuleStillBound());

        s.complianceBound[_compliance] = false;
        s.nonces[_compliance]++;

        emit EventsLib.ComplianceUnbound(_compliance);
    }

    /**
     *  @dev See {IModule-afterTransfer}.
     *  Default no-op: a module overrides it only when it names `TRACKER`.
     */
    // solhint-disable-next-line no-empty-blocks
    function afterTransfer(TransferContext calldata) external virtual onlyComplianceCall { }

    /**
     *  @dev See {IModule-allowedAmount}.
     *  Default no limit: a module overrides it only when it names `RULE`.
     */
    function allowedAmount(TransferContext calldata) external view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     *  @dev See {IModule-moduleCheckSpender}.
     *  Default allowed: a module overrides it only when it names `SPENDER`.
     */
    function moduleCheckSpender(TransferContext calldata) external view virtual returns (bool) {
        return true;
    }

    /**
     *  @dev See {IModule-isComplianceBound}.
     */
    function isComplianceBound(address _compliance) external view returns (bool) {
        AbstractModuleStorage storage s = _getAbstractModuleStorage();
        return s.complianceBound[_compliance];
    }

    /**
     *  @dev Returns the current bind nonce of `_compliance`, starting at 0 and incremented on every
     *  unbind. Modules key their per-compliance storage by this value so that an unbind discards it.
     *  @param _compliance compliance contract address
     */
    function getNonce(address _compliance) public view returns (uint256) {
        AbstractModuleStorage storage s = _getAbstractModuleStorage();
        return s.nonces[_compliance];
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IModule).interfaceId || super.supportsInterface(interfaceId);
    }

    function __AbstractModule_init() internal onlyInitializing {
        __ERC165_init();
        __AbstractModule_init_unchained();
    }

    function __AbstractModule_init_unchained() internal onlyInitializing { }

    function _getAbstractModuleStorage() private pure returns (AbstractModuleStorage storage s) {
        assembly ("memory-safe") {
            s.slot := _ABSTRACT_MODULE_STORAGE_LOCATION
        }
    }

}

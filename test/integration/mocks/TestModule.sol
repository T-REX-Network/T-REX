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

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";

contract TestModule is AbstractModuleUpgradeable {

    /// @dev address authorized to upgrade this test module
    address private _upgradeAdmin;

    /// state variables
    mapping(address => uint256) private _complianceData;
    mapping(address => bool) private _blockedTransfers;

    /// functions

    /**
     * @dev initializes the contract and sets the initial state.
     * @notice This function should only be called once during the contract deployment.
     */
    function initialize() external initializer {
        __AbstractModule_init();
        _upgradeAdmin = msg.sender;
    }

    /// @dev Transfers upgrade authority to a pending admin (two-step: pendingAdmin must call acceptUpgradeAdmin).
    address private _pendingUpgradeAdmin;

    function transferUpgradeAdmin(address newAdmin) external {
        require(msg.sender == _upgradeAdmin, ErrorsLib.NotUpgradeAdmin());
        _pendingUpgradeAdmin = newAdmin;
    }

    function acceptUpgradeAdmin() external {
        require(msg.sender == _pendingUpgradeAdmin, ErrorsLib.NotUpgradeAdmin());
        _upgradeAdmin = _pendingUpgradeAdmin;
        _pendingUpgradeAdmin = address(0);
    }

    function upgradeAdmin() external view returns (address) {
        return _upgradeAdmin;
    }

    function doSomething(uint256 _value) external onlyComplianceCall {
        _complianceData[msg.sender] = _value;
    }

    function blockModule(bool _blocked) external onlyComplianceCall {
        _blockedTransfers[msg.sender] = _blocked;
    }

    function getComplianceData(address _compliance) external view returns (uint256) {
        return _complianceData[_compliance];
    }

    function getBlockedTransfers(address _compliance) external view returns (bool) {
        return _blockedTransfers[_compliance];
    }

    /**
     *  @dev See {IModule-moduleCheck}.
     *  always returns true (just a test module)
     */
    function moduleCheck(
        address,
        /*_from*/
        address,
        uint256,
        address _compliance
    )
        external
        view
        override
        returns (bool)
    {
        if (_blockedTransfers[_compliance]) {
            return false;
        }
        return true;
    }

    /**
     *  @dev See {IModule-moduleCapabilities}.
     *  only the transfer check is implemented, the hooks keep the base defaults
     */
    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.CHECK_TRANSFER;
    }

    /**
     *  @dev See {IModule-canComplianceBind}.
     */
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    /**
     *  @dev See {IModule-isPlugAndPlay}.
     */
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /**
     *  @dev See {IModule-name}.
     */
    function name() public pure returns (string memory _name) {
        return "TestModule";
    }

    /**
     *  @dev Test function to cover onlyBoundCompliance modifier
     */
    function invokeOnlyBoundCompliance(address _compliance) external onlyBoundCompliance(_compliance) { }

    /// @dev Upgrade guard: only the upgrade admin may authorize an upgrade.
    function _authorizeUpgrade(address) internal virtual override {
        require(msg.sender == _upgradeAdmin, ErrorsLib.NotUpgradeAdmin());
    }

    // Fallback function to accept any callData (used for testing _selector with short callData)
    fallback() external { }

}

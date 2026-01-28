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

pragma solidity ^0.8.30;

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { AbstractProxy } from "./AbstractProxy.sol";

interface IFeeCollector {

    function collectFee(address feePayer, uint8 multiplier, uint16 referralCode) external;

}

/// @title AbstractFeeCollectorProxy
/// @notice Abstract contract to allow for fee collection from function calls
/// @dev Contracts inheriting from AbstractFeeCollectorProxy must implements AccesManaged and initialize the AccessManger
/// @dev THE CONTRACT MUST BE WHITELISTED ON FEECOLLECTOR SIDE
abstract contract AbstractFeeCollectorProxy is AbstractProxy {

    struct FeeDetails {
        uint8 multiplier;
        bool hasFees;
    }

    /// @custom:storage-location erc7201:feeCollectorProxy.storage.main
    struct FeeCollectorProxyStorage {
        address feeCollector;
        mapping(bytes4 selector => FeeDetails) functionFees;
    }
    // keccak256(abi.encode(uint256(keccak256("feeCollectorProxy.storage.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant FEE_COLLECTOR_PROXY_STORAGE_LOCATION =
        0xfc1edd06193cb51fe588be932e27464ab102fd2e478bca59288a1ee436b98e00;

    uint16 transient referralCode;

    constructor(address implementationAuthority, address feeCollector) AbstractProxy(implementationAuthority) {
        require(feeCollector != address(0), ErrorsLib.ZeroAddress());

        _feeCollectorProxyStorage().feeCollector = feeCollector;
    }

    /// @notice Calls a function with a referral code
    /// @param _referralCode The referral code to use
    /// @param _data The function and data to call (abi.encodeCall(...))
    function callWithReferralCode(uint16 _referralCode, bytes calldata _data) external payable {
        referralCode = _referralCode;

        (bool success, bytes memory returnData) = address(this).delegatecall(_data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    /// @dev Must be overridden to restrict access
    function setFeeCollector(address _feeCollector) external virtual {
        _updateFeeCollector(_feeCollector);
    }

    function _updateFeeCollector(address _feeCollector) internal {
        FeeCollectorProxyStorage storage s = _feeCollectorProxyStorage();

        address oldFeeCollector = s.feeCollector;
        s.feeCollector = _feeCollector;
        emit EventsLib.FeeCollectorUpdated(oldFeeCollector, _feeCollector, msg.sender);
    }

    /// @dev Must be overridden to restrict access
    /// @notice Sets the fees for multiple functions
    /// @notice Set multiplier to 0 to disable fees for a function
    /// @param _selectors The selectors of the functions to set the fees for
    /// @param _multipliers The multipliers to set for the functions
    function setFunctionsFees(bytes4[] calldata _selectors, uint8[] calldata _multipliers) external virtual {
        _updateFunctionsFees(_selectors, _multipliers);
    }

    function _updateFunctionsFees(bytes4[] calldata _selectors, uint8[] calldata _multipliers) internal {
        FeeCollectorProxyStorage storage s = _feeCollectorProxyStorage();
        for (uint256 i = 0; i < _selectors.length; i++) {
            s.functionFees[_selectors[i]] = FeeDetails({ multiplier: _multipliers[i], hasFees: _multipliers[i] > 0 });
        }
    }

    // solhint-disable-next-line no-complex-fallback
    fallback() external payable override {
        FeeCollectorProxyStorage storage s = _feeCollectorProxyStorage();
        if (s.functionFees[msg.sig].hasFees) {
            IFeeCollector(s.feeCollector).collectFee(msg.sender, s.functionFees[msg.sig].multiplier, referralCode);
        }

        address logic = getLogic();

        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0x0, 0x0, calldatasize())
            let success := delegatecall(sub(gas(), 10000), logic, 0x0, calldatasize(), 0, 0)
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

    function _feeCollectorProxyStorage() private pure returns (FeeCollectorProxyStorage storage $) {
        assembly {
            $.slot := FEE_COLLECTOR_PROXY_STORAGE_LOCATION
        }
    }

}

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

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";

/**
 * @title ComplianceLedgerLib
 * @dev The layout of the compliance's ledger, and the part of it that is not on a transfer's path: the
 * owner's position repair, deployed once and linked, and the pending reservation an issuance writes.
 *
 * The compliance reaches {fixPosition} by DELEGATECALL, so the storage is its own
 * `erc3643.storage.ComplianceLedger` namespace at the slot it always had and the event is the compliance's.
 * The caller is checked by the compliance's entry point, before it reaches this.
 */
library ComplianceLedgerLib {

    /// @custom:storage-location erc7201:erc3643.storage.ComplianceLedger
    struct Ledger {
        /// What each identity owns over every wallet and every chain.
        mapping(address identity => uint256 amount) position;
        /// What open validations promise to each identity.
        mapping(address identity => uint256 amount) pendingIn;
        /// What open validations promise out of each identity.
        mapping(address identity => uint256 amount) pendingOut;
        /// The gap between the positions and the supply: credits that landed on nobody add to it,
        /// debits that found nobody or found too little subtract from it. Zero while the registry is stable.
        int256 gap;
        /// The identity each native wallet was last credited to, so a relink is noticed and followed.
        mapping(address wallet => address identity) ownerOf;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.ComplianceLedger")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant LEDGER_STORAGE_LOCATION =
        0x37065f79446a9096383af794d27f19e665b7dd5afcf9e812ca702bcc08bee600;

    /// @dev Moves `amount` of position from one side to the other. A zero side is the gap between the positions and
    ///  the supply, so this can give tokens that landed on nobody their owner, or take a stale position off an
    ///  identity a relink left too high.
    function fixPosition(address from, address to, uint256 amount) external {
        require(from != to, ErrorsLib.FromAndToAreTheSame());
        Ledger storage ledger = layout();

        if (from == address(0)) {
            ledger.gap -= int256(amount);
        } else {
            uint256 held = ledger.position[from];
            require(held >= amount, ErrorsLib.InsufficientPosition(from, held, amount));
            ledger.position[from] = held - amount;
        }

        if (to == address(0)) ledger.gap += int256(amount);
        else ledger.position[to] += amount;

        emit EventsLib.PositionFixed(from, to, amount);
    }

    /// @dev Counts an issued validation as pending at `amountMax`, the worst case for any additive rule. Only
    ///  when ownership really moves: relocating tokens between two wallets of one identity never eats that
    ///  identity's own room.
    /// @return identitiesReserved whether anything was written, which the caller records on the validation
    function reservePending(address fromIdentity, address toIdentity, uint256 amountMax)
        internal
        returns (bool identitiesReserved)
    {
        if (isRelocation(fromIdentity, toIdentity)) return false;
        Ledger storage ledger = layout();
        ledger.pendingOut[fromIdentity] += amountMax;
        ledger.pendingIn[toIdentity] += amountMax;
        return true;
    }

    /// @dev One identity on both sides. Two wallets that resolve to nobody are not that. The one definition of
    ///  a relocation, for the ledger and the validation flow alike.
    function isRelocation(address fromIdentity, address toIdentity) internal pure returns (bool) {
        return fromIdentity != address(0) && fromIdentity == toIdentity;
    }

    function layout() internal pure returns (Ledger storage ledger) {
        assembly ("memory-safe") {
            ledger.slot := LEDGER_STORAGE_LOCATION
        }
    }

}

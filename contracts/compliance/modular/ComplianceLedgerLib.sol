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

// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ErrorsLib } from "../../libraries/ErrorsLib.sol";
import { EventsLib } from "../../libraries/EventsLib.sol";

/**
 * @title ComplianceLedgerLib
 * @dev The layout of the compliance's ledger and every write to it: the position a movement moves, the owner a
 * native wallet's balance is counted under, and the pending reservation an issuance writes and a settlement or a
 * discard releases. All internal, so each write is compiled into the contract or the linked library that makes
 * it: the compliance for a native movement, the validation libraries for a cross-chain one.
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
        /// Was the gap between the positions and the supply. Kept so `ownerOf` stays in its slot for a deployed proxy.
        int256 __deprecatedGap;
        /// The identity each native wallet was last credited to, so a change of owner is noticed and followed.
        mapping(address wallet => address identity) ownerOf;
        /// What all open validations promise, relocations included: every validation the bound token still holds
        /// a reservation for. Zero is what lets the compliance leave a token or be bound to another one without
        /// carrying a promise it could no longer release.
        uint256 pendingTotal;
        /// The money on hold that left each chain and goes on to its receiver: it left that chain already, but is
        /// told done only once the receiver's chain answers.
        mapping(bytes32 chainKey => uint256 amount) onHoldForward;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.ComplianceLedger")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant LEDGER_STORAGE_LOCATION =
        0x37065f79446a9096383af794d27f19e665b7dd5afcf9e812ca702bcc08bee600;

    /// @dev Counts an issued validation as pending at `amountMax`, the worst case for any additive rule. The
    ///  total counts every validation, since the token holds a reservation for each until the compliance closes
    ///  it. The identities' rows count only when ownership really moves: relocating tokens between two wallets of
    ///  one identity never eats that identity's own room.
    /// @return identitiesReserved whether the identities' rows were written, which the caller records on the
    ///  validation
    function reservePending(address fromIdentity, address toIdentity, uint256 amountMax)
        internal
        returns (bool identitiesReserved)
    {
        Ledger storage ledger = layout();
        ledger.pendingTotal += amountMax;
        if (isRelocation(fromIdentity, toIdentity)) return false;
        ledger.pendingOut[fromIdentity] += amountMax;
        ledger.pendingIn[toIdentity] += amountMax;
        return true;
    }

    /// @dev Undoes the total of {reservePending}, once the movement is over: the validation settled, or the
    ///  ticket was cancelled. Every validation gets here, a relocation included.
    function releasePendingTotal(uint256 amountMax) internal {
        layout().pendingTotal -= amountMax;
    }

    /// @dev Undoes the identities' rows of {reservePending}. Only a validation that wrote them gets here, so
    ///  never a relocation.
    function releasePendingOfIdentities(address fromIdentity, address toIdentity, uint256 amountMax) internal {
        Ledger storage ledger = layout();
        ledger.pendingOut[fromIdentity] -= amountMax;
        ledger.pendingIn[toIdentity] -= amountMax;
    }

    /// @dev Moves `amount` of position from one identity to the other: one side loses it, the other gains it.
    ///
    ///  A relocation between two wallets of one identity is not a change of ownership, so nothing moves.
    ///  A zero wallet is the absent side of a mint or a burn, and is simply skipped.
    function movePosition(
        address fromIdentity,
        address toIdentity,
        bytes32 fromWallet,
        bytes32 toWallet,
        uint256 amount
    ) internal {
        if (isRelocation(fromIdentity, toIdentity)) return;
        mapping(address identity => uint256 amount) storage position = layout().position;
        if (fromWallet != bytes32(0)) position[fromIdentity] -= amount;
        if (toWallet != bytes32(0)) position[toIdentity] += amount;
    }

    /// @dev Who a native wallet's tokens belong to now. An empty wallet follows the registry; a funded one is
    ///  refused until the registry names the identity the ledger credited again, since a balance changing identity
    ///  outside a movement is a position no rule ever checked. `adjustment` is what this very movement already did
    ///  to the wallet's balance on the token, so that what is judged is what the wallet held before it: `+amount`
    ///  for a sender the token already debited, `-amount` for a recipient it already credited, zero otherwise.
    /// @param token the token the compliance is bound to
    function currentOwner(address token, address wallet, address resolved, int256 adjustment)
        internal
        returns (address owner)
    {
        address previous;
        (owner, previous) = _followOwner(wallet, resolved);
        if (previous == address(0)) return owner;
        uint256 balance = uint256(int256(IERC20(token).balanceOf(wallet)) + adjustment);
        // A balance never changes identity without the rules seeing it, and the rules only see movements. So a
        // funded wallet keeps the owner the ledger credited until that owner is named again or the wallet is empty.
        bool walletIsEmpty = balance == 0;
        require(walletIsEmpty, ErrorsLib.WalletBoundToAnotherIdentity(wallet, previous));
        // Only an empty wallet gets here, so no position moves; the event keeps its amount field, always zero,
        // so indexers built on it need no change.
        emit EventsLib.WalletOwnerChanged(wallet, previous, owner, 0);
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

    /// @dev Who a native wallet's tokens belong to now, given who the registry names. Records the first owner
    ///  seen, follows a change of owner, and keeps the remembered owner when the registry names nobody.
    /// @return owner the identity to debit or credit for this wallet
    /// @return previous the identity that was credited before, when the owner just changed; zero otherwise. The
    ///  caller decides whether the wallet may change owner: only an empty one may.
    function _followOwner(address wallet, address resolved) private returns (address owner, address previous) {
        mapping(address => address) storage ownerOf = layout().ownerOf;
        address recorded = ownerOf[wallet];
        if (resolved == address(0)) return (recorded, address(0));
        if (recorded == resolved) return (resolved, address(0));
        ownerOf[wallet] = resolved;
        return (resolved, recorded);
    }

}

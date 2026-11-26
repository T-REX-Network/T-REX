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

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { WalletKeyLib } from "../libraries/WalletKeyLib.sol";

/**
 * @title TokenLedgerLib
 * @dev The token's bridged ledger, deployed once and linked.
 *
 * Satellite positions, in-transit holds and validation reservations are envelope parsing and bucket
 * arithmetic: bytecode that pushed the token past EIP-170. It lives here and the token reaches it by
 * DELEGATECALL, so the storage is the token's own `erc3643.storage.TREXToken` namespace at the slot it
 * always had, `block.chainid` and `address(this)` are the token's, and every event is the token's.
 *
 * Nothing here is an entry point and nothing checks a caller or the pause: the token's entry points do,
 * before they reach this. The native half of a movement is not here either, since it is the ERC-20
 * balance the library cannot reach: the token burns or mints it around the call. Its state-changing
 * functions cannot be called on the library itself.
 */
library TokenLedgerLib {

    /// @custom:storage-location erc7201:erc3643.storage.TREXToken
    struct TokenStorage {
        uint8 decimals;
        /// @dev Positions delegated to satellites, keyed by the canonical ERC-7930 wallet key. Separate from the
        ///  native mapping, which stays OpenZeppelin's.
        mapping(bytes32 walletKey => uint256) awayBalance;
        /// @dev Sum of every bridged position, kept so `totalSupply` counts it in O(1).
        uint256 totalAwayBalance;
        /// @dev The money on hold between the two halves of a move, keyed by its ticket: what left the sender's
        ///  wallet, an away wallet or a home wallet, and has not reached the wallet it ends on. Counted in
        ///  `totalAwayBalance`, still owned by the sender the ticket names.
        mapping(bytes32 ticketId => uint256) inTransit;
        /// @dev Sum of every in-transit hold: the part of `totalAwayBalance` no wallet currently holds.
        uint256 totalOnHold;
        /// @dev What open validations may still draw from each satellite wallet. Kept here, beside the balance
        ///  it reserves against, so `availableOf` is one subtraction rather than two contracts agreeing: the
        ///  compliance reserves at issuance and gives back when the ticket leaves its open row, a receipt or a
        ///  cancel.
        mapping(bytes32 walletKey => uint256) reservedForTickets;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXToken")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOKEN_STORAGE_LOCATION =
        0x05378669fd58b6f9251e6d5461e60e18b8b3fdf11d70481ba6f9fc72a4bfc600;

    /* ----- Views ----- */

    /// @dev See {IToken-awayBalanceOf}.
    function awayBalanceOf(bytes calldata wallet) external view returns (uint256) {
        return layout().awayBalance[WalletKeyLib.canonicalKey(wallet)];
    }

    /// @dev See {IToken-reservedOf}.
    function reservedOf(bytes calldata wallet) external view returns (uint256) {
        return layout().reservedForTickets[WalletKeyLib.canonicalKey(wallet)];
    }

    /// @dev See {IToken-availableOf}. An open bring home reserves in the same table as every ticket.
    function availableOf(bytes calldata wallet) external view returns (uint256) {
        TokenStorage storage s = layout();
        bytes32 key = WalletKeyLib.canonicalKey(wallet);
        uint256 balance = s.awayBalance[key];
        uint256 reservedForTickets = s.reservedForTickets[key];
        return reservedForTickets < balance ? balance - reservedForTickets : 0;
    }

    /* ----- Reservations ----- */

    /// @dev Records that an open validation may draw `amount` from a satellite `wallet`.
    function reserve(bytes calldata wallet, uint256 amount) external {
        bytes32 key = WalletKeyLib.satelliteKey(wallet);
        layout().reservedForTickets[key] += amount;

        emit EventsLib.ReservedForValidation(key, wallet, amount);
    }

    /// @dev Gives back what a validation reserved against `wallet`. See {_release}.
    function release(bytes calldata wallet, uint256 amount) external {
        _release(WalletKeyLib.canonicalKey(wallet), wallet, amount);
    }

    /* ----- Transitions ----- */

    /// @dev Takes `amount` out of `fromWallet`'s away balance and holds it against `ticketId`: the first half of a
    ///  move landed, its away chain burned the amount, and the second half has not. The amount stays counted in
    ///  `totalAwayBalance` and stays the sender's; only the wallet no longer holds it. One hold per ticket.
    function putOnHold(bytes calldata fromWallet, uint256 amount, bytes32 ticketId) external {
        bytes32 fromKey = WalletKeyLib.satelliteKey(fromWallet);

        TokenStorage storage s = layout();
        require(s.inTransit[ticketId] == 0, ErrorsLib.TransitAlreadyHeld(ticketId));
        _debit(s, fromWallet, fromKey, amount);
        s.inTransit[ticketId] = amount;
        s.totalOnHold += amount;

        emit EventsLib.HeldInTransit(fromKey, ticketId, fromWallet, amount);
    }

    /// @dev Holds `amount` against `ticketId` for a home wallet that moves out: the token burns it from the wallet's
    ///  native balance right after, so the amount leaves the native supply and joins `totalAwayBalance` on hold, and
    ///  `totalSupply` does not move. One hold per ticket.
    /// @return holder The home wallet the token burns from.
    function holdFromHome(bytes calldata fromWallet, uint256 amount, bytes32 ticketId)
        external
        returns (address holder)
    {
        (, holder) = WalletKeyLib.isReferenceChain(fromWallet);
        require(holder != address(0), ErrorsLib.ZeroAddress());

        TokenStorage storage s = layout();
        require(s.inTransit[ticketId] == 0, ErrorsLib.TransitAlreadyHeld(ticketId));
        s.inTransit[ticketId] = amount;
        s.totalOnHold += amount;
        s.totalAwayBalance += amount;

        emit EventsLib.HeldInTransit(keccak256(fromWallet), ticketId, fromWallet, amount);
    }

    /// @dev Ends a move: `amount` leaves the ticket's hold when it has one, `from`'s away balance otherwise, and
    ///  lands on `to`. A receiver on this chain is the token's to credit, so only the bridged side is applied here
    ///  and `toNative` tells the token to mint `amount` to `recipient`; any other receiver is credited here. A hold
    ///  may be released in parts: the compliance never takes more from it than it put on it.
    /// @return toNative Whether the receiver is a wallet on this chain.
    /// @return recipient That wallet, when `toNative`.
    /// @return fromKey The sender's key.
    function settle(bytes calldata from, bytes calldata to, uint256 amount, bytes32 ticketId)
        external
        returns (bool toNative, address recipient, bytes32 fromKey)
    {
        fromKey = WalletKeyLib.canonicalKey(from);
        TokenStorage storage s = layout();
        _takeFromHoldOrWallet(s, from, fromKey, amount, ticketId);

        (toNative, recipient) = WalletKeyLib.isReferenceChain(to);
        if (toNative) {
            s.totalAwayBalance -= amount;
            return (toNative, recipient, fromKey);
        }

        bytes32 toKey = WalletKeyLib.satelliteKey(to);
        s.awayBalance[toKey] += amount;

        emit EventsLib.BridgedTransfer(fromKey, toKey, ticketId, from, to, amount);
    }

    /* ----- Storage ----- */

    /// @dev The token's `TREXToken` namespace. Internal, so the cheap reads stay in the token itself.
    function layout() internal pure returns (TokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TOKEN_STORAGE_LOCATION
        }
    }

    /* ----- Private ----- */

    /// @dev Takes `amount` off the ticket's hold when it has one: the second half of a move, or the end of a home
    ///  wallet's move out. Off `from`'s away balance otherwise: a move inside one away chain.
    function _takeFromHoldOrWallet(
        TokenStorage storage s,
        bytes calldata from,
        bytes32 fromKey,
        uint256 amount,
        bytes32 ticketId
    ) private {
        uint256 held = s.inTransit[ticketId];
        if (held == 0) {
            _debit(s, from, fromKey, amount);
            return;
        }
        s.inTransit[ticketId] = held - amount;
        s.totalOnHold -= amount;
    }

    /// @dev Gives back what a validation reserved against a wallet. Floors at zero rather than reverting: the
    ///  compliance is the only caller and releases each reservation once, so a shortfall would mean its own
    ///  bookkeeping is wrong, and blocking a settlement over it would strand the movement.
    function _release(bytes32 key, bytes calldata wallet, uint256 amount) private {
        mapping(bytes32 => uint256) storage reserved = layout().reservedForTickets;
        uint256 held = reserved[key];
        uint256 released = held < amount ? held : amount;
        reserved[key] = held - released;

        emit EventsLib.ReleasedFromValidation(key, wallet, released);
    }

    function _debit(TokenStorage storage s, bytes calldata wallet, bytes32 key, uint256 amount) private {
        uint256 balance = s.awayBalance[key];
        require(amount <= balance, ErrorsLib.InsufficientBridgedBalance(wallet, balance, amount));
        s.awayBalance[key] = balance - amount;
    }

}

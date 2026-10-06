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
        mapping(bytes32 walletKey => uint256) bridgedBalance;
        /// @dev Sum of every bridged position, kept so `totalSupply` counts it in O(1).
        uint256 totalBridged;
        /// @dev Amounts a satellite burned for a cross-chain validation whose mint leg has not landed, keyed by
        ///  the validation. Debited from the sender's position, still counted in `totalBridged`, still owned by
        ///  the sender the validation names.
        mapping(uint256 validationId => uint256) inTransit;
        /// @dev Sum of every in-transit hold: the part of `totalBridged` no wallet currently holds.
        uint256 totalInTransit;
        /// @dev What open validations may still draw from each satellite wallet. Kept here, beside the balance
        ///  it reserves against, so `availableOf` is one subtraction rather than two contracts agreeing: the
        ///  compliance reserves at issuance and gives back at settlement or discard, and `holdInTransit` turns a
        ///  reservation straight into a hold, which is why nothing has to be released in between.
        mapping(bytes32 walletKey => uint256) reservedForValidations;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.TREXToken")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TOKEN_STORAGE_LOCATION =
        0x05378669fd58b6f9251e6d5461e60e18b8b3fdf11d70481ba6f9fc72a4bfc600;

    /* ----- Views ----- */

    /// @dev See {IToken-bridgedBalanceOf}.
    function bridgedBalanceOf(bytes calldata wallet) external view returns (uint256) {
        return layout().bridgedBalance[WalletKeyLib.canonicalKey(wallet)];
    }

    /// @dev See {IToken-reservedOf}.
    function reservedOf(bytes calldata wallet) external view returns (uint256) {
        return layout().reservedForValidations[WalletKeyLib.canonicalKey(wallet)];
    }

    /// @dev See {IToken-availableOf}.
    function availableOf(bytes calldata wallet) external view returns (uint256) {
        TokenStorage storage s = layout();
        bytes32 key = WalletKeyLib.canonicalKey(wallet);
        uint256 balance = s.bridgedBalance[key];
        uint256 reserved = s.reservedForValidations[key];
        return reserved < balance ? balance - reserved : 0;
    }

    /* ----- Reservations ----- */

    /// @dev Records that an open validation may draw `amount` from a satellite `wallet`.
    function reserve(bytes calldata wallet, uint256 amount) external {
        bytes32 key = WalletKeyLib.satelliteKey(wallet);
        layout().reservedForValidations[key] += amount;

        emit EventsLib.ReservedForValidation(key, wallet, amount);
    }

    /// @dev Gives back what a validation reserved against `wallet`. See {_release}.
    function release(bytes calldata wallet, uint256 amount) external {
        _release(WalletKeyLib.canonicalKey(wallet), wallet, amount);
    }

    /* ----- Transitions ----- */

    /// @dev Takes `amount` out of `fromWallet`'s bridged position and holds it against `validationId`: the burn
    ///  leg of a cross-chain validation landed, the mint leg has not. The amount stays bridged and stays the
    ///  sender's; only the wallet no longer holds it, so nothing can be issued or recalled against tokens the
    ///  satellite already burned. One hold per validation.
    /// @dev Turns what a validation reserved against the wallet into an in-transit hold, in one step: the
    ///  tokens leave the wallet, so the reservation that was standing in for them is given back at the same
    ///  time and there is nothing to release separately.
    /// @param reserved what this validation had reserved against the wallet, released as the hold is taken
    function holdInTransit(bytes calldata fromWallet, uint256 amount, uint256 validationId, uint256 reserved) external {
        bytes32 fromKey = WalletKeyLib.satelliteKey(fromWallet);

        TokenStorage storage s = layout();
        require(s.inTransit[validationId] == 0, ErrorsLib.TransitAlreadyHeld(validationId));
        if (reserved != 0) _release(fromKey, fromWallet, reserved);
        _debit(s, fromWallet, fromKey, amount);
        s.inTransit[validationId] = amount;
        s.totalInTransit += amount;

        emit EventsLib.HeldInTransit(fromKey, validationId, fromWallet, amount);
    }

    /// @dev Puts a held amount back on the wallet it was burned from. The mirror of {holdInTransit}: the
    ///  movement is unwound where it started instead of completed, so `totalSupply` and `totalBridged` do not
    ///  move, only the hold becomes a balance again.
    function returnHeldInTransit(bytes calldata toWallet, uint256 validationId) external {
        TokenStorage storage s = layout();
        uint256 held = s.inTransit[validationId];
        require(held != 0, ErrorsLib.NothingInTransit(validationId));

        bytes32 toKey = WalletKeyLib.satelliteKey(toWallet);
        delete s.inTransit[validationId];
        s.totalInTransit -= held;
        s.bridgedBalance[toKey] += held;

        emit EventsLib.ReturnedInTransit(toKey, validationId, toWallet, held);
    }

    /// @dev Routes a settled validation leg. A receiver on this chain is the token's to credit, so only the
    ///  bridged half is applied here: the sender's position is debited and `toNative` tells the token to mint
    ///  `amount` to `recipient` and name the movement. Any other receiver is a movement between two satellite
    ///  wallets and is applied whole, see {_bridgedTransfer}.
    /// @return toNative Whether the receiver is a wallet on this chain.
    /// @return recipient That wallet, when `toNative`.
    /// @return fromKey The sender's key, when `toNative`.
    function settle(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId)
        external
        returns (bool toNative, address recipient, bytes32 fromKey)
    {
        (toNative, recipient) = WalletKeyLib.isReferenceChain(to);
        if (toNative) {
            fromKey = _debitToNative(from, recipient, amount);
        } else {
            _bridgedTransfer(from, to, amount, validationId);
        }
    }

    /// @dev The bridged half of every bridged-to-native transition: a bridged debit, `totalBridged` down. The
    ///  token mints `amount` to `holder` afterwards and names the movement. Emits nothing.
    function debitToNative(bytes calldata fromWallet, address holder, uint256 amount)
        external
        returns (bytes32 fromKey)
    {
        return _debitToNative(fromWallet, holder, amount);
    }

    /// @dev The bridged half of every native-to-bridged transition: a bridged credit, `totalBridged` up. The
    ///  token burns `amount` from `holder` afterwards and names the movement. Emits nothing.
    /// @param freeBalance `holder`'s free native balance, read by the token; `amount` may not exceed it
    function creditFromNative(address holder, bytes calldata toWallet, uint256 amount, uint256 freeBalance)
        external
        returns (bytes32 toKey)
    {
        toKey = WalletKeyLib.satelliteKey(toWallet);
        require(amount <= freeBalance, IERC20Errors.ERC20InsufficientBalance(holder, freeBalance, amount));

        TokenStorage storage s = layout();
        s.bridgedBalance[toKey] += amount;
        s.totalBridged += amount;
    }

    /* ----- Storage ----- */

    /// @dev The token's `TREXToken` namespace. Internal, so the cheap reads stay in the token itself.
    function layout() internal pure returns (TokenStorage storage $) {
        assembly ("memory-safe") {
            $.slot := TOKEN_STORAGE_LOCATION
        }
    }

    /* ----- Private ----- */

    /// @dev Applies a settled movement between two satellite wallets, same-chain or cross-chain, in one atomic
    ///  touch: `from` down, `to` up, nothing native. `validationId` is the validation the settlement consumed.
    ///  When its burn leg already moved the amount in transit, the hold is what `to` is credited from, and it
    ///  must be the settled amount exactly.
    function _bridgedTransfer(bytes calldata from, bytes calldata to, uint256 amount, uint256 validationId) private {
        bytes32 fromKey = WalletKeyLib.satelliteKey(from);
        bytes32 toKey = WalletKeyLib.satelliteKey(to);

        TokenStorage storage s = layout();
        uint256 held = s.inTransit[validationId];
        if (held != 0) {
            require(held == amount, ErrorsLib.TransitAmountMismatch(validationId, held, amount));
            delete s.inTransit[validationId];
            s.totalInTransit -= amount;
        } else {
            _debit(s, from, fromKey, amount);
        }
        s.bridgedBalance[toKey] += amount;

        emit EventsLib.BridgedTransfer(fromKey, toKey, validationId, from, to, amount);
    }

    function _debitToNative(bytes calldata fromWallet, address holder, uint256 amount)
        private
        returns (bytes32 fromKey)
    {
        require(holder != address(0), ErrorsLib.ZeroAddress());
        fromKey = WalletKeyLib.satelliteKey(fromWallet);

        TokenStorage storage s = layout();
        _debit(s, fromWallet, fromKey, amount);
        s.totalBridged -= amount;
    }

    /// @dev Gives back what a validation reserved against a wallet. Floors at zero rather than reverting: the
    ///  compliance is the only caller and releases each reservation once, so a shortfall would mean its own
    ///  bookkeeping is wrong, and blocking a settlement over it would strand the movement.
    function _release(bytes32 key, bytes calldata wallet, uint256 amount) private {
        mapping(bytes32 => uint256) storage reserved = layout().reservedForValidations;
        uint256 held = reserved[key];
        uint256 released = held < amount ? held : amount;
        reserved[key] = held - released;

        emit EventsLib.ReleasedFromValidation(key, wallet, released);
    }

    function _debit(TokenStorage storage s, bytes calldata wallet, bytes32 key, uint256 amount) private {
        uint256 balance = s.bridgedBalance[key];
        require(amount <= balance, ErrorsLib.InsufficientBridgedBalance(wallet, balance, amount));
        s.bridgedBalance[key] = balance - amount;
    }

}

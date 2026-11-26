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

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";

/// @title IToken
/// @notice The T-REX token surface beyond ERC-3643: the ledger views the standard does not define.
///  A position has three buckets. Free and frozen are native and `balanceOf` is their sum, plain ERC-20.
///  Bridged is the part delegated to satellites, per ERC-7930 wallet, outside `balanceOf`; `totalSupply` counts
///  all three. Inside the bridged bucket, the money of a move between its two halves is on hold against its
///  ticket: no wallet holds it, its sender still owns it.
interface IToken is IERC3643 {

    event ReservedForValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);
    event ReleasedFromValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);
    event HeldInTransit(bytes32 indexed fromKey, bytes32 indexed ticketId, bytes fromWallet, uint256 amount);
    event BridgedTransfer(
        bytes32 indexed fromKey, bytes32 indexed toKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );

    error InsufficientBridgedBalance(bytes wallet, uint256 balance, uint256 needed);
    error PeerChanged(bytes32 chainKey);
    error UnverifiedWallet(bytes wallet);
    error NonCanonicalInteroperableAddress(bytes envelope);
    error NotASatelliteWallet(bytes wallet);
    error TransitAlreadyHeld(bytes32 ticketId);
    error NoTokenToRecover();
    error RecoveryNotPossible();
    error SameWalletRecovery();
    error TokenCirculating();
    error InvalidIdentityRegistry();
    error InvalidCompliance();
    error ComplianceAlreadyBoundToToken();

    /// @notice Returns the part of a wallet's balance that is movable on this chain: `balanceOf` minus frozen.
    /// @param wallet the wallet to read
    function freeBalanceOf(address wallet) external view returns (uint256);

    /// @notice Returns the position delegated to a satellite wallet.
    /// @dev A non-canonical envelope reverts rather than reading a key no transition ever wrote.
    /// @param wallet the ERC-7930 envelope of the satellite wallet
    function awayBalanceOf(bytes calldata wallet) external view returns (uint256);

    /// @notice Returns the sum of every bridged position, the in-transit holds included: the part of
    ///  `totalSupply` active on satellites. The native float, what the ERC-20 balances on this chain add up to,
    ///  is `totalSupply() - totalAwayBalance()`.
    function totalAwayBalance() external view returns (uint256);

    /// @notice Returns the money on hold for a move between its two halves. Zero once the move ended, or for a
    ///  ticket that never held anything.
    /// @param ticketId the ticket of the move
    function onHoldOf(bytes32 ticketId) external view returns (uint256);

    /// @notice Returns the sum of every in-transit hold: the part of `totalAwayBalance` no wallet currently holds.
    function totalOnHold() external view returns (uint256);

    /// @notice Ends a move on the ledger, once, by the shape of its wallets: `amount` leaves the ticket's hold when it
    ///  has one, `from`'s away balance otherwise; a home `to` is minted to, an away `to` credited. A hold may be
    ///  released in parts.
    /// @dev Callable by the bound compliance only, which classified the receipt against the ticket it issued; reverts
    ///  with `OnlyBoundCompliance` otherwise. Reverts with `InsufficientBridgedBalance` when `from`'s away balance no
    ///  longer covers `amount`, which leaves the receipt deliverable again. Reverts with `EnforcedPause` while the
    ///  token is paused. Bypasses `_update`, like every ledger transition.
    /// @param from the ERC-7930 envelope of the sender: an away wallet, or the home wallet of a move out
    /// @param to the ERC-7930 envelope of the wallet the move ends on
    /// @param amount the exact amount that moved
    /// @param ticketId the ticket of the move
    function finishMove(bytes calldata from, bytes calldata to, uint256 amount, bytes32 ticketId) external;

    /// @notice Takes `amount` out of `from`'s away balance and puts it on hold against `ticketId`: the away chain
    ///  burned it for the first half of a move, and the second half has not landed. `totalAwayBalance` and
    ///  `totalSupply` do not move; the amount is still the sender's. `finishMove` for the same ticket later takes
    ///  it from the hold.
    /// @dev Callable by the bound compliance only; reverts with `OnlyBoundCompliance` otherwise. Reverts with
    ///  `TransitAlreadyHeld` when the ticket already holds an amount, with `InsufficientBridgedBalance` when `from`'s
    ///  away balance no longer covers `amount`, and with `EnforcedPause` while the token is paused.
    /// @param from the ERC-7930 envelope of the sender, an away wallet
    /// @param amount the exact amount the away chain burned
    /// @param ticketId the ticket of the move
    function putOnHold(bytes calldata from, uint256 amount, bytes32 ticketId) external;

    /// @notice Burns `amount` of the home wallet `from` and puts it on hold against `ticketId`: a home wallet that
    ///  moves out to an away wallet. The native balance is burned (`Transfer(holder, 0x0)`), the hold joins
    ///  `totalAwayBalance`, `totalSupply` does not move; `finishMove` later takes it from the hold.
    /// @dev Callable by the bound compliance only, which checked the free balance, the freeze and the rules at the
    ///  ask; reverts with `OnlyBoundCompliance` otherwise. Reverts with `ZeroAddress` when `from` is not a home
    ///  wallet, `TransitAlreadyHeld`, `ERC20InsufficientBalance` and `EnforcedPause`.
    /// @param from the ERC-7930 envelope of the home wallet
    /// @param amount the amount burned
    /// @param ticketId the ticket of the move
    function burnOntoHold(bytes calldata from, uint256 amount, bytes32 ticketId) external;

    /// @dev What open tickets may still draw from `wallet`, an open bring home included. The compliance reserves
    ///  this when a ticket is written and gives it back when the ticket leaves its open row.
    /// @param wallet the satellite wallet, ERC-7930
    function reservedOf(bytes calldata wallet) external view returns (uint256);

    /// @dev What `wallet` can still send: its bridged balance less what open tickets may draw from it, an open bring
    ///  home included. Floors at zero. The compliance bounds every new ask and every bring home by this, so none
    ///  draws on tokens another ticket reserved.
    /// @param wallet the satellite wallet, ERC-7930
    function availableOf(bytes calldata wallet) external view returns (uint256);

    /// @dev Reserves `amount` of `wallet`'s bridged balance for a validation being issued. Callable by the
    ///  bound compliance alone.
    function reserveForTicket(bytes calldata wallet, uint256 amount) external;

    /// @dev Gives back `amount` of what was reserved against `wallet`. Callable by the bound compliance alone.
    function releaseFromTicket(bytes calldata wallet, uint256 amount) external;

    /// @dev Initializes a token behind its beacon proxy. Called once, by the factory.
    function init(
        string calldata tokenName,
        string calldata tokenSymbol,
        uint8 tokenDecimals,
        address identityRegistryAddress,
        address complianceAddress,
        address trustedGatewayRegistryAddress,
        address onchainIdAddress,
        address accessManagerAddress
    ) external;

    /// @dev Sends a ticket, or an ask for its receipt, to this token's peer on `chainKey`, on the ticket route when
    ///  one is usable and on the receipt route otherwise. Callable by the bound compliance alone.
    function sendOnTicketRoute(bytes32 chainKey, bytes32 ticketId, bytes calldata body) external returns (bytes32);

    /// @dev Sends a message for one half of a move, a `MOVE_OUT` or a `BRING_HOME`, to this token's peer on `chainKey`
    ///  on the receipt route, at full finality, and pins `halfKey` to that route and peer at its first send. A half sent
    ///  again goes only to the pair it was pinned to, while it is the chain's current pair; otherwise reverts with
    ///  `PeerChanged`. Reverts with `ChainNotOpen` when the chain has no open receipt route. Callable by the bound
    ///  compliance alone; reverts with `OnlyBoundCompliance` otherwise. Emits `HalfPinned` at the first send and
    ///  `ProtocolMessageSent`.
    /// @param chainKey the away chain the half goes to
    /// @param halfKey the half, see {MessageTypesLib-halfKeyOf}
    /// @param messageType what the message is
    /// @param body the encoded message
    /// @return the gateway's id for the message
    function sendOnReceiptRoute(
        bytes32 chainKey,
        bytes32 halfKey,
        MessageTypesLib.Message messageType,
        bytes calldata body
    ) external returns (bytes32);

}

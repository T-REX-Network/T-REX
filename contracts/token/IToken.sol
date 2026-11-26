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

    event RecallInstructed(
        uint256 indexed recallId, bytes32 indexed walletKey, address indexed nativeWallet, bytes wallet, uint256 amount
    );
    event RecallSettled(uint256 indexed recallId, bytes32 indexed originChainKey, uint256 amount);
    event BurnProofDuplicate(uint256 indexed recallId, bytes32 indexed originChainKey);
    event ReplayedBurnProof(uint256 indexed recallId, bytes32 indexed originChainKey);
    event InstructionResent(uint8 indexed kind, uint256 indexed id, bytes32 indexed chainKey, bytes32 sendId);

    error InsufficientBridgedBalance(bytes wallet, uint256 balance, uint256 needed);
    error WalletsNotLinked(address nativeWallet, bytes wallet);
    error RecallMismatch(uint256 recallId);
    error RecallAmountExceeded(uint256 recallId, uint256 instructed, uint256 proven);
    error RecallPending(bytes32 walletKey, uint256 recallId);
    error RecallNotPending(uint256 recallId);
    error PeerChanged(bytes32 chainKey);
    error UnknownResendKind(uint8 kind);
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

    /// @dev What open validations may still draw from `wallet`. The compliance reserves this at issuance and
    ///  gives it back when the validation settles or is discarded. The amount of an open recall is not part of
    ///  it: {availableOf} subtracts both, so `awayBalanceOf - reservedOf` overstates what the wallet can send
    ///  while a recall is open.
    /// @param wallet the satellite wallet, ERC-7930
    function reservedOf(bytes calldata wallet) external view returns (uint256);

    /// @dev What `wallet` can still send: its bridged balance less what open validations may draw from it and
    ///  less the amount of its open recall, from {instructRecall} until the proof settles it. Floors at zero.
    ///  The compliance narrows every new request to this, so none made after a recall draws on tokens being
    ///  recalled. A request that reserved before the recall keeps its reservation, issued or still awaiting
    ///  approval.
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

    /// @dev Sends a message for one half of a move, a `MOVE_OUT` today, to this token's peer on `chainKey` on the
    ///  receipt route, at full finality, and pins `halfKey` to that route and peer at its first send. A half sent
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

    /// @notice Orders the Lite on `wallet`'s chain to burn up to `amount` of `wallet` and prove it under the returned id.
    ///  The proof debits the bridged position and credits `nativeWallet` by what the satellite actually burned, and the
    ///  compliance is told, as a `RECALL`. A forced movement
    ///  of location, never of ownership. One recall at a time per wallet; a lost instruction is sent
    ///  again with {resend}. Only the gateway and the peer the instruction went to may answer it, even after a
    ///  `setPeer`: before replacing a hostile peer, distrust its gateway or drain its open recalls.
    /// @dev Callable by the AccessManager role bound to this selector. Not pause-gated: the instruction moves nothing.
    ///  Reverts with `ZeroValue`, `ZeroAddress`, `WalletsNotLinked` (revoked wallets still resolve),
    ///  `NotASatelliteWallet`, `RecallPending`, `InsufficientBridgedBalance` above the wallet's bridged position, and
    ///  `ChainNotOpen`. The recall is not bounded by the wallet's reservations, so a holder cannot keep a position
    ///  from being recalled by reserving it: a validation that reserved earlier may still execute first, and the
    ///  satellite burns what it still holds and proves that. From here until the proof lands, `amount` is subtracted
    ///  from {availableOf}, so no validation requested from now on draws on it.
    ///  Emits `RecallInstructed` and `ProtocolMessageSent`.
    /// @param wallet the ERC-7930 envelope of the satellite wallet to burn
    /// @param amount the most the satellite may burn
    /// @param nativeWallet the wallet on this chain to credit
    /// @return recallId the id the burn proof must answer with
    function instructRecall(bytes calldata wallet, uint256 amount, address nativeWallet)
        external
        returns (uint256 recallId);

    /// @notice Sends a recall instruction again, byte for byte, under its original id, to the peer it first went to,
    ///  through the chain's current route. Moves nothing on this chain; the Lite acts on each id once.
    ///  `kind` 1, the only kind: a recall still waiting for its proof, `data` = `abi.encode(wallet)`; the gateway
    ///  admitted to answer it becomes the current route.
    /// @dev Callable by the AccessManager role bound to this selector, while paused too. Reverts with
    ///  `RecallNotPending`, `RecallMismatch`, `PeerChanged` when the chain's peer is no longer
    ///  the one addressed, `UnknownResendKind`, and `ChainNotOpen`. Emits `ProtocolMessageSent` and `InstructionResent`.
    /// @return sendId the gateway's id for the resent instruction
    function resend(uint8 kind, uint256 id, bytes calldata data) external returns (bytes32 sendId);

}

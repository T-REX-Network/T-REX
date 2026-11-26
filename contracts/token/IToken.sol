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
import { IReceiptHandler } from "../interop/IReceiptHandler.sol";
import { TokenLedgerLib } from "./TokenLedgerLib.sol";

/// @title IToken
/// @notice The T-REX token surface beyond ERC-3643: the ledger views the standard does not define.
///  A position has three buckets. Free and frozen are native and `balanceOf` is their sum, plain ERC-20.
///  Bridged is the part delegated to satellites, per ERC-7930 wallet, outside `balanceOf`; `totalSupply` counts
///  all three. Inside the bridged bucket, an amount a satellite burned for a cross-chain validation whose mint
///  leg has not landed is held in transit against that validation: no wallet holds it, its sender still owns it.
interface IToken is IERC3643 {

    event ReservedForValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);
    event ReleasedFromValidation(bytes32 indexed walletKey, bytes wallet, uint256 amount);
    event ReturnedInTransit(bytes32 indexed walletKey, bytes32 indexed ticketId, bytes wallet, uint256 amount);
    event HeldInTransit(bytes32 indexed fromKey, bytes32 indexed ticketId, bytes fromWallet, uint256 amount);
    event BridgedTransfer(
        bytes32 indexed fromKey, bytes32 indexed toKey, bytes32 indexed ticketId, bytes from, bytes to, uint256 amount
    );

    event DelegatedOut(
        address indexed holder, bytes32 indexed toKey, uint256 indexed delegationId, bytes toWallet, uint256 amount
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
    error DelegationMismatch(uint256 delegationId);
    error PeerChanged(bytes32 chainKey);
    error UnknownResendKind(uint8 kind);
    error UnverifiedWallet(bytes wallet);
    error NonCanonicalInteroperableAddress(bytes envelope);
    error NotASatelliteWallet(bytes wallet);
    error NothingInTransit(bytes32 ticketId);
    error TransitAlreadyHeld(bytes32 ticketId);
    error TransitAmountMismatch(bytes32 ticketId, uint256 held, uint256 amount);
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

    /// @notice Returns the amount held in transit against a cross-chain validation: its burn leg landed, its mint
    ///  leg has not. Zero once settled, or for a validation that never held anything.
    /// @param ticketId the validation the burn leg consumed
    function onHoldOf(bytes32 ticketId) external view returns (uint256);

    /// @notice Returns the sum of every in-transit hold: the part of `totalAwayBalance` no wallet currently holds.
    function totalOnHold() external view returns (uint256);

    /// @notice Applies a settled validation to the ledger, once, by the shape of its wallets: a native `to` lands
    ///  on that holder's free balance, two satellite wallets are a bridged transfer, both under `ticketId`.
    ///  `from` is always a satellite wallet, the compliance refusing to issue a validation out of a native one, so
    ///  the position a settlement debits is one the executing satellite held all along.
    /// @dev Callable by the bound compliance only, which classified the settlement against the validation it
    ///  issued; reverts with `OnlyBoundCompliance` otherwise. Reverts with `InsufficientBridgedBalance` when
    ///  `from`'s position no longer covers `amount`, which leaves the settlement deliverable again. Reverts
    ///  with `EnforcedPause` while the token is paused, so a halt stops satellite settlements too. Bypasses
    ///  `_update`, like every ledger transition.
    /// @param from the ERC-7930 envelope of the sender, a satellite wallet
    /// @param to the ERC-7930 envelope of the recipient
    /// @param amount the exact amount the satellite executed
    /// @param ticketId the validation the settlement consumed
    function finishMove(bytes calldata from, bytes calldata to, uint256 amount, bytes32 ticketId) external;

    /// @notice Debits `amount` from `from`'s bridged position and holds it in transit against `ticketId`:
    ///  the burn leg of a cross-chain validation landed and proves the satellite burned it, so the wallet must
    ///  not be issued or recalled against it while the mint leg is in flight. `totalAwayBalance` and `totalSupply`
    ///  do not move; the amount is still bridged and still the sender's. `finishMove` for the same id
    ///  later credits the recipient from the hold instead of debiting `from` again.
    /// @dev Callable by the bound compliance only; reverts with `OnlyBoundCompliance` otherwise. Reverts with
    ///  `TransitAlreadyHeld` when the validation already holds an amount, and with `InsufficientBridgedBalance`
    ///  when `from`'s position no longer covers `amount`, which leaves the burn leg deliverable again. Reverts
    ///  with `EnforcedPause` while the token is paused.
    /// @param from the ERC-7930 envelope of the sender, a satellite wallet
    /// @param amount the exact amount the satellite burned
    /// @param ticketId the validation the burn leg consumed
    function putOnHold(bytes calldata from, uint256 amount, bytes32 ticketId, uint256 reserved) external;

    /// @dev Puts the amount held for `ticketId` back on `to`, the satellite wallet it was burned from,
    ///  because the other leg never arrived and the compliance gave up on the pair. Callable by the bound
    ///  compliance alone.
    function returnHeldInTransit(bytes calldata to, bytes32 ticketId) external;

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

    /// @notice Applies a verdict the compliance reached outside a delivery: a leg parked under an id, settled by
    ///  `applyWaitingReceipt` once that id is issued, gets the same brake it would have got at delivery, see
    ///  {IReceiptHandler-Verdict}. Callable by the bound compliance alone.
    /// @param chainKey the chain the judged leg came from
    /// @param verdict what to apply; `None` applies nothing
    function applyVerdict(bytes32 chainKey, IReceiptHandler.Verdict verdict) external;

    /// @dev Sends a compliance validation to this token's peer on `chainKey`. Callable by the bound compliance alone.
    function dispatchComplianceValidation(bytes32 chainKey, bytes32 ticketId, bytes calldata body)
        external
        returns (bytes32);

    /// @notice Moves `amount` of `holder`'s free balance onto `toWallet`, a satellite wallet of the same identity: the
    ///  native balance is burned (`Transfer(holder, 0x0)`), the bridged position credited, `totalSupply` unchanged,
    ///  and a `MOVE_OUT` carrying a fresh delegation id sent to the Lite on `toWallet`'s chain. Location
    ///  moves, ownership does not, so no distribution rule is asked; the compliance is told, as a `DELEGATION`, so
    ///  its ledger follows a registry relink of `holder`. A lost instruction is sent again with {resend}. The way
    ///  back is a validation to a native wallet through the compliance, or an agent's {instructRecall}.
    /// @dev Callable by `holder`, by the identity `holder` is linked to, or by an address the AccessManager authorises
    ///  for this selector; otherwise reverts with `AccessManagedUnauthorized`. Reverts with `EnforcedPause`,
    ///  `FrozenWallet`, `ZeroValue`, `WalletsNotLinked`, `UnverifiedWallet`, `NotASatelliteWallet`,
    ///  `ERC20InsufficientBalance`, `AwayChainBlocked` and `ChainNotOpen`; nothing moves in any of these cases.
    ///  Emits `Transfer`,
    ///  `DelegatedOut` and `ProtocolMessageSent`.
    /// @param holder the native wallet the tokens leave
    /// @param toWallet the ERC-7930 envelope of the satellite wallet to credit
    /// @param amount the amount to delegate
    /// @return sendId the gateway's id for the instruction
    function delegateOut(address holder, bytes calldata toWallet, uint256 amount) external returns (bytes32 sendId);

    /// @notice Orders the Lite on `wallet`'s chain to burn up to `amount` of `wallet` and prove it under the returned id.
    ///  The proof debits the bridged position and credits `nativeWallet` by what the satellite actually burned, and the
    ///  compliance is told, as a `RECALL`, the inverse of the `DELEGATION` it heard on the way out. A forced movement
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

    /// @notice Sends an instruction again, byte for byte, under its original id, to the peer it first went to, through
    ///  the chain's current route. Moves nothing on this chain; the Lite acts on each id once.
    ///  `kind` 0: a delegation, `data` = `abi.encode(toWallet, amount, holder, peer)` as dispatched, checked against
    ///  the commitment stored then. `kind` 1: a recall still waiting for its proof, `data` = `abi.encode(wallet)`;
    ///  the gateway admitted to answer it becomes the current route.
    /// @dev Callable by the AccessManager role bound to this selector, while paused too. Reverts with
    ///  `DelegationMismatch`, `RecallNotPending`, `RecallMismatch`, `PeerChanged` when the chain's peer is no longer
    ///  the one addressed, `UnknownResendKind`, and `ChainNotOpen`. Emits `ProtocolMessageSent` and `InstructionResent`.
    /// @return sendId the gateway's id for the resent instruction
    function resend(uint8 kind, uint256 id, bytes calldata data) external returns (bytes32 sendId);

    /// @notice The recall instruction `recallId` while it waits for its proof; all zeros once settled or never issued.
    function pendingRecall(uint256 recallId) external view returns (TokenLedgerLib.PendingRecall memory);

}

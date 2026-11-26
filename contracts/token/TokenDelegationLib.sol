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
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { ITickets } from "../compliance/modular/ITickets.sol";
import { TREXMessagingLib } from "../interop/TREXMessagingLib.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";
import { TokenLedgerLib } from "./TokenLedgerLib.sol";

/**
 * @title TokenDelegationLib
 * @dev The checks, the bookkeeping and the messages of a recall: an agent's order to an away chain to burn a
 * wallet's position so it comes back to a home wallet of the same identity. Deployed once and linked. A home
 * wallet's move to an away wallet is a ticket of the compliance now, see {SecondHalfLib}.
 *
 * The token reaches this by DELEGATECALL, so the storage is its own `erc3643.storage.TREXToken` namespace, the
 * registry, the compliance and the gateway see the token as their caller, and every event is the token's. The
 * registry and the compliance are read from the token's own getters, so the token passes neither. The native
 * half stays in the token, since it is the ERC-20 balance this library cannot reach: the token mints after
 * {consumeBurnProof}, then reports the recall to the compliance; everything bridged happens here.
 *
 * The instruction is retryable, never written off: {resend} sends it again byte for byte, under the same id, to
 * the same peer, and the Lite acts on each id once. Nothing here checks a caller or the pause: the token's entry
 * points do, before they reach this.
 */
library TokenDelegationLib {

    /// @dev `resend` kind of a recall instruction, the only kind left: a move out is a second half, sent again by
    ///  anyone through the compliance.
    uint8 internal constant RECALL = 1;

    /// @dev Records a recall instruction and sends it. One recall at a time per wallet. The amount is bounded by the
    ///  wallet's bridged position so the proof that answers can always apply, and not by its reservations: a
    ///  validation that executes on the satellite first leaves the satellite less to burn, and the proof carries
    ///  what it burned, down to zero. The gateway and the peer it goes to are recorded, and only they may answer.
    ///  The open record is what {TokenLedgerLib-availableOf} subtracts, so validations requested from now on
    ///  cannot draw on the recalled amount.
    /// @return recallId The id the proof must answer with.
    function instructRecall(bytes calldata wallet, uint256 amount, address nativeWallet)
        external
        returns (uint256 recallId)
    {
        require(amount != 0, ErrorsLib.ZeroValue());
        require(nativeWallet != address(0), ErrorsLib.ZeroAddress());
        _requireLinked(nativeWallet, wallet);

        bytes32 walletKey = WalletKeyLib.satelliteKey(wallet);
        TokenLedgerLib.TokenStorage storage s = TokenLedgerLib.layout();
        require(s.openRecall[walletKey] == 0, ErrorsLib.RecallPending(walletKey, s.openRecall[walletKey]));
        uint256 balance = s.awayBalance[walletKey];
        require(amount <= balance, ErrorsLib.InsufficientBridgedBalance(wallet, balance, amount));

        bytes32 chainKey = _chainKeyOf(wallet);
        recallId = ++s.lastRecallId;
        s.recalls[recallId] = TokenLedgerLib.PendingRecall({
            walletKey: walletKey,
            chainKey: chainKey,
            nativeWallet: nativeWallet,
            amount: amount,
            gateway: TREXMessagingLib.layout().receiptRoutes[chainKey],
            peerKey: keccak256(TREXMessagingLib.peerFor(chainKey))
        });
        s.openRecall[walletKey] = recallId;

        emit EventsLib.RecallInstructed(recallId, walletKey, nativeWallet, wallet, amount);

        _sendRecall(chainKey, recallId, wallet, amount, nativeWallet);
    }

    /// @dev Judges an attributed burn proof against the recall it answers, settles that recall, and applies the
    ///  bridged half of the credit.
    ///
    ///  A proof for an open recall must name its wallet and chain and prove at most the instructed amount, or it
    ///  reverts and stays deliverable. The identity link is checked again, then the compliance follows any relink
    ///  of the native wallet before the credit lands, so the wallet's existing balance is attributed to its current
    ///  owner and the credit, already counted in that identity's position as a bridged one, is not migrated with
    ///  it. The proof is recorded, the bridged position debited (`Recalled`), and the token mints the native half
    ///  and reports the `RECALL` to the compliance's trackers. A zero proof settles the same way with nothing to
    ///  move and nothing to report.
    ///
    ///  With no open recall: the very proof that settled it, from the same chain, is a duplicate and changes
    ///  nothing. A different proof for a recall the token issued and settled blocks the chain that sent it on the
    ///  compliance: that chain is at fault. A proof for a recall never issued reverts with `RecallNotPending`:
    ///  nothing stops the token or blocks a chain over an id it does not know. A proof from a blocked away chain
    ///  reverts with `AwayChainBlocked` and stays deliverable.
    /// @return nativeWallet The wallet the token mints to, as the instruction recorded it.
    /// @return amount What the token mints: what the satellite proved it burned, zero when nothing is credited.
    function consumeBurnProof(bytes32 originChainKey, bytes memory body)
        external
        returns (address nativeWallet, uint256 amount)
    {
        _requireAwayChainNotBlocked(originChainKey);
        MessageTypesLib.BurnProof memory proof = MessageTypesLib.decodeBurnProof(body);
        bytes32 proofHash = keccak256(abi.encode(originChainKey, body));

        emit EventsLib.BurnProofReceived(originChainKey, proof.recallId, proof.burnedWallet, proof.amount);

        TokenLedgerLib.TokenStorage storage s = TokenLedgerLib.layout();
        TokenLedgerLib.PendingRecall storage recall = s.recalls[proof.recallId];
        if (recall.amount == 0) {
            if (s.settledProofs[proof.recallId] == proofHash) {
                emit EventsLib.BurnProofDuplicate(proof.recallId, originChainKey);
                return (address(0), 0);
            }
            // A proof for a recall never sent stops nothing: it reverts and stays deliverable at the bridge.
            bool issued = proof.recallId != 0 && proof.recallId <= s.lastRecallId;
            require(issued, ErrorsLib.RecallNotPending(proof.recallId));
            emit EventsLib.ReplayedBurnProof(proof.recallId, originChainKey);
            ITickets(address(_compliance())).blockAwayChain(originChainKey);
            return (address(0), 0);
        }

        require(
            keccak256(proof.burnedWallet) == recall.walletKey && originChainKey == recall.chainKey,
            ErrorsLib.RecallMismatch(proof.recallId)
        );
        require(
            proof.amount <= recall.amount, ErrorsLib.RecallAmountExceeded(proof.recallId, recall.amount, proof.amount)
        );

        nativeWallet = recall.nativeWallet;
        amount = proof.amount;
        bytes32 walletKey = recall.walletKey;
        _requireLinked(nativeWallet, proof.burnedWallet);
        _compliance().syncOwner(nativeWallet);

        delete s.openRecall[walletKey];
        delete s.recalls[proof.recallId];
        s.settledProofs[proof.recallId] = proofHash;

        emit EventsLib.RecallSettled(proof.recallId, originChainKey, amount);

        if (amount != 0) {
            TokenLedgerLib.debitToNative(proof.burnedWallet, nativeWallet, amount);
            emit EventsLib.Recalled(walletKey, nativeWallet, proof.burnedWallet, amount);
        }
    }

    /// @dev Sends a recall instruction again, unchanged, through the chain's current route, to the peer it first went
    ///  to, from its stored record and the `abi.encode(wallet)` the caller supplies, which must be the recorded wallet.
    ///  It is refused once settled, and its admitted gateway moves to the current route, since the Lite answers
    ///  through the gateway that delivered the resend. The chain's peer must still be the one the instruction was
    ///  addressed to: a resend never retargets. Nothing moves on this chain.
    /// @return sendId The gateway's id for the resent instruction.
    function resend(uint8 kind, uint256 id, bytes calldata data) external returns (bytes32 sendId) {
        require(kind == RECALL, ErrorsLib.UnknownResendKind(kind));
        bytes memory wallet = abi.decode(data, (bytes));
        TokenLedgerLib.PendingRecall storage recall = TokenLedgerLib.layout().recalls[id];
        require(recall.amount != 0, ErrorsLib.RecallNotPending(id));
        require(keccak256(wallet) == recall.walletKey, ErrorsLib.RecallMismatch(id));
        bytes32 chainKey = recall.chainKey;
        _requireSamePeer(chainKey, recall.peerKey);
        recall.gateway = TREXMessagingLib.layout().receiptRoutes[chainKey];
        sendId = _sendRecall(chainKey, id, wallet, recall.amount, recall.nativeWallet);

        emit EventsLib.InstructionResent(kind, id, chainKey, sendId);
    }

    /// @dev Both wallets must resolve to one existing identity. Attribution, not admission: a revoked wallet
    ///  still resolves, since a recall is how a revoked position comes home.
    function _requireLinked(address nativeWallet, bytes memory wallet) private view {
        ITREXRegistry registry = _registry();
        address identity = address(registry.identity(nativeWallet));
        require(
            identity != address(0) && identity == address(registry.resolveIdentity(wallet)),
            ErrorsLib.WalletsNotLinked(nativeWallet, wallet)
        );
    }

    /// @dev The token's registry, through its own getter: run by DELEGATECALL, `address(this)` is the token.
    function _registry() private view returns (ITREXRegistry) {
        return ITREXRegistry(address(IERC3643(address(this)).identityRegistry()));
    }

    /// @dev A blocked away chain is the compliance's: none of its proofs lands.
    function _requireAwayChainNotBlocked(bytes32 chainKey) private view {
        bool blocked = ITickets(address(_compliance())).isAwayChainBlocked(chainKey);
        require(!blocked, ErrorsLib.AwayChainBlocked(chainKey));
    }

    /// @dev The token's compliance, through its own getter.
    function _compliance() private view returns (IModularCompliance) {
        return IModularCompliance(address(IERC3643(address(this)).compliance()));
    }

    function _requireSamePeer(bytes32 chainKey, bytes32 peerKey) private view {
        require(keccak256(TREXMessagingLib.peerFor(chainKey)) == peerKey, ErrorsLib.PeerChanged(chainKey));
    }

    function _sendRecall(bytes32 chainKey, uint256 recallId, bytes memory wallet, uint256 amount, address nativeWallet)
        private
        returns (bytes32)
    {
        return TREXMessagingLib.sendMessage(
            chainKey,
            MessageTypesLib.Message.BRING_HOME,
            abi.encode(
                MessageTypesLib.BringHomeMessage({
                    recallId: recallId, wallet: wallet, amount: amount, nativeWallet: nativeWallet
                })
            )
        );
    }

    function _chainKeyOf(bytes memory wallet) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) = WalletKeyLib.parse(wallet);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}

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

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { MovementKindLib } from "../compliance/modular/MovementKindLib.sol";
import { ISettlementHandler } from "../interop/ISettlementHandler.sol";
import { TREXMessagingLib } from "../interop/TREXMessagingLib.sol";
import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { MessageTypesLib } from "../libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "../libraries/WalletKeyLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";
import { TokenLedgerLib } from "./TokenLedgerLib.sol";

/**
 * @title TokenDelegationLib
 * @dev The checks, the bookkeeping and the messages of the two movements that change a position's location and
 * never its owner: a delegation-out, native wallet to satellite wallet of one identity, and a recall, the way
 * back. Deployed once and linked.
 *
 * The token reaches this by DELEGATECALL, so the storage is its own `erc3643.storage.TREXToken` namespace, the
 * registry, the compliance and the gateway see the token as their caller, and every event is the token's. The
 * registry and the compliance are read from the token's own getters, so the token passes neither. The native
 * half of each movement stays in the token, since it is the ERC-20 balance this library cannot reach: the token
 * burns before {delegateOut} and mints after {consumeBurnProof}; everything bridged happens here.
 *
 * Both instructions are retryable, never written off: {resend} sends an instruction again byte for byte, under
 * the same id, to the same peer, and the Lite acts on each id once. Nothing here checks a caller or the pause:
 * the token's entry points do, before they reach this.
 */
library TokenDelegationLib {

    /// @dev `resend` kind of a delegation's mint instruction.
    uint8 internal constant DELEGATION = 0;

    /// @dev `resend` kind of a recall instruction.
    uint8 internal constant RECALL = 1;

    /// @dev The rest of a delegation-out, once the token has burned `amount` of `holder`'s native balance: the burn
    ///  stayed inside the free balance, the bridged position of `toWallet` is credited under a fresh delegation id
    ///  (`DelegatedOut`), both wallets sit on one identity, the registry admits the recipient, the compliance is told,
    ///  the instruction is committed and sent. Any refusal reverts the burn with it, so nothing is delegated that the
    ///  satellite is not told to mint.
    /// @return sendId The gateway's id for the instruction.
    function delegateOut(address holder, bytes calldata toWallet, uint256 amount) external returns (bytes32 sendId) {
        uint256 delegationId = _creditDelegation(holder, toWallet, amount);

        _requireLinked(holder, toWallet);
        require(_registry().isWalletVerified(toWallet), ErrorsLib.UnverifiedWallet(toWallet));

        _compliance().agentTransferred(holder, holder, amount, MovementKindLib.DELEGATION);

        bytes32 chainKey = _chainKeyOf(toWallet);
        TokenLedgerLib.layout().delegations[delegationId] =
            _commitment(chainKey, keccak256(TREXMessagingLib.peerFor(chainKey)), toWallet, amount, holder);

        return _sendMint(chainKey, delegationId, toWallet, amount, holder);
    }

    /// @dev The bridged half of a delegation-out, through the ledger's own transition: the token already burned, so
    ///  the free balance before the burn is what it holds now plus `amount`, less what is frozen. Then the delegation
    ///  takes the next id.
    function _creditDelegation(address holder, bytes calldata toWallet, uint256 amount)
        private
        returns (uint256 delegationId)
    {
        require(amount != 0, ErrorsLib.ZeroValue());
        IERC3643 token = IERC3643(address(this));
        uint256 freeBefore = token.balanceOf(holder) + amount - token.getFrozenTokens(holder);
        bytes32 toKey = TokenLedgerLib.creditFromNative(holder, toWallet, amount, freeBefore);
        delegationId = ++TokenLedgerLib.layout().lastDelegationId;

        emit EventsLib.DelegatedOut(holder, toKey, delegationId, toWallet, amount);
    }

    /// @dev Records a recall instruction and sends it. One recall at a time per wallet. The amount is bounded by the
    ///  wallet's bridged position so the proof that answers can always apply, and not by its reservations: a
    ///  validation that executes on the satellite first leaves the satellite less to burn, and the proof carries
    ///  what it burned, down to zero. The gateway and the peer it goes to are recorded, and only they may answer.
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
        uint256 balance = s.bridgedBalance[walletKey];
        require(amount <= balance, ErrorsLib.InsufficientBridgedBalance(wallet, balance, amount));

        bytes32 chainKey = _chainKeyOf(wallet);
        recallId = ++s.lastRecallId;
        s.recalls[recallId] = TokenLedgerLib.PendingRecall({
            walletKey: walletKey,
            chainKey: chainKey,
            nativeWallet: nativeWallet,
            amount: amount,
            gateway: TREXMessagingLib.layout().routes[chainKey],
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
    ///  it. The proof is recorded, the bridged position debited (`Recalled`), and the token mints the native half.
    ///  A zero proof settles the same way with nothing to move.
    ///
    ///  With no open recall: the very proof that settled it, from the same chain, is a duplicate and changes
    ///  nothing; anything else is a message the token cannot account for, judged as a replayed settlement is. A
    ///  different proof for a recall the token issued and settled is `PauseChain`: the chain that sent it is at
    ///  fault. A proof for a recall never issued is `HaltToken`.
    /// @return verdict `Applied` when the proof settled its recall or duplicated the one that did; else the pause.
    /// @return nativeWallet The wallet the token mints to, as the instruction recorded it.
    /// @return amount What the token mints: what the satellite proved it burned, zero when nothing is credited.
    function consumeBurnProof(bytes32 originChainKey, bytes memory body)
        external
        returns (ISettlementHandler.Verdict verdict, address nativeWallet, uint256 amount)
    {
        MessageTypesLib.BurnProof memory proof = MessageTypesLib.decodeBurnProof(body);
        bytes32 proofHash = keccak256(abi.encode(originChainKey, body));

        emit EventsLib.BurnProofReceived(originChainKey, proof.recallId, proof.burnedWallet, proof.amount);

        TokenLedgerLib.TokenStorage storage s = TokenLedgerLib.layout();
        TokenLedgerLib.PendingRecall storage recall = s.recalls[proof.recallId];
        if (recall.amount == 0) {
            if (s.settledProofs[proof.recallId] == proofHash) {
                emit EventsLib.BurnProofDuplicate(proof.recallId, originChainKey);
                return (ISettlementHandler.Verdict.Applied, address(0), 0);
            }
            emit EventsLib.ReplayedBurnProof(proof.recallId, originChainKey);
            bool issued = proof.recallId != 0 && proof.recallId <= s.lastRecallId;
            return
                (issued ? ISettlementHandler.Verdict.PauseChain : ISettlementHandler.Verdict.HaltToken, address(0), 0);
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

    /// @dev Sends an instruction again, unchanged, through the chain's current route, to the peer it first went to.
    ///
    ///  A delegation (`kind` 0) is resent from the fields the caller supplies, `abi.encode(toWallet, amount, holder,
    ///  peer)`, which must hash to the commitment stored at dispatch. A recall (`kind` 1) is resent from its stored
    ///  record and the `abi.encode(wallet)` the caller supplies, which must be the recorded wallet; it is refused
    ///  once settled, and its admitted gateway moves to the current route, since the Lite answers through the
    ///  gateway that delivered the resend. Either way the chain's peer must still be the one the instruction was
    ///  addressed to: a resend never retargets. Nothing moves on this chain.
    /// @return sendId The gateway's id for the resent instruction.
    function resend(uint8 kind, uint256 id, bytes calldata data) external returns (bytes32 sendId) {
        TokenLedgerLib.TokenStorage storage s = TokenLedgerLib.layout();
        bytes32 chainKey;
        if (kind == DELEGATION) {
            (bytes memory toWallet, uint256 amount, address holder, bytes memory peer) =
                abi.decode(data, (bytes, uint256, address, bytes));
            chainKey = _chainKeyOf(toWallet);
            bytes32 committed = s.delegations[id];
            require(
                committed != 0 && committed == _commitment(chainKey, keccak256(peer), toWallet, amount, holder),
                ErrorsLib.DelegationMismatch(id)
            );
            _requireSamePeer(chainKey, keccak256(peer));
            sendId = _sendMint(chainKey, id, toWallet, amount, holder);
        } else if (kind == RECALL) {
            bytes memory wallet = abi.decode(data, (bytes));
            TokenLedgerLib.PendingRecall storage recall = s.recalls[id];
            require(recall.amount != 0, ErrorsLib.RecallNotPending(id));
            require(keccak256(wallet) == recall.walletKey, ErrorsLib.RecallMismatch(id));
            chainKey = recall.chainKey;
            _requireSamePeer(chainKey, recall.peerKey);
            recall.gateway = TREXMessagingLib.layout().routes[chainKey];
            sendId = _sendRecall(chainKey, id, wallet, recall.amount, recall.nativeWallet);
        } else {
            revert ErrorsLib.UnknownResendKind(kind);
        }

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

    /// @dev The token's compliance, through its own getter.
    function _compliance() private view returns (IModularCompliance) {
        return IModularCompliance(address(IERC3643(address(this)).compliance()));
    }

    function _requireSamePeer(bytes32 chainKey, bytes32 peerKey) private view {
        require(keccak256(TREXMessagingLib.peerFor(chainKey)) == peerKey, ErrorsLib.PeerChanged(chainKey));
    }

    function _commitment(bytes32 chainKey, bytes32 peerKey, bytes memory toWallet, uint256 amount, address holder)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(chainKey, peerKey, toWallet, amount, holder));
    }

    function _sendMint(bytes32 chainKey, uint256 delegationId, bytes memory toWallet, uint256 amount, address holder)
        private
        returns (bytes32)
    {
        return TREXMessagingLib.sendMessage(
            chainKey,
            MessageTypesLib.Message.MINT_INSTRUCTION,
            abi.encode(
                MessageTypesLib.MintInstruction({
                    delegationId: delegationId, toWallet: toWallet, amount: amount, holder: holder
                })
            )
        );
    }

    function _sendRecall(bytes32 chainKey, uint256 recallId, bytes memory wallet, uint256 amount, address nativeWallet)
        private
        returns (bytes32)
    {
        return TREXMessagingLib.sendMessage(
            chainKey,
            MessageTypesLib.Message.RECALL_INSTRUCTION,
            abi.encode(
                MessageTypesLib.RecallInstruction({
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

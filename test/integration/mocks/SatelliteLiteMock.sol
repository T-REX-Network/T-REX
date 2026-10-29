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

pragma solidity 0.8.30;

import { IERC7786Recipient } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { ERC7786GatewayMock } from "./ERC7786GatewayMock.sol";

/**
 * @title SatelliteLiteMock
 * @notice A satellite Lite that follows every rule in `docs/satellite-lite.md`, so the reference chain can be run
 *  against the counterpart it assumes.
 *
 * One instance stands in for the Lite of one satellite chain. It receives the token's outbound messages through
 * that chain's `ERC7786GatewayMock`, which the test registers as the token's peer for the chain, and answers through
 * the same gateway. Two Lites talk to each other through the receiving Lite's gateway, under a type code no protocol
 * message uses.
 *
 * What it enforces: only its own gateway delivers (`msg.sender`); the author is the reference token, or the peer
 * Lite for a burn message, at the envelope the loopback gateway presents (it attributes every message to its own
 * chain, so the expected envelopes are built with that chain id); a validation executes once, before its expiry,
 * inside its range, for its wallets, by its sender or its named spender; a mint leg is minted only on the sending
 * Lite's burn message; a mint instruction mints once per `delegationId`, and the same id with other contents is
 * refused; a recall burns once per `recallId`, stores its proof, and answers any repetition with the stored proof.
 */
contract SatelliteLiteMock is IERC7786Recipient {

    error NotTheGateway(address caller);
    error NotTheReferenceToken(bytes sender);
    error NotThePeerLite(bytes sender);
    error AlreadyDelivered(bytes32 receiveId);
    error UnknownValidation(uint256 validationId);
    error ValidationConsumed(uint256 validationId);
    error ValidationExpired(uint256 validationId);
    error AmountOutOfRange(uint256 validationId, uint256 amount);
    error NotTheExecutor(uint256 validationId, address caller);
    error InsufficientBalance(bytes wallet, uint256 balance, uint256 amount);
    error BurnNotReceived(uint256 validationId);
    error AlreadyMinted(uint256 validationId);
    error DelegationConflict(uint256 delegationId);
    error RecallConflict(uint256 recallId);
    error NoStoredProof(uint256 recallId);
    error UnexpectedMessage(uint8 messageType);

    /// @dev A burn message between two Lites. Travels under `LITE_BURN`, outside the protocol's type range.
    struct BurnMessage {
        uint256 validationId;
        bytes to;
        uint256 amount;
    }

    uint8 internal constant LITE_BURN = 0xFF;

    uint256 public immutable chainId;
    address public immutable referenceToken;
    ERC7786GatewayMock public immutable gateway;

    SatelliteLiteMock public peer;
    ERC7786GatewayMock public peerGateway;

    mapping(bytes32 receiveId => bool) public delivered;
    mapping(uint256 validationId => MessageTypesLib.ComplianceValidation) internal _validations;
    mapping(uint256 validationId => bool) public known;
    mapping(uint256 validationId => bool) public consumed;
    mapping(uint256 validationId => uint256) public burnReceived;
    mapping(uint256 validationId => bool) public minted;
    mapping(uint256 delegationId => bytes32) public delegationSeen;
    mapping(uint256 recallId => bytes32) public recallSeen;
    mapping(uint256 recallId => bytes) internal _proofs;
    mapping(uint256 recallId => uint256) public burnedFor;
    mapping(bytes32 walletKey => uint256) internal _balances;

    uint256 public mints;
    uint256 public burns;

    constructor(uint256 chainId_, address referenceToken_, ERC7786GatewayMock gateway_) {
        chainId = chainId_;
        referenceToken = referenceToken_;
        gateway = gateway_;
    }

    /// @notice The Lite this one exchanges burn messages with, and the gateway that carries them to it.
    function setPeer(SatelliteLiteMock peer_, ERC7786GatewayMock peerGateway_) external {
        peer = peer_;
        peerGateway = peerGateway_;
    }

    function balanceOf(bytes memory wallet) external view returns (uint256) {
        return _balances[keccak256(wallet)];
    }

    function validationOf(uint256 validationId) external view returns (MessageTypesLib.ComplianceValidation memory) {
        return _validations[validationId];
    }

    /// @inheritdoc IERC7786Recipient
    function receiveMessage(bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        external
        payable
        returns (bytes4)
    {
        require(msg.sender == address(gateway), NotTheGateway(msg.sender));
        if (receiveId != bytes32(0)) {
            require(!delivered[receiveId], AlreadyDelivered(receiveId));
            delivered[receiveId] = true;
        }

        (uint8 messageType,, bytes memory body) = abi.decode(payload, (uint8, uint8, bytes));
        uint256 seenFrom = gateway.originChainId();

        if (messageType == LITE_BURN) {
            require(_isAuthor(sender, seenFrom, address(peer)), NotThePeerLite(sender));
            _receiveBurn(abi.decode(body, (BurnMessage)));
            return IERC7786Recipient.receiveMessage.selector;
        }

        require(_isAuthor(sender, seenFrom, referenceToken), NotTheReferenceToken(sender));

        if (messageType == uint8(MessageTypesLib.Message.COMPLIANCE_VALIDATION)) {
            MessageTypesLib.ComplianceValidation memory validation = MessageTypesLib.decodeValidation(body);
            _validations[validation.validationId] = validation;
            known[validation.validationId] = true;
        } else if (messageType == uint8(MessageTypesLib.Message.MINT_INSTRUCTION)) {
            _mint(MessageTypesLib.decodeMintInstruction(body), keccak256(body));
        } else if (messageType == uint8(MessageTypesLib.Message.RECALL_INSTRUCTION)) {
            _recall(MessageTypesLib.decodeRecallInstruction(body), keccak256(body));
        } else {
            revert UnexpectedMessage(messageType);
        }

        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice The satellite user executes `validationId` for `amount`: the sender, or the named spender.
    function execute(uint256 validationId, uint256 amount) external {
        require(known[validationId], UnknownValidation(validationId));
        require(!consumed[validationId], ValidationConsumed(validationId));
        MessageTypesLib.ComplianceValidation storage validation = _validations[validationId];
        require(block.timestamp < validation.expiry, ValidationExpired(validationId));
        require(
            validation.amountMin <= amount && amount <= validation.amountMax, AmountOutOfRange(validationId, amount)
        );
        require(_isExecutor(validation), NotTheExecutor(validationId, msg.sender));
        consumed[validationId] = true;

        _debit(validation.from, amount);

        (bool toIsEvm, uint256 toChainId,) = InteroperableAddress.tryParseEvmV1(validation.to);
        bool twoLegs = toIsEvm && toChainId != chainId && toChainId != block.chainid;
        if (!twoLegs) {
            if (toChainId == chainId) _balances[keccak256(validation.to)] += amount;
            _report(validationId, validation.from, validation.to, amount);
            return;
        }

        _report(validationId, validation.from, "", amount);
        peerGateway.sendMessage(
            InteroperableAddress.formatEvmV1(block.chainid, address(peer)),
            abi.encode(
                LITE_BURN, MessageTypesLib.VERSION, abi.encode(BurnMessage(validationId, validation.to, amount))
            ),
            new bytes[](0)
        );
    }

    /// @notice What a Lite that ignored the two-leg rule would do: mint from the validation alone. Refused.
    function mintWithoutBurn(uint256 validationId) external view {
        require(known[validationId], UnknownValidation(validationId));
        require(burnReceived[validationId] != 0, BurnNotReceived(validationId));
        revert AlreadyMinted(validationId);
    }

    /// @notice The operator's retry of a proof the reference chain never received: the stored proof, unchanged.
    function resendProof(uint256 recallId) external {
        bytes memory proof = _proofs[recallId];
        require(proof.length != 0, NoStoredProof(recallId));
        _send(proof);
    }

    /* ----- Private ----- */

    /// @dev Once per delegation id; the same id again with the same body is a no-op, with another body a conflict.
    function _mint(MessageTypesLib.MintInstruction memory instruction, bytes32 bodyHash) private {
        bytes32 seen = delegationSeen[instruction.delegationId];
        if (seen == bodyHash) return;
        require(seen == 0, DelegationConflict(instruction.delegationId));
        delegationSeen[instruction.delegationId] = bodyHash;
        _balances[keccak256(instruction.toWallet)] += instruction.amount;
        mints += instruction.amount;
    }

    /// @dev Burn what is there, up to the instruction, once per recall id; store the proof and send it. A repeated
    ///  instruction is answered with the stored proof; another body under the same id is a conflict.
    function _recall(MessageTypesLib.RecallInstruction memory instruction, bytes32 bodyHash) private {
        bytes32 seen = recallSeen[instruction.recallId];
        if (seen == bodyHash) {
            _send(_proofs[instruction.recallId]);
            return;
        }
        require(seen == 0, RecallConflict(instruction.recallId));
        recallSeen[instruction.recallId] = bodyHash;

        bytes32 key = keccak256(instruction.wallet);
        uint256 burned = _balances[key] < instruction.amount ? _balances[key] : instruction.amount;
        _balances[key] -= burned;
        burns += burned;
        burnedFor[instruction.recallId] = burned;

        bytes memory proof = MessageTypesLib.encodeBurnProof(
            MessageTypesLib.BurnProof({
                recallId: instruction.recallId, burnedWallet: instruction.wallet, amount: burned
            })
        );
        _proofs[instruction.recallId] = proof;
        _send(proof);
    }

    /// @dev The receiving half of the two-leg rule: the burn message carries the amount, the mint repeats it.
    function _receiveBurn(BurnMessage memory message) private {
        require(!minted[message.validationId], AlreadyMinted(message.validationId));
        burnReceived[message.validationId] = message.amount;
        minted[message.validationId] = true;
        _balances[keccak256(message.to)] += message.amount;
        _report(message.validationId, "", message.to, message.amount);
    }

    function _report(uint256 validationId, bytes memory from, bytes memory to, uint256 amount) private {
        _send(
            MessageTypesLib.encodeSettlement(
                MessageTypesLib.SettlementNotification({
                    validationId: validationId, from: from, to: to, amount: amount
                })
            )
        );
    }

    function _send(bytes memory payload) private {
        gateway.sendMessage(InteroperableAddress.formatEvmV1(block.chainid, referenceToken), payload, new bytes[](0));
    }

    function _debit(bytes memory wallet, uint256 amount) private {
        bytes32 key = keccak256(wallet);
        require(amount <= _balances[key], InsufficientBalance(wallet, _balances[key], amount));
        _balances[key] -= amount;
    }

    function _isAuthor(bytes calldata sender, uint256 seenFrom, address expected) private pure returns (bool) {
        return keccak256(sender) == keccak256(InteroperableAddress.formatEvmV1(seenFrom, expected));
    }

    function _isExecutor(MessageTypesLib.ComplianceValidation storage validation) private view returns (bool) {
        (,, bytes memory from) = InteroperableAddress.parseV1(validation.from);
        if (address(bytes20(from)) == msg.sender) return true;
        if (validation.spender.length == 0) return false;
        (,, bytes memory spender) = InteroperableAddress.parseV1(validation.spender);
        return address(bytes20(spender)) == msg.sender;
    }

}

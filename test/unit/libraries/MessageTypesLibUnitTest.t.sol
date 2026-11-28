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

import { Test } from "@forge-std/Test.sol";
import { IERC7786Recipient } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev External wrappers, so a revert raised inside the library crosses a call boundary and
///      `vm.expectRevert` can see it.
contract MessageTypesHarness {

    function encode(MessageTypesLib.Message messageType, bytes calldata body) external pure returns (bytes memory) {
        return MessageTypesLib.encode(messageType, body);
    }

    function decode(bytes calldata payload) external pure returns (MessageTypesLib.Message, bytes memory) {
        return MessageTypesLib.decode(payload);
    }

    function decodeSettlement(bytes calldata body) external pure returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.decodeSettlement(body);
    }

    function decodeMintInstruction(bytes calldata body) external pure returns (MessageTypesLib.MoveOutMessage memory) {
        return MessageTypesLib.decodeMintInstruction(body);
    }

    function decodeBringHome(bytes calldata body) external pure returns (MessageTypesLib.BringHomeMessage memory) {
        return MessageTypesLib.decodeBringHome(body);
    }

    function decodeValidation(bytes calldata body) external pure returns (MessageTypesLib.TicketMessage memory) {
        return MessageTypesLib.decodeValidation(body);
    }

}

/// @dev Records what the gateway delivered, so ordering, duplication and loss are observable.
contract RecordingRecipient is IERC7786Recipient {

    bytes32[] public receiveIds;
    bytes[] public senders;
    bytes[] public payloads;

    function receiveMessage(bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        external
        payable
        returns (bytes4)
    {
        receiveIds.push(receiveId);
        senders.push(sender);
        payloads.push(payload);
        return IERC7786Recipient.receiveMessage.selector;
    }

    function callCount() external view returns (uint256) {
        return receiveIds.length;
    }

}

contract MessageTypesLibUnitTest is Test {

    MessageTypesHarness harness;
    ERC7786GatewayMock gateway;
    RecordingRecipient recipient;

    bytes body = abi.encode("a body no transport ever reads", uint256(42));

    function setUp() public {
        harness = new MessageTypesHarness();
        gateway = new ERC7786GatewayMock(block.chainid);
        recipient = new RecordingRecipient();
    }

    /* ----- Envelope codec ----- */

    function testRoundTripPreservesTypeAndBody() public view {
        MessageTypesLib.Message[4] memory types = [
            MessageTypesLib.Message.TICKET,
            MessageTypesLib.Message.MOVE_OUT,
            MessageTypesLib.Message.BRING_HOME,
            MessageTypesLib.Message.RECEIPT
        ];

        for (uint256 i = 0; i < types.length; i++) {
            (MessageTypesLib.Message decodedType, bytes memory decodedBody) =
                harness.decode(harness.encode(types[i], body));

            assertEq(uint8(decodedType), uint8(types[i]));
            assertEq(decodedBody, body);
        }
    }

    /// @dev `encode` needs no such test: an undefined type is a compile error on its parameter.
    function testDecodeRevertsOnUndefinedType(uint8 messageType) public {
        vm.assume(messageType > uint8(type(MessageTypesLib.Message).max));

        bytes memory payload = abi.encode(messageType, MessageTypesLib.VERSION, body);

        vm.expectRevert();
        harness.decode(payload);
    }

    /// @dev The wire codes are the member positions, so a reorder must not pass unnoticed.
    function testMemberNumberingIsTheWireFormat() public pure {
        assertEq(uint8(MessageTypesLib.Message.TICKET), 0);
        assertEq(uint8(MessageTypesLib.Message.MOVE_OUT), 1);
        assertEq(uint8(MessageTypesLib.Message.BRING_HOME), 2);
        assertEq(uint8(MessageTypesLib.Message.RECEIPT), 3);
        assertEq(uint8(type(MessageTypesLib.Message).max), 3);
    }

    /// @dev The bound is inclusive on the valid side, so the refusal above it is not an off-by-one.
    function testHighestMemberDecodesFromARawPayload() public view {
        bytes memory payload = abi.encode(uint8(type(MessageTypesLib.Message).max), MessageTypesLib.VERSION, body);

        (MessageTypesLib.Message messageType, bytes memory decodedBody) = harness.decode(payload);

        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.RECEIPT));
        assertEq(decodedBody, body);
    }

    function testDecodeRevertsOnUnsupportedVersion(uint8 messageVersion) public {
        vm.assume(messageVersion != MessageTypesLib.VERSION);

        bytes memory payload = abi.encode(MessageTypesLib.Message.RECEIPT, messageVersion, body);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, messageVersion));
        harness.decode(payload);
    }

    /// @dev A message in the format before this one, a peer that was not upgraded, is refused instead of decoded
    ///  wrong: its receipt has no ask block hash and no echo of the copy.
    function test_decode_RevertWhen_TheMessageIsVersionOne() public {
        assertEq(MessageTypesLib.VERSION, 2, "this format is version 2");
        uint8 versionOne = 1;
        bytes memory payload = abi.encode(MessageTypesLib.Message.RECEIPT, versionOne, abi.encode(_settlement()));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, versionOne));
        harness.decode(payload);
    }

    /* ----- Typed bodies ----- */

    function testSettlementRoundTrip() public view {
        MessageTypesLib.ReceiptMessage memory receipt = _settlement();

        (MessageTypesLib.Message messageType, bytes memory decodedBody) =
            harness.decode(MessageTypesLib.encodeSettlement(receipt));
        MessageTypesLib.ReceiptMessage memory back = harness.decodeSettlement(decodedBody);

        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.RECEIPT));
        assertEq(back.ticketId, receipt.ticketId);
        assertEq(back.from, receipt.from);
        assertEq(back.to, receipt.to);
        assertEq(back.amount, receipt.amount);
        assertEq(back.askBlockHash, receipt.askBlockHash);
        assertEq(back.seenMax, receipt.seenMax);
        assertEq(back.seenValidUntil, receipt.seenValidUntil);
        assertEq(back.half, receipt.half);
        assertEq(uint8(back.answer), uint8(receipt.answer));
    }

    /// @dev The answer travels as its member position, so a reorder must not pass unnoticed.
    function testReceiptAnswerNumberingIsTheWireFormat() public pure {
        assertEq(uint8(MessageTypesLib.ReceiptAnswer.Executed), 0);
        assertEq(uint8(MessageTypesLib.ReceiptAnswer.Expired), 1);
        assertEq(uint8(MessageTypesLib.ReceiptAnswer.StillOpen), 2);
        assertEq(uint8(type(MessageTypesLib.ReceiptAnswer).max), 2);
    }

    function testMintInstructionRoundTrip() public view {
        MessageTypesLib.MoveOutMessage memory i = MessageTypesLib.MoveOutMessage({
            ticketId: bytes32(uint256(4)),
            half: 1,
            toWallet: hex"0001000001890114",
            amount: 12,
            validUntil: 1_700_000_000
        });

        (MessageTypesLib.Message messageType, bytes memory decodedBody) =
            harness.decode(MessageTypesLib.encode(MessageTypesLib.Message.MOVE_OUT, abi.encode(i)));
        MessageTypesLib.MoveOutMessage memory back = harness.decodeMintInstruction(decodedBody);

        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.MOVE_OUT));
        assertEq(back.ticketId, i.ticketId);
        assertEq(back.half, i.half);
        assertEq(back.toWallet, i.toWallet);
        assertEq(back.amount, i.amount);
        assertEq(back.validUntil, i.validUntil);
    }

    function testBringHomeRoundTrip() public view {
        MessageTypesLib.BringHomeMessage memory i = MessageTypesLib.BringHomeMessage({
            ticketId: bytes32(uint256(3)), half: 2, wallet: hex"0001000001890114", amount: 40, validUntil: 1_700_000_001
        });

        (MessageTypesLib.Message messageType, bytes memory decodedBody) =
            harness.decode(MessageTypesLib.encode(MessageTypesLib.Message.BRING_HOME, abi.encode(i)));
        MessageTypesLib.BringHomeMessage memory back = harness.decodeBringHome(decodedBody);

        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.BRING_HOME));
        assertEq(back.ticketId, i.ticketId);
        assertEq(back.half, i.half);
        assertEq(back.wallet, i.wallet);
        assertEq(back.amount, i.amount);
        assertEq(back.validUntil, i.validUntil);
    }

    function testValidationRoundTrip() public view {
        MessageTypesLib.TicketMessage memory v = _validation(hex"0001000001890114");
        (MessageTypesLib.Message messageType, bytes memory decodedBody) =
            harness.decode(MessageTypesLib.encodeValidation(v));
        MessageTypesLib.TicketMessage memory back = harness.decodeValidation(decodedBody);

        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.TICKET));
        assertEq(back.ticketId, v.ticketId);
        assertEq(back.kind, v.kind, "the kind travels");
        assertEq(back.from, v.from);
        assertEq(back.to, v.to);
        assertEq(back.spender, v.spender);
        assertEq(back.amountMin, v.amountMin);
        assertEq(back.amountMax, v.amountMax);
        assertEq(back.requestedMax, v.requestedMax);
        assertEq(back.token, v.token);
        assertEq(back.validUntil, v.validUntil);
        assertEq(back.askBlockHash, v.askBlockHash);
        assertEq(back.salt, v.salt);
    }

    function testValidationRoundTripPreservesAnEmptySpender() public view {
        MessageTypesLib.TicketMessage memory v = _validation("");
        (, bytes memory decodedBody) = harness.decode(MessageTypesLib.encodeValidation(v));
        MessageTypesLib.TicketMessage memory back = harness.decodeValidation(decodedBody);

        assertEq(back.spender.length, 0);
        assertEq(back.from, v.from);
    }

    function testTypedDecodeRevertsOnAForeignBody() public {
        vm.expectRevert();
        harness.decodeSettlement(hex"deadbeef");

        vm.expectRevert();
        harness.decodeMintInstruction(abi.encode(uint256(1)));

        vm.expectRevert();
        harness.decodeBringHome(hex"deadbeef");

        vm.expectRevert();
        harness.decodeValidation(abi.encode(_settlement()));
    }

    function _validation(bytes memory spender) private pure returns (MessageTypesLib.TicketMessage memory) {
        return MessageTypesLib.TicketMessage({
            ticketId: bytes32(uint256(7)),
            kind: 1,
            salt: bytes32(uint256(5)),
            from: hex"0001000001890114",
            to: hex"00010000010a0114",
            spender: spender,
            amountMin: 9,
            amountMax: 11,
            requestedMax: 12,
            token: address(0xBEEF),
            validUntil: 1_700_000_000,
            askBlockHash: bytes32(uint256(13))
        });
    }

    function _settlement() private pure returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.ReceiptMessage({
            ticketId: bytes32(uint256(7)),
            from: hex"0001000001890114",
            to: "",
            amount: 42,
            askBlockHash: bytes32(uint256(99)),
            seenMax: 50,
            seenValidUntil: 1_700_000_000,
            half: 0,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    /* ----- chainKey ----- */

    function testChainKeyIsStablePerChainPrefix() public pure {
        bytes memory chainRef = hex"01";

        assertEq(MessageTypesLib.chainKey(bytes2(0x0000), chainRef), MessageTypesLib.chainKey(bytes2(0x0000), chainRef));
    }

    /// @dev Derived through the standard's EVM-specific helper, which builds the same identifier by
    /// another path, so agreement is a cross-check rather than a restatement.
    function testChainKeyIsTheCanonicalChainIdentifierHashed() public pure {
        uint256 chainId = 137;

        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));

        assertEq(
            MessageTypesLib.chainKey(chainType, chainReference), keccak256(InteroperableAddress.formatEvmV1(chainId))
        );
    }

    /// @dev A chain identifier needs a reference, so the degenerate key has no value to collide with.
    function testChainKeyRefusesAnEmptyReference() public {
        vm.expectRevert();
        this.callChainKey(MessageTypesLib.EVM_CHAIN_TYPE, "");
    }

    function callChainKey(bytes2 chainType, bytes calldata chainReference) external pure returns (bytes32) {
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

    function testChainKeyDiffersAcrossChains() public pure {
        assertTrue(
            MessageTypesLib.chainKey(bytes2(0x0000), hex"01") != MessageTypesLib.chainKey(bytes2(0x0000), hex"89")
        );
        assertTrue(
            MessageTypesLib.chainKey(bytes2(0x0000), hex"01") != MessageTypesLib.chainKey(bytes2(0x0002), hex"01")
        );
    }

    /* ----- Mock gateway relay controls ----- */

    function testSendQueuesWithoutDelivering() public {
        _send(body);

        assertEq(gateway.queueLength(), 1);
        assertEq(recipient.callCount(), 0);
    }

    function testRelayDeliversTheExactPayloadOnce() public {
        bytes memory payload = MessageTypesLib.encode(MessageTypesLib.Message.TICKET, body);
        _sendRaw(payload);

        gateway.relay(0);

        assertEq(recipient.callCount(), 1);
        assertEq(recipient.payloads(0), payload);
    }

    function testDuplicateRelayDeliversTwiceWithTheSameReceiveId() public {
        _send(body);

        gateway.relay(0);
        gateway.relay(0);

        assertEq(recipient.callCount(), 2);
        assertEq(recipient.receiveIds(0), recipient.receiveIds(1));
    }

    function testDroppedMessageIsNeverDelivered() public {
        _send(body);

        gateway.drop(0);

        vm.expectRevert("ERC7786GatewayMock: dropped");
        gateway.relay(0);

        assertEq(recipient.callCount(), 0);
    }

    /// @dev One mock stands in for one satellite's counterpart gateway, and says so on every delivery.
    function testRelayAttributesTheMessageToTheConfiguredOriginChain() public {
        ERC7786GatewayMock polygon = new ERC7786GatewayMock(137);
        polygon.sendMessage(InteroperableAddress.formatEvmV1(block.chainid, address(recipient)), body, new bytes[](0));

        polygon.relay(0);

        assertEq(recipient.senders(0), InteroperableAddress.formatEvmV1(137, address(this)));
    }

    function testOutOfOrderRelayDeliversInTheRelayedOrder() public {
        bytes memory first = MessageTypesLib.encode(MessageTypesLib.Message.TICKET, abi.encode("first"));
        bytes memory second = MessageTypesLib.encode(MessageTypesLib.Message.MOVE_OUT, abi.encode("second"));
        _sendRaw(first);
        _sendRaw(second);

        gateway.relay(1);
        gateway.relay(0);

        assertEq(recipient.payloads(0), second);
        assertEq(recipient.payloads(1), first);
    }

    function _send(bytes memory messageBody) private {
        _sendRaw(MessageTypesLib.encode(MessageTypesLib.Message.TICKET, messageBody));
    }

    function _sendRaw(bytes memory payload) private {
        gateway.sendMessage(
            InteroperableAddress.formatEvmV1(block.chainid, address(recipient)), payload, new bytes[](0)
        );
    }

}

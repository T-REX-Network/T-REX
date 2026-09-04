// SPDX-License-Identifier: GPL-3.0
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

    function encode(uint8 messageType, bytes calldata body) external pure returns (bytes memory) {
        return MessageTypesLib.encode(messageType, body);
    }

    function decode(bytes calldata payload) external pure returns (uint8, bytes memory) {
        return MessageTypesLib.decode(payload);
    }

    function decodeSettlement(bytes calldata body)
        external
        pure
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return MessageTypesLib.decodeSettlement(body);
    }

    function decodeBurnProof(bytes calldata body) external pure returns (MessageTypesLib.BurnProof memory) {
        return MessageTypesLib.decodeBurnProof(body);
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
        uint8[4] memory types = [
            MessageTypesLib.COMPLIANCE_VALIDATION,
            MessageTypesLib.MINT_INSTRUCTION,
            MessageTypesLib.SETTLEMENT_NOTIFICATION,
            MessageTypesLib.BURN_PROOF
        ];

        for (uint256 i = 0; i < types.length; i++) {
            (uint8 decodedType, bytes memory decodedBody) = harness.decode(harness.encode(types[i], body));

            assertEq(decodedType, types[i]);
            assertEq(decodedBody, body);
        }
    }

    function testEncodeRevertsOnUnknownType(uint8 messageType) public {
        vm.assume(!MessageTypesLib.isKnownType(messageType));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownMessageType.selector, messageType));
        harness.encode(messageType, body);
    }

    function testDecodeRevertsOnUnknownType(uint8 messageType) public {
        vm.assume(!MessageTypesLib.isKnownType(messageType));

        bytes memory payload = abi.encode(messageType, MessageTypesLib.VERSION, body);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownMessageType.selector, messageType));
        harness.decode(payload);
    }

    function testDecodeRevertsOnUnsupportedVersion(uint8 messageVersion) public {
        vm.assume(messageVersion != MessageTypesLib.VERSION);

        bytes memory payload = abi.encode(MessageTypesLib.SETTLEMENT_NOTIFICATION, messageVersion, body);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, messageVersion));
        harness.decode(payload);
    }

    /* ----- Typed bodies ----- */

    function testSettlementRoundTrip() public view {
        MessageTypesLib.SettlementNotification memory n = MessageTypesLib.SettlementNotification({
            validationId: 7, token: address(0xBEEF), from: hex"0001000001890114", to: "", amount: 42
        });

        (uint8 messageType, bytes memory decodedBody) = harness.decode(MessageTypesLib.encodeSettlement(n));
        MessageTypesLib.SettlementNotification memory back = harness.decodeSettlement(decodedBody);

        assertEq(messageType, MessageTypesLib.SETTLEMENT_NOTIFICATION);
        assertEq(back.validationId, n.validationId);
        assertEq(back.token, n.token);
        assertEq(back.from, n.from);
        assertEq(back.to, n.to);
        assertEq(back.amount, n.amount);
    }

    function testBurnProofRoundTrip() public view {
        MessageTypesLib.BurnProof memory p = MessageTypesLib.BurnProof({
            burnedWallet: hex"0001000001890114", amount: 9, nativeWallet: address(0xCAFE)
        });

        (uint8 messageType, bytes memory decodedBody) = harness.decode(MessageTypesLib.encodeBurnProof(p));
        MessageTypesLib.BurnProof memory back = harness.decodeBurnProof(decodedBody);

        assertEq(messageType, MessageTypesLib.BURN_PROOF);
        assertEq(back.burnedWallet, p.burnedWallet);
        assertEq(back.amount, p.amount);
        assertEq(back.nativeWallet, p.nativeWallet);
    }

    function testTypedDecodeRevertsOnAForeignBody() public {
        vm.expectRevert();
        harness.decodeSettlement(hex"deadbeef");

        vm.expectRevert();
        harness.decodeBurnProof(abi.encode(uint256(1)));
    }

    /* ----- chainKey ----- */

    function testChainKeyIsStablePerChainPrefix() public pure {
        bytes memory chainRef = hex"01";

        assertEq(MessageTypesLib.chainKey(bytes2(0x0000), chainRef), MessageTypesLib.chainKey(bytes2(0x0000), chainRef));
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
        bytes memory payload = MessageTypesLib.encode(MessageTypesLib.COMPLIANCE_VALIDATION, body);
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
        bytes memory first = MessageTypesLib.encode(MessageTypesLib.COMPLIANCE_VALIDATION, abi.encode("first"));
        bytes memory second = MessageTypesLib.encode(MessageTypesLib.MINT_INSTRUCTION, abi.encode("second"));
        _sendRaw(first);
        _sendRaw(second);

        gateway.relay(1);
        gateway.relay(0);

        assertEq(recipient.payloads(0), second);
        assertEq(recipient.payloads(1), first);
    }

    function _send(bytes memory messageBody) private {
        _sendRaw(MessageTypesLib.encode(MessageTypesLib.COMPLIANCE_VALIDATION, messageBody));
    }

    function _sendRaw(bytes memory payload) private {
        gateway.sendMessage(
            InteroperableAddress.formatEvmV1(block.chainid, address(recipient)), payload, new bytes[](0)
        );
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ISettlementHandler } from "contracts/interop/ISettlementHandler.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

contract InboundMessagingTest is InteropSuiteTest {

    ERC7786GatewayMock routedGateway;
    ERC7786GatewayMock otherTrustedGateway;
    ERC7786GatewayMock untrustedGateway;

    address impostor = makeAddr("Impostor");

    address compliance;

    bytes32 originChain = polygon;

    bytes32 validationId;
    uint256 amount = 500;
    bytes satelliteFrom;
    bytes satelliteTo;

    function setUp() public override {
        super.setUp();

        routedGateway = _newTrustedGateway(POLYGON);
        otherTrustedGateway = _newTrustedGateway(POLYGON);
        untrustedGateway = new ERC7786GatewayMock(POLYGON);

        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(routedGateway));

        // A never-issued id is parked and pauses its chain's inbound, so the transport cases below run on a real
        // one, which settles for good.
        vm.prank(agent);
        token.unpause();
        satelliteFrom = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), 1000);
        satelliteTo = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        validationId = _requestValidation(address(aliceIdentity), satelliteFrom, satelliteTo, 1, amount);
    }

    function _issuedSettlement() private view returns (MessageTypesLib.SettlementNotification memory) {
        return _settlement(validationId, satelliteFrom, satelliteTo, amount);
    }

    function _settlementPayload() private view returns (bytes memory) {
        return MessageTypesLib.encodeSettlement(_issuedSettlement());
    }

    function _peerSendsSettlement() private returns (uint256) {
        return _liteSends(routedGateway, token, _settlementPayload());
    }

    function _expectSettlementNotified(MessageTypesLib.SettlementNotification memory n) private {
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementNotified(originChain, n.validationId, n.from, n.to, n.amount);
    }

    /// @dev A refusal rolls the whole delivery back, so the token never records having seen it.
    function _assertNothingApplied(ERC7786GatewayMock gateway, uint256 index) private view {
        assertFalse(token.messageReceived(address(gateway), gateway.receiveIdFor(index)));
    }

    /* ----- Settlement delivery: one leg, two legs ----- */

    /// @dev Same-chain transfer: one notification with real `from` and `to`, forwarded as decoded and settled.
    function testOneLegSettlementReachesTheBoundComplianceIntact() public {
        MessageTypesLib.SettlementNotification memory n = _issuedSettlement();
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(n));

        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (originChain, n)));
        _expectSettlementNotified(n);

        routedGateway.relay(index);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(index)));
        assertEq(token.bridgedBalanceOf(satelliteTo), amount);
        assertFalse(token.paused());
    }

    /// @dev Cross-chain transfer: a burn leg from one chain and a mint leg from another, under one id. Each
    ///      arrives through its own chain's gateway and each reaches the compliance on its own, in any order.
    ///      The id was never issued here, so each leg is parked under its own chain and that chain's inbound
    ///      pauses; the token itself stays open, and the first leg's pause does not hold the other chain's back.
    function testTwoLegSettlementDeliversBothLegsUnderOneId() public {
        ERC7786GatewayMock optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        bytes32 neverIssued = bytes32(uint256(validationId) + 1);

        bytes memory from = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From"));
        bytes memory to = InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("To"));

        MessageTypesLib.SettlementNotification memory burnLeg = _settlement(neverIssued, from, "", amount);
        MessageTypesLib.SettlementNotification memory mintLeg = _settlement(neverIssued, "", to, amount);

        uint256 burnIndex = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(burnLeg));
        uint256 mintIndex = _liteSends(optimismGateway, token, MessageTypesLib.encodeSettlement(mintLeg));

        // The mint leg lands first: the transport imposes no ordering, the lifecycle does.
        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (optimism, mintLeg)));
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementNotified(optimism, neverIssued, "", to, amount);
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementParked(neverIssued, optimism, amount, mintLeg.hash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(optimism);
        optimismGateway.relay(mintIndex);

        assertTrue(token.messageReceived(address(optimismGateway), optimismGateway.receiveIdFor(mintIndex)));
        assertTrue(token.isInboundPaused(optimism));
        assertFalse(token.isInboundPaused(polygon), "the other chain is not held back");
        assertFalse(token.paused());

        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (polygon, burnLeg)));
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementNotified(polygon, neverIssued, from, "", amount);
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementParked(neverIssued, polygon, amount, burnLeg.hash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        routedGateway.relay(burnIndex);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(burnIndex)));
        ITransferValidation.ParkedLeg memory parkedMint = boundCompliance.parkedLegOf(neverIssued, optimism);
        ITransferValidation.ParkedLeg memory parkedBurn = boundCompliance.parkedLegOf(neverIssued, polygon);
        assertTrue(parkedMint.exists);
        assertEq(parkedMint.to, to);
        assertTrue(parkedBurn.exists);
        assertEq(parkedBurn.from, from);
        assertTrue(token.isInboundPaused(optimism));
        assertTrue(token.isInboundPaused(polygon));
        assertFalse(token.paused());
    }

    /// @dev One side on the reference chain: a single leg, from the one satellite involved, reaches the
    ///      compliance intact.
    function testSingleLegSettlementWhenOneSideIsTheReferenceChain() public {
        MessageTypesLib.SettlementNotification memory leg = _settlement(
            validationId,
            InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From")),
            InteroperableAddress.formatEvmV1(block.chainid, makeAddr("NativeTo")),
            amount
        );
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(leg));

        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (originChain, leg)), 1);
        // Not the issued wallets, under the issued hash: the compliance rejects the leg and pauses the chain
        // that reported it. The delivery is consumed, nothing applied, the validation untouched.
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementRejected(validationId, originChain, amount, leg.hash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(originChain);
        routedGateway.relay(index);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(index)));
        assertTrue(token.isInboundPaused(originChain));
        assertFalse(token.paused());
        assertEq(token.bridgedBalanceOf(satelliteTo), 0);
        assertEq(uint8(boundCompliance.statusOf(validationId)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function testReceiveIsAnnounced() public {
        uint256 index = _peerSendsSettlement();

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageReceived(
            MessageTypesLib.Message.SETTLEMENT_NOTIFICATION, originChain, routedGateway.receiveIdFor(index)
        );

        routedGateway.relay(index);
    }

    /// @dev The compliance's entry point belongs to the token alone.
    function testOnlyTheBoundTokenMayHandASettlementToTheCompliance() public {
        MessageTypesLib.SettlementNotification memory n = _issuedSettlement();

        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        vm.prank(impostor);
        ISettlementHandler(compliance).handleSettlement(originChain, n);
    }

    /* ----- Burn proof: the recall path ----- */

    /// @dev The proof reaches the recall path with every field intact and credits the instructed wallet; the
    ///      settlement handler never sees it.
    function testBurnProofReachesTheRecallPathIntact() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        uint256 index =
            _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100)));
        uint256 nativeBefore = token.balanceOf(alice);

        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 0);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofReceived(originChain, recallId, satelliteFrom, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.RecallSettled(recallId, originChain, 100);
        routedGateway.relay(index);

        assertEq(token.balanceOf(alice), nativeBefore + 100);
        assertEq(token.bridgedBalanceOf(satelliteFrom), 900);
    }

    /// @dev A proof answering a recall this token never issued is the never-issued emergency: nothing moves and
    ///      the token pauses itself.
    function testBurnProofForANeverIssuedRecallHaltsTheToken() public {
        uint256 index =
            _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(99, satelliteFrom, amount)));
        uint256 nativeBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ReplayedBurnProof(99, originChain);
        routedGateway.relay(index);

        assertTrue(token.paused());
        assertEq(token.balanceOf(alice), nativeBefore);
        assertEq(token.bridgedBalanceOf(satelliteFrom), 1000);
    }

    /* ----- Outbound-only types have no inbound handler ----- */

    function testOutboundOnlyTypesAreRefusedInbound() public {
        bytes memory body = abi.encode(uint256(1), "not for us");

        uint256 validation = _liteSends(
            routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.COMPLIANCE_VALIDATION, body)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.COMPLIANCE_VALIDATION
            )
        );
        routedGateway.relay(validation);

        uint256 mint =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.MINT_INSTRUCTION, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.MINT_INSTRUCTION)
        );
        routedGateway.relay(mint);

        uint256 recall =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.RECALL_INSTRUCTION, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.Message.RECALL_INSTRUCTION)
        );
        routedGateway.relay(recall);
    }

    /* ----- The rejection matrix: three trust levels, three errors ----- */

    function testUntrustedGatewayIsRefused() public {
        uint256 index = _liteSends(untrustedGateway, token, _settlementPayload());

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(untrustedGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        untrustedGateway.relay(index);

        _assertNothingApplied(untrustedGateway, index);
    }

    /// @dev The issued validation is pinned to the routed gateway, so an unpinned id is what exercises the
    ///      current-route check.
    function testTrustedButUnroutedGatewayIsRefused() public {
        bytes memory unpinned = MessageTypesLib.encodeSettlement(
            _settlement(bytes32(uint256(validationId) + 1), satelliteFrom, satelliteTo, amount)
        );
        uint256 index = _liteSends(otherTrustedGateway, token, unpinned);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.GatewayNotRouted.selector, address(otherTrustedGateway), originChain)
        );
        otherTrustedGateway.relay(index);

        _assertNothingApplied(otherTrustedGateway, index);
    }

    function testNonPeerAuthorIsRefusedThroughTheRightGateway() public {
        uint256 index = _queue(routedGateway, impostor, token, _settlementPayload());

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, originChain, InteroperableAddress.formatEvmV1(POLYGON, impostor)
            )
        );
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /// @dev The token's own address, but on a chain the issuer never opened: not a peer either.
    function testTheTokensAddressOnAnUnopenedChainIsNotAPeer() public {
        ERC7786GatewayMock strangerChain = _newTrustedGateway(OPTIMISM);
        uint256 index = _liteSends(strangerChain, token, _settlementPayload());

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.SenderNotPeer.selector, optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(token))
            )
        );
        strangerChain.relay(index);
    }

    /* ----- Replay: transport versus semantic ----- */

    function testTransportReplayIsRefused() public {
        uint256 index = _peerSendsSettlement();

        routedGateway.relay(index);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.MessageAlreadyReceived.selector, address(routedGateway), routedGateway.receiveIdFor(index)
            )
        );
        routedGateway.relay(index);

        assertEq(routedGateway.queuedMessage(index).deliveries, 1, "delivered once");
    }

    /// @dev A fresh receiveId carrying already-consumed content is the slot lifecycle's problem, not
    ///      this layer's: both deliveries reach the compliance, which is what lets it raise its emergency.
    function testSemanticRedeliveryIsPassedThroughUntouched() public {
        uint256 first = _peerSendsSettlement();
        uint256 second = _peerSendsSettlement();
        assertTrue(routedGateway.receiveIdFor(first) != routedGateway.receiveIdFor(second));

        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 2);
        routedGateway.relay(first);

        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.ReplayedSettlement(validationId, originChain);
        routedGateway.relay(second);

        assertTrue(token.isInboundPaused(originChain), "the emergency pauses the chain's inbound");
        assertFalse(token.paused(), "and nothing else");
        assertEq(token.bridgedBalanceOf(satelliteTo), amount, "applied once");
    }

    /// @dev A paused chain's messages, settlements and burn proofs alike, are refused after attribution and before
    ///      any handler, so nothing is recorded and the same deliveries land once the pauser lifts the pause.
    function testInboundPausedChainRefusesEveryMessageAndKeepsItDeliverable() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(satelliteFrom, 100, alice);
        uint256 settlement = _peerSendsSettlement();
        uint256 proof =
            _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(_burnProof(recallId, satelliteFrom, 100)));
        uint256 nativeBefore = token.balanceOf(alice);
        vm.prank(agent);
        token.setInboundPaused(originChain, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, originChain));
        routedGateway.relay(settlement);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, originChain));
        routedGateway.relay(proof);
        _assertNothingApplied(routedGateway, settlement);
        _assertNothingApplied(routedGateway, proof);
        assertTrue(token.isChainOpen(originChain), "outbound is not gated");
        assertFalse(token.paused());

        vm.prank(agent);
        token.setInboundPaused(originChain, false);
        routedGateway.relay(settlement);
        routedGateway.relay(proof);

        assertEq(token.bridgedBalanceOf(satelliteTo), amount);
        assertEq(token.balanceOf(alice), nativeBefore + 100);
    }

    /* ----- Envelope refusals ----- */

    /// @dev The refusal carries no data, so what is asserted is that it lands before any handler and
    /// leaves the receipt unrecorded, letting a corrected message follow.
    function testUndefinedMessageTypeReachesNoHandler() public {
        uint8 undefinedType = uint8(type(MessageTypesLib.Message).max) + 1;
        uint256 index = _liteSends(routedGateway, token, abi.encode(undefinedType, MessageTypesLib.VERSION, "x"));

        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 0);

        vm.expectRevert();
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    function testUnsupportedVersionReachesNoHandler() public {
        uint8 futureVersion = 2;
        uint256 index = _liteSends(
            routedGateway, token, abi.encode(MessageTypesLib.Message.SETTLEMENT_NOTIFICATION, futureVersion, "x")
        );

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, futureVersion));
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /// @dev A well-typed envelope around a body that is not a settlement never reaches the compliance.
    function testMalformedSettlementBodyIsRefused() public {
        uint256 index = _liteSends(
            routedGateway, token, MessageTypesLib.encode(MessageTypesLib.Message.SETTLEMENT_NOTIFICATION, hex"deadbeef")
        );

        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 0);
        vm.expectRevert();
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /* ----- Teardown: the emergency lever closes the door both ways ----- */

    function testUntrustingTheGatewayStopsInboundToo() public {
        uint256 index = _peerSendsSettlement();

        trustedGatewayRegistry.setTrustedGateway(address(routedGateway), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC7786Recipient.ERC7786RecipientUnauthorizedGateway.selector,
                address(routedGateway),
                InteroperableAddress.formatEvmV1(POLYGON, address(token))
            )
        );
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

}

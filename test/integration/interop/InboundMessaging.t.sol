// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ERC7786Recipient } from "@openzeppelin/contracts/crosschain/ERC7786Recipient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

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
    address holder = makeAddr("Holder");

    address compliance;

    bytes32 originChain = polygon;

    uint256 validationId = 7;
    uint256 amount = 500;

    function setUp() public override {
        super.setUp();

        routedGateway = _newTrustedGateway(POLYGON);
        otherTrustedGateway = _newTrustedGateway(POLYGON);
        untrustedGateway = new ERC7786GatewayMock(POLYGON);

        compliance = address(token.compliance());

        _openEvmChain(token, POLYGON, address(routedGateway));
    }

    function _settlementPayload() private returns (bytes memory) {
        return MessageTypesLib.encodeSettlement(_sameChainSettlement(validationId, token, POLYGON, amount));
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

    /// @dev Same-chain transfer: one notification with real `from` and `to`, forwarded as decoded.
    function testOneLegSettlementReachesTheBoundComplianceIntact() public {
        MessageTypesLib.SettlementNotification memory n = _sameChainSettlement(validationId, token, POLYGON, amount);
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(n));

        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (originChain, n)));
        _expectSettlementNotified(n);

        routedGateway.relay(index);

        assertTrue(token.messageReceived(address(routedGateway), routedGateway.receiveIdFor(index)));
    }

    /// @dev Cross-chain transfer: a burn leg from one chain and a mint leg from another, under one id.
    ///      Each arrives through its own chain's gateway and each reaches the compliance on its own.
    function testTwoLegSettlementDeliversBothLegsUnderOneId() public {
        ERC7786GatewayMock optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        bytes memory from = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From"));
        bytes memory to = InteroperableAddress.formatEvmV1(OPTIMISM, makeAddr("To"));

        MessageTypesLib.SettlementNotification memory burnLeg = _settlement(validationId, token, from, "", amount);
        MessageTypesLib.SettlementNotification memory mintLeg = _settlement(validationId, token, "", to, amount);

        uint256 burnIndex = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(burnLeg));
        uint256 mintIndex = _liteSends(optimismGateway, token, MessageTypesLib.encodeSettlement(mintLeg));

        // The mint leg lands first: the transport imposes no ordering, the lifecycle does.
        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (optimism, mintLeg)));
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementNotified(optimism, validationId, "", to, amount);
        optimismGateway.relay(mintIndex);

        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (polygon, burnLeg)));
        vm.expectEmit(true, true, false, true, compliance);
        emit EventsLib.SettlementNotified(polygon, validationId, from, "", amount);
        routedGateway.relay(burnIndex);
    }

    /// @dev One side on the reference chain: a single leg, from the one satellite involved.
    function testSingleLegSettlementWhenOneSideIsTheReferenceChain() public {
        MessageTypesLib.SettlementNotification memory leg = _settlement(
            validationId,
            token,
            InteroperableAddress.formatEvmV1(POLYGON, makeAddr("From")),
            InteroperableAddress.formatEvmV1(block.chainid, makeAddr("NativeTo")),
            amount
        );
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeSettlement(leg));

        vm.expectCall(compliance, abi.encodeCall(ISettlementHandler.handleSettlement, (originChain, leg)), 1);
        routedGateway.relay(index);
    }

    function testReceiveIsAnnounced() public {
        uint256 index = _peerSendsSettlement();

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ProtocolMessageReceived(
            MessageTypesLib.SETTLEMENT_NOTIFICATION, originChain, routedGateway.receiveIdFor(index)
        );

        routedGateway.relay(index);
    }

    /// @dev The compliance's entry point belongs to the token alone.
    function testOnlyTheBoundTokenMayHandASettlementToTheCompliance() public {
        MessageTypesLib.SettlementNotification memory n = _sameChainSettlement(validationId, token, POLYGON, amount);

        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        vm.prank(impostor);
        ISettlementHandler(compliance).handleSettlement(originChain, n);
    }

    /* ----- Burn proof: the recall path ----- */

    /// @dev The proof reaches the recall path with every field intact, and the compliance never sees it.
    function testBurnProofReachesTheRecallPathWithItsDestinationWalletIntact() public {
        address burned = makeAddr("BurnedSatelliteWallet");
        MessageTypesLib.BurnProof memory proof = _burnProof(POLYGON, burned, amount, holder);
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(proof));

        vm.expectCall(compliance, abi.encodeWithSelector(ISettlementHandler.handleSettlement.selector), 0);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofReceived(originChain, InteroperableAddress.formatEvmV1(POLYGON, burned), holder, amount);

        routedGateway.relay(index);
    }

    function testBurnProofWithNoDestinationWalletIsRefused() public {
        MessageTypesLib.BurnProof memory proof = _burnProof(POLYGON, makeAddr("Burned"), amount, address(0));
        uint256 index = _liteSends(routedGateway, token, MessageTypesLib.encodeBurnProof(proof));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /* ----- Outbound-only types have no inbound handler ----- */

    function testOutboundOnlyTypesAreRefusedInbound() public {
        bytes memory body = abi.encode(uint256(1), "not for us");

        uint256 validation =
            _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.COMPLIANCE_VALIDATION, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.COMPLIANCE_VALIDATION)
        );
        routedGateway.relay(validation);

        uint256 mint = _liteSends(routedGateway, token, MessageTypesLib.encode(MessageTypesLib.MINT_INSTRUCTION, body));

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.MessageTypeNotInbound.selector, MessageTypesLib.MINT_INSTRUCTION)
        );
        routedGateway.relay(mint);
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

    function testTrustedButUnroutedGatewayIsRefused() public {
        uint256 index = _liteSends(otherTrustedGateway, token, _settlementPayload());

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
        routedGateway.relay(second);
    }

    /* ----- Envelope refusals ----- */

    function testUnknownMessageTypeReachesNoHandler() public {
        uint8 undefinedType = 9;
        uint256 index = _liteSends(routedGateway, token, abi.encode(undefinedType, MessageTypesLib.VERSION, "x"));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownMessageType.selector, undefinedType));
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    function testUnsupportedVersionReachesNoHandler() public {
        uint8 futureVersion = 2;
        uint256 index =
            _liteSends(routedGateway, token, abi.encode(MessageTypesLib.SETTLEMENT_NOTIFICATION, futureVersion, "x"));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedMessageVersion.selector, futureVersion));
        routedGateway.relay(index);

        _assertNothingApplied(routedGateway, index);
    }

    /// @dev A well-typed envelope around a body that is not a settlement never reaches the compliance.
    function testMalformedSettlementBodyIsRefused() public {
        uint256 index = _liteSends(
            routedGateway, token, MessageTypesLib.encode(MessageTypesLib.SETTLEMENT_NOTIFICATION, hex"deadbeef")
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

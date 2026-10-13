// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev The reference chain run against Lites that follow `docs/satellite-lite.md`: every inbound message is produced
///      by a Lite acting on what the token sent it, never hand-built. Each gateway mock carries both directions of one
///      chain and is the token's route there; each Lite is the token's registered peer.
contract LiteDrivenSettlementTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;
    uint256 internal constant DELEGATED = 500;

    ERC7786GatewayMock polygonGateway;
    ERC7786GatewayMock optimismGateway;
    SatelliteLiteMock polygonLite;
    SatelliteLiteMock optimismLite;

    Account aliceOnPolygon;
    bytes aliceSat;
    bytes bobSat;
    bytes bobOptimism;
    bytes nativeBob;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        optimismLite = new SatelliteLiteMock(OPTIMISM, address(token), optimismGateway);
        polygonLite.setPeer(optimismLite, optimismGateway);
        optimismLite.setPeer(polygonLite, polygonGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)));
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)));
        vm.stopPrank();

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

        vm.prank(alice);
        token.delegateOut(alice, aliceSat, DELEGATED);
        _relayAll(polygonGateway);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED, "the Lite minted what the token delegated");
    }

    /// @dev Delivers every queued entry of `gateway` not yet delivered or dropped, in order, including the ones a
    ///      delivery queues behind it.
    function _relayAll(ERC7786GatewayMock gateway) private {
        for (uint256 i = 0; i < gateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) gateway.relay(i);
        }
    }

    function _last(ERC7786GatewayMock gateway) private view returns (uint256) {
        return gateway.queueLength() - 1;
    }

    function _issueAndDeliver(bytes memory to, uint256 min, uint256 max) private returns (uint256 id) {
        id = _requestValidation(address(aliceIdentity), aliceSat, to, min, max);
        _relayAll(polygonGateway);
        _relayAll(optimismGateway);
    }

    function _execute(uint256 id, uint256 amount) private {
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(id, amount);
    }

    function _status(uint256 id) private view returns (ITransferValidation.ValidationStatus) {
        return boundCompliance.statusOf(id);
    }

    /* ----- Two legs ----- */

    /// @notice The sending Lite burns and tells both the reference chain and the receiving Lite; the receiving Lite
    ///         mints on that word and tells the reference chain; the pair settles at the amount the sender chose.
    function test_twoLegs_Success_WhenTheLitesDriveBothLegs() public {
        uint256 id = _issueAndDeliver(bobOptimism, 90, 100);
        assertTrue(polygonLite.known(id));
        assertTrue(optimismLite.known(id));

        _execute(id, 95);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED - 95, "burned on the sending chain");

        _relayAll(polygonGateway);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        assertEq(token.inTransitOf(id), 95);

        _relayAll(optimismGateway);
        _relayAll(optimismGateway);
        assertEq(optimismLite.balanceOf(bobOptimism), 95, "minted on the receiving chain, from the burn message");

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED - 95);
        assertEq(token.bridgedBalanceOf(bobOptimism), 95);
        assertEq(token.inTransitOf(id), 0);
        assertEq(token.totalBridged(), DELEGATED);
        assertEq(token.totalSupply(), MINTED);
    }

    /// @notice The receiving Lite's copy of the validation was lost. The sender burns anyway; the burn message is
    ///         refused for want of the terms to check it against, the leg is sent again, and the pair settles.
    function test_twoLegs_Success_WhenTheReceivingLegIsLostAndResentAfterTheBurn() public {
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        optimismGateway.drop(_last(optimismGateway));
        _relayAll(polygonGateway);
        assertTrue(polygonLite.known(id));
        assertFalse(optimismLite.known(id));

        _execute(id, 95);
        _relayAll(polygonGateway);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));
        uint256 burnMessage = _last(optimismGateway);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.UnknownValidation.selector, id));
        optimismGateway.relay(burnMessage);

        vm.prank(address(aliceIdentity));
        boundCompliance.redispatchValidation(id, optimism, bobOptimism, "");
        optimismGateway.relay(_last(optimismGateway));
        assertTrue(optimismLite.known(id));
        optimismGateway.relay(burnMessage);
        _relayAll(optimismGateway);

        assertEq(optimismLite.balanceOf(bobOptimism), 95, "minted once the leg and the burn message were both held");
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobOptimism), 95);
    }

    function test_twoLegs_RevertWhen_TheReceivingLiteMintsBeforeTheBurnMessage() public {
        uint256 id = _issueAndDeliver(bobOptimism, 90, 100);

        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.BurnNotReceived.selector, id));
        optimismLite.mintWithoutBurn(id);

        assertEq(optimismLite.balanceOf(bobOptimism), 0);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    /// @notice A lost burn message leaves the pair waiting; after the second window the keeper returns the hold.
    function test_twoLegs_Resolved_WhenTheBurnMessageIsLost() public {
        uint256 issuedAt = block.timestamp;
        uint256 id = _issueAndDeliver(bobOptimism, 90, 100);
        _execute(id, 95);
        optimismGateway.drop(_last(optimismGateway));
        _relayAll(polygonGateway);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));

        vm.warp(issuedAt + VALIDITY_WINDOW + 2 * OPTIMISM_WINDOW + 1);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(id);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Resolved));
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED, "the hold went back to the sender on this chain");
    }

    /// @notice The receiving chain is paused with its mint report held at the gateway. The keeper cannot resolve
    ///         the pair on that report's absence, so once the pause is lifted the report lands and the pair
    ///         settles: the ledger never credits the sender for what the receiving chain minted.
    function test_twoLegs_Success_WhenTheReceivingChainIsPausedAcrossTheSecondWindow() public {
        uint256 issuedAt = block.timestamp;
        uint256 id = _issueAndDeliver(bobOptimism, 90, 100);
        _execute(id, 95);
        _relayAll(polygonGateway);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.AwaitingMint));

        vm.prank(agent);
        token.setInboundPaused(optimism, true);
        optimismGateway.relay(_last(optimismGateway));
        uint256 mintReport = _last(optimismGateway);
        assertEq(optimismLite.balanceOf(bobOptimism), 95, "the receiving Lite minted on the burn message");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, optimism));
        optimismGateway.relay(mintReport);

        vm.warp(issuedAt + VALIDITY_WINDOW + 2 * OPTIMISM_WINDOW + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, optimism));
        boundCompliance.resolveStuckValidation(id);

        vm.prank(agent);
        token.setInboundPaused(optimism, false);
        optimismGateway.relay(mintReport);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED - 95, "the ledger follows the burn");
        assertEq(token.bridgedBalanceOf(bobOptimism), 95, "and the mint");
        assertFalse(token.isInboundPaused(optimism), "the honest chain stays open");
    }

    /* ----- One leg ----- */

    function test_oneLeg_Success_WhenTheLiteSettlesToTheReferenceChain() public {
        uint256 id = _issueAndDeliver(nativeBob, 100, 100);

        _execute(id, 100);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED - 100);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED - 100);
        assertEq(token.totalSupply(), MINTED);
    }

    function test_oneLeg_Success_WhenTheLiteSettlesOnItsOwnChain() public {
        uint256 id = _issueAndDeliver(bobSat, 10, 50);

        _execute(id, 50);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 50);
        assertEq(polygonLite.balanceOf(bobSat), 50);
    }

    /* ----- The Lite's own rules ----- */

    function test_execute_RevertWhen_TheCallerIsNeitherSenderNorSpender() public {
        uint256 id = _issueAndDeliver(bobSat, 10, 50);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.NotTheExecutor.selector, id, bob));
        polygonLite.execute(id, 50);
    }

    function test_execute_RevertWhen_TheValidationIsConsumed() public {
        uint256 id = _issueAndDeliver(bobSat, 10, 50);
        _execute(id, 50);

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationConsumed.selector, id));
        polygonLite.execute(id, 50);
    }

    function test_execute_RevertWhen_TheValidationExpired() public {
        uint256 id = _issueAndDeliver(bobSat, 10, 50);
        vm.warp(block.timestamp + VALIDITY_WINDOW);

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.ValidationExpired.selector, id));
        polygonLite.execute(id, 50);
    }

    function test_execute_RevertWhen_TheAmountIsOutsideTheRange() public {
        uint256 id = _issueAndDeliver(bobSat, 10, 50);

        vm.prank(aliceOnPolygon.addr);
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.AmountOutOfRange.selector, id, 51));
        polygonLite.execute(id, 51);
    }

    function test_receiveMessage_RevertWhen_NotDeliveredByItsGateway() public {
        vm.expectRevert(abi.encodeWithSelector(SatelliteLiteMock.NotTheGateway.selector, address(this)));
        polygonLite.receiveMessage(bytes32(0), "", "");
    }

    /* ----- Delegation retries ----- */

    /// @notice The mint instruction is lost; the agent resends it; then the original arrives too. The Lite mints
    ///         once, and the token debited once.
    function test_resend_Success_WhenTheMintInstructionWasLost() public {
        vm.prank(alice);
        token.delegateOut(alice, aliceSat, 100);
        uint256 original = _last(polygonGateway);

        bytes memory fields = abi.encode(aliceSat, uint256(100), alice, token.peerFor(polygon));
        vm.prank(agent);
        token.resend(0, 2, fields);
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.relay(original);

        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED + 100, "minted once");
        assertEq(polygonLite.mints(), DELEGATED + 100);
        assertEq(token.balanceOf(alice), MINTED - DELEGATED - 100, "debited once");
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED + 100);
    }

    /* ----- Recall ----- */

    function test_recall_Success_WhenTheLiteAnswersTheInstruction() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 200, alice);
        polygonGateway.relay(_last(polygonGateway));
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED - 200, "the Lite burned what was instructed");

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.RecallSettled(recallId, polygon, 200);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(token.balanceOf(alice), MINTED - DELEGATED + 200);
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED - 200);
        assertEq(token.totalSupply(), MINTED);
    }

    /// @notice A validation executed while the instruction was in flight: the Lite burns what it has left and
    ///         proves that.
    function test_recall_Success_WhenTheLiteHadLessToBurn() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 200, alice);
        uint256 instruction = _last(polygonGateway);
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 400, 400);
        polygonGateway.relay(_last(polygonGateway));
        _execute(id, 400);
        polygonGateway.relay(_last(polygonGateway));
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));

        polygonGateway.relay(instruction);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.RecallSettled(recallId, polygon, DELEGATED - 400);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(token.balanceOf(alice), MINTED - 400);
        assertEq(token.bridgedBalanceOf(aliceSat), 0);
        assertEq(polygonLite.balanceOf(aliceSat), 0);
    }

    /// @notice The recall instruction is lost; the agent resends it; the original arrives later and is answered
    ///         with the stored proof, which the token recognises as a duplicate.
    function test_resend_Success_WhenTheRecallInstructionWasLost() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 200, alice);
        uint256 original = _last(polygonGateway);

        vm.prank(agent);
        token.resend(1, recallId, abi.encode(aliceSat));
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.relay(_last(polygonGateway));
        assertEq(token.balanceOf(alice), MINTED - DELEGATED + 200);

        polygonGateway.relay(original);
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.BurnProofDuplicate(recallId, polygon);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(polygonLite.burns(), 200, "burned once");
        assertEq(token.balanceOf(alice), MINTED - DELEGATED + 200, "credited once");
        assertFalse(token.paused());
    }

    /// @notice The proof is lost; the Lite's operator resends the stored proof; it settles once.
    function test_resendProof_Success_WhenTheProofWasLost() public {
        vm.prank(agent);
        uint256 recallId = token.instructRecall(aliceSat, 200, alice);
        polygonGateway.relay(_last(polygonGateway));
        polygonGateway.drop(_last(polygonGateway));
        assertEq(token.pendingRecall(recallId).amount, 200, "still waiting");

        polygonLite.resendProof(recallId);
        polygonGateway.relay(_last(polygonGateway));

        assertEq(token.balanceOf(alice), MINTED - DELEGATED + 200);
        assertEq(token.pendingRecall(recallId).amount, 0);
    }

}

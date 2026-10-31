// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev The reference chain against Lites that execute a validation attested before this chain's finality, so a
///      reorg can reorder, drop or re-issue an issuance after a Lite acted on it. Three things hold it together: the
///      id is a function of the request (`keccak256(fromKey, salt)`), a leg reported for an id nothing is issued
///      under is parked and settled once the request is sent again with the same salt, and the hash a leg carries tells
///      a body a reorg orphaned from a Lite that broke a rule. See `docs/satellite-lite.md`, "Lanes".
///
///      The issuance a reorg dropped is replayed here by delivering, authored by the token, the body the orphaned
///      fork would have sent: the Lite cannot tell it from one that survived.
contract ReorgRecoveryTest is InteropSuiteTest {

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
    address backend = makeAddr("institutionBackend");

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

        vm.startPrank(agent);
        token.mint(alice, MINTED);
        token.unpause();
        vm.stopPrank();

        vm.prank(alice);
        token.delegateOut(alice, aliceSat, DELEGATED);
        _relayAll(polygonGateway);
        assertEq(polygonLite.balanceOf(aliceSat), DELEGATED, "the Lite minted what the token delegated");
    }

    /* ----- Case 1: the issuance is re-included behind another one ----- */

    /// @notice Two requests land in the other order on the canonical fork. Each keeps the id its request derives,
    ///         so what the Lite executed under either id settles whatever the order was.
    function test_reorg_Success_WhenIssuancesAreReorderedTheIdsStay() public {
        bytes32 saltA = _salt();
        bytes32 saltB = _salt();
        bytes32 a = _validationId(aliceSat, saltA);
        bytes32 b = _validationId(aliceSat, saltB);

        // B lands before A: on the orphaned fork it was the other way round.
        vm.startPrank(address(aliceIdentity));
        assertEq(boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", saltB), b);
        assertEq(boundCompliance.requestTransferValidation(aliceSat, bobSat, 50, 60, "", saltA), a);
        vm.stopPrank();
        _relayAll(polygonGateway);

        _execute(a, 55);
        _execute(b, 95);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(a)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(uint8(_status(b)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(boundCompliance.validationOf(a).executedAmount, 55);
        assertEq(boundCompliance.validationOf(b).executedAmount, 95);
        assertEq(token.bridgedBalanceOf(bobSat), 150);
        assertFalse(token.isInboundPaused(polygon));
    }

    /* ----- Case 2: the issuance is dropped from the canonical chain ----- */

    /// @notice The Lite executed an issuance the canonical chain never saw. Its leg is parked under the id and the
    ///         chain paused, the token untouched. The request sent again with the same salt issues the same id,
    ///         sends nothing to the chain that already executed, and settles the parked leg.
    function test_reorg_Success_WhenADroppedIssuanceIsResubmittedWithTheSameSalt() public {
        bytes32 salt = _salt();
        MessageTypesLib.ComplianceValidation memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.validationId;
        assertTrue(polygonLite.known(id));
        assertEq(boundCompliance.validationOf(id).fromIdentity, address(0), "nothing recorded here");

        _execute(id, 95);
        uint256 report = _last(polygonGateway);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SettlementParked(id, polygon, 95, MessageTypesLib.hashValidation(orphaned));
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(report);

        assertFalse(token.paused(), "the token keeps running");
        assertTrue(token.isInboundPaused(polygon), "the chain that executed before finality is paused");
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(report)), "consumed");
        assertEq(token.bridgedBalanceOf(bobSat), 0, "nothing applied");
        ITransferValidation.ParkedLeg memory parked = boundCompliance.parkedLegOf(id, polygon);
        assertTrue(parked.exists);
        assertEq(parked.amount, 95);
        assertEq(parked.hash, MessageTypesLib.hashValidation(orphaned));

        // The operator lifts the pause once the reorg is understood; the requester sends the request again.
        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        uint256 queued = polygonGateway.queueLength();

        vm.prank(address(aliceIdentity));
        assertEq(boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt), id);
        assertEq(polygonGateway.queueLength(), queued, "no leg toward the chain that already executed");
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ParkedLegSettled(id, polygon);
        boundCompliance.settleParkedLeg(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(boundCompliance.validationOf(id).executedAmount, 95);
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED - 95);
        assertFalse(boundCompliance.parkedLegOf(id, polygon).exists);
        assertEq(
            boundCompliance.validationOf(id).hash,
            MessageTypesLib.hashValidation(orphaned),
            "same terms, same hash, whatever the clock said"
        );
        assertFalse(token.isInboundPaused(polygon));
    }

    /// @notice The pause the parking set gates both steps of the recovery: the request sent again and the settling
    ///         of the parked leg wait for the pauser, as a leg at the gateway does.
    function test_reorg_RevertWhen_TheChainIsStillPausedForEitherStep() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).validationId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        assertTrue(token.isInboundPaused(polygon));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, polygon));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt);

        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt);

        // The pauser looks again before the parked leg is taken: it waits under the pause like any delivery.
        vm.prank(agent);
        token.setInboundPaused(polygon, true);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainInboundPaused.selector, polygon));
        boundCompliance.settleParkedLeg(id, polygon);
        assertTrue(boundCompliance.parkedLegOf(id, polygon).exists);

        vm.prank(agent);
        token.setInboundPaused(polygon, false);
        boundCompliance.settleParkedLeg(id, polygon);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /// @notice The other way out of a drop. The Lite executed the dropped body above what the request, sent
    ///         again, is issued at: the parked leg fits no issued terms and its hash is not the issued one, so
    ///         the validation ends `Orphaned` at issuance, nothing moves, and the chain is paused again.
    function test_reorg_Success_WhenTheResubmittedTermsNoLongerCoverTheParkedLeg() public {
        bytes32 salt = _salt();
        MessageTypesLib.ComplianceValidation memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.validationId;
        _execute(id, 98);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 95, "", salt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationOrphaned(id, polygon, 98, MessageTypesLib.hashValidation(orphaned));
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        boundCompliance.settleParkedLeg(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Orphaned));
        assertTrue(token.isInboundPaused(polygon));
        assertEq(token.bridgedBalanceOf(bobSat), 0, "nothing applied");
        assertEq(token.reservedOf(aliceSat), 0, "the reservation is released");
        assertEq(boundCompliance.pendingInOf(address(bobIdentity)), 0);
        assertFalse(boundCompliance.parkedLegOf(id, polygon).exists);
    }

    /// @notice A dropped two-leg issuance: the sending Lite burned and the receiving Lite minted on its word,
    ///         each leg parked on its own chain. The request sent again settles both and sends nothing.
    function test_reorg_Success_WhenADroppedTwoLegIssuanceIsResubmitted() public {
        bytes32 salt = _salt();
        MessageTypesLib.ComplianceValidation memory orphaned = _orphanedIssuance(salt, bobOptimism, 90, 100);
        bytes32 id = orphaned.validationId;
        _deliverToLite(optimismGateway, optimismLite, orphaned);

        _execute(id, 95);
        _relayAll(polygonGateway);
        _relayAll(optimismGateway);
        assertEq(optimismLite.balanceOf(bobOptimism), 95, "minted on the burn message");
        assertTrue(boundCompliance.parkedLegOf(id, polygon).exists, "the burn leg is parked");
        assertTrue(boundCompliance.parkedLegOf(id, optimism).exists, "the mint leg is parked");
        assertTrue(token.isInboundPaused(polygon));
        assertTrue(token.isInboundPaused(optimism));
        assertFalse(token.paused());
        assertEq(token.inTransitOf(id), 0, "nothing applied");

        vm.startPrank(agent);
        token.setInboundPaused(polygon, false);
        token.setInboundPaused(optimism, false);
        vm.stopPrank();
        uint256 polygonQueued = polygonGateway.queueLength();
        uint256 optimismQueued = optimismGateway.queueLength();

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobOptimism, 90, 100, "", salt);
        assertEq(polygonGateway.queueLength(), polygonQueued, "nothing sent");
        assertEq(optimismGateway.queueLength(), optimismQueued, "nothing sent");

        // Either order: the mint leg first waits as it does at delivery.
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ParkedLegSettled(id, optimism);
        boundCompliance.settleParkedLeg(id, optimism);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.AwaitingBurn));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ParkedLegSettled(id, polygon);
        boundCompliance.settleParkedLeg(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(aliceSat), DELEGATED - 95);
        assertEq(token.bridgedBalanceOf(bobOptimism), 95);
        assertEq(token.inTransitOf(id), 0);
        assertEq(token.totalBridged(), DELEGATED);
    }

    /// @notice A parked leg for a request that then waits for approval stays parked until the answer: issued, it
    ///         settles.
    function test_reorg_Success_WhenTheResubmittedRequestWaitsForApproval() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        MessageTypesLib.ComplianceValidation memory orphaned = _orphanedIssuance(salt, bobSat, 90, 100);
        bytes32 id = orphaned.validationId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.AwaitingApproval));
        assertTrue(boundCompliance.parkedLegOf(id, polygon).exists, "waits for the answer");
        assertEq(token.bridgedBalanceOf(bobSat), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ParkedLegNotSettleable.selector, id, polygon));
        boundCompliance.settleParkedLeg(id, polygon);

        vm.prank(backend);
        module.approveValidation(address(boundCompliance), id, 100);
        module.finalize(address(boundCompliance), id);
        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Pending));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ParkedLegSettled(id, polygon);
        boundCompliance.settleParkedLeg(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.parkedLegOf(id, polygon).exists);
    }

    /// @notice Refused, the request issues nothing and the leg stays parked for the operator to read.
    function test_reorg_Success_WhenTheResubmittedRequestIsRefusedTheLegStaysParked() public {
        AsyncApprovalModule module = _bindApprovalModule();
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).validationId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt);
        vm.prank(backend);
        module.refuseValidation(address(boundCompliance), id);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertTrue(boundCompliance.parkedLegOf(id, polygon).exists, "left for the operator");
        assertEq(boundCompliance.parkedLegOf(id, polygon).amount, 95);
        assertEq(token.bridgedBalanceOf(bobSat), 0);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ParkedLegNotSettleable.selector, id, polygon));
        boundCompliance.settleParkedLeg(id, polygon);
    }

    /// @notice The requester need not come back: the body the Lite holds carries the salt, so an agent sends the
    ///         request again on their behalf from the parked leg's wallets and the Lite's copy.
    function test_reorg_Success_WhenAnAgentResubmitsFromTheLitesCopy() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 90, 100).validationId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        MessageTypesLib.ComplianceValidation memory held = polygonLite.validationOf(id);
        ITransferValidation.ParkedLeg memory parked = boundCompliance.parkedLegOf(id, polygon);
        assertEq(held.salt, salt, "the salt is final on the satellite");

        vm.prank(agent);
        assertEq(
            boundCompliance.requestTransferValidation(
                parked.from, parked.to, parked.amount, parked.amount, "", held.salt
            ),
            id
        );
        boundCompliance.settleParkedLeg(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
    }

    /* ----- Case 3: the same id, another body ----- */

    /// @notice The Lite holds the wider body of the orphaned fork and has not executed when the canonical one
    ///         lands under the same id: it replaces what it holds, executes the canonical terms, and the leg
    ///         settles as any other.
    function test_reorg_Success_WhenTheCanonicalBodyReplacesTheOrphanedOneBeforeExecution() public {
        bytes32 salt = _salt();
        bytes32 id = _orphanedIssuance(salt, bobSat, 80, 100).validationId;
        assertEq(polygonLite.validationOf(id).amountMin, 80);

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt);
        _relayAll(polygonGateway);
        assertEq(polygonLite.validationOf(id).amountMin, 90, "the later body replaced the orphaned one");
        assertEq(polygonLite.hashOf(id), boundCompliance.validationOf(id).hash);

        _execute(id, 95);
        _relayAll(polygonGateway);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertFalse(token.isInboundPaused(polygon));
    }

    /// @notice The Lite executed the wider orphaned body at an amount the canonical terms also cover: the leg
    ///         settles, with the divergence on record.
    function test_reorg_Success_WhenTheLegExecutedUnderAnotherBodyFitsTheIssuedTerms() public {
        bytes32 salt = _salt();
        MessageTypesLib.ComplianceValidation memory orphaned = _orphanedIssuance(salt, bobSat, 80, 100);
        bytes32 id = orphaned.validationId;
        _execute(id, 95);
        polygonGateway.relay(_last(polygonGateway));
        vm.prank(agent);
        token.setInboundPaused(polygon, false);

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 90, 100, "", salt);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.SettlementBodyDiverged(id, polygon, MessageTypesLib.hashValidation(orphaned));
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ParkedLegSettled(id, polygon);
        boundCompliance.settleParkedLeg(id, polygon);

        assertEq(uint8(_status(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 95);
        assertTrue(boundCompliance.validationOf(id).hash != MessageTypesLib.hashValidation(orphaned));
    }

    /// @notice A resend repeats the issuance byte for byte: the Lite ignores it, and so does a Lite that already
    ///         consumed the id whatever body arrives under it.
    function test_reorg_Success_WhenALaterBodyUnderAConsumedIdIsIgnored() public {
        bytes32 salt = _salt();
        MessageTypesLib.ComplianceValidation memory orphaned = _orphanedIssuance(salt, bobSat, 80, 100);
        bytes32 id = orphaned.validationId;
        bytes32 executedUnder = MessageTypesLib.hashValidation(orphaned);
        _execute(id, 95);

        // `orphaned` is a memory reference: `later` is the same body, narrowed in place, so the Lite sees another
        // body under the id it already consumed.
        MessageTypesLib.ComplianceValidation memory later = orphaned;
        later.amountMin = 90;
        _deliverToLite(polygonGateway, polygonLite, later);

        assertEq(polygonLite.validationOf(id).amountMin, 80, "consumed: the body held is the one executed");
        assertEq(polygonLite.hashOf(id), executedUnder);
    }

    /* ----- Helpers ----- */

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

    function _execute(bytes32 id, uint256 amount) private {
        vm.prank(aliceOnPolygon.addr);
        polygonLite.execute(id, amount);
    }

    function _status(bytes32 id) private view returns (ITransferValidation.ValidationStatus) {
        return boundCompliance.statusOf(id);
    }

    /// @dev What the issuance a reorg orphaned sent to the sending Lite: the body the reference chain built on
    ///      the fork that did not survive, under the id the request derives, authored by the token as the gateway
    ///      attributes it. Nothing is recorded on this chain for it.
    function _orphanedIssuance(bytes32 salt, bytes memory to, uint256 amountMin, uint256 amountMax)
        private
        returns (MessageTypesLib.ComplianceValidation memory body)
    {
        body = MessageTypesLib.ComplianceValidation({
            validationId: _validationId(aliceSat, salt),
            salt: salt,
            from: aliceSat,
            to: to,
            spender: "",
            amountMin: amountMin,
            amountMax: amountMax,
            token: address(token),
            expiry: uint64(block.timestamp) + VALIDITY_WINDOW,
            reconciliationWindow: POLYGON_WINDOW
        });
        _deliverToLite(polygonGateway, polygonLite, body);
    }

    function _deliverToLite(
        ERC7786GatewayMock gateway,
        SatelliteLiteMock lite,
        MessageTypesLib.ComplianceValidation memory body
    ) private {
        bytes memory recipient = InteroperableAddress.formatEvmV1(gateway.originChainId(), address(lite));
        vm.prank(address(token));
        gateway.sendMessage(recipient, MessageTypesLib.encodeValidation(body), new bytes[](0));
        gateway.relay(_last(gateway));
    }

    function _bindApprovalModule() private returns (AsyncApprovalModule module) {
        module = AsyncApprovalModule(
            address(
                new ModuleProxy(
                    address(new AsyncApprovalModule()),
                    abi.encodeCall(AsyncApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );
        address[] memory approvers = new address[](1);
        approvers[0] = backend;
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(module), settings);
    }

}

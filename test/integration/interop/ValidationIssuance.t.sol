// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Issuance through the real messaging layer: which legs leave toward which chain, what they carry, how
///      the route is pinned, and how a closed chain or a pause stops everything before any write.
contract ValidationIssuanceTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 100;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal bobOptimism;
    bytes internal nativeAlice;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));
        nativeAlice = InteroperableAddress.formatEvmV1(block.chainid, alice);
    }

    /* ----- Legs ----- */

    function test_requestTransferValidation_Success_WhenSameChainQueuesOneLeg() public {
        vm.warp(1_700_000_000);
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);

        assertEq(polygonGateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 0);
        assertEq(polygonGateway.queuedMessage(0).recipient, token.peerFor(polygon));
        assertEq(token.pinnedRouteFor(id, polygon), address(polygonGateway));

        MessageTypesLib.ComplianceValidation memory sent = _decodeQueuedValidation(polygonGateway, 0);
        assertEq(sent.validationId, id);
        assertEq(sent.from, aliceSat);
        assertEq(sent.to, bobSat);
        assertEq(sent.spender.length, 0);
        assertEq(sent.amountMin, 10);
        assertEq(sent.amountMax, 90);
        assertEq(sent.token, address(token));
        assertEq(sent.expiry, 1_700_000_000 + VALIDITY_WINDOW);
        assertEq(sent.reconciliationWindow, POLYGON_WINDOW);
        assertEq(boundCompliance.validationOf(id).hash, MessageTypesLib.hashValidation(sent));
    }

    function test_requestTransferValidation_Success_WhenCrossChainQueuesOneLegPerChain() public {
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 10, 90);

        assertEq(polygonGateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 1);
        assertEq(token.pinnedRouteFor(id, polygon), address(polygonGateway));
        assertEq(token.pinnedRouteFor(id, optimism), address(optimismGateway));

        MessageTypesLib.ComplianceValidation memory burnLeg = _decodeQueuedValidation(polygonGateway, 0);
        MessageTypesLib.ComplianceValidation memory mintLeg = _decodeQueuedValidation(optimismGateway, 0);
        assertEq(burnLeg.validationId, id);
        assertEq(mintLeg.validationId, id);
        assertEq(MessageTypesLib.hashValidation(burnLeg), MessageTypesLib.hashValidation(mintLeg));
        assertEq(burnLeg.reconciliationWindow, OPTIMISM_WINDOW);

        ITransferValidation.ValidationRecord memory record = boundCompliance.validationOf(id);
        assertEq(record.releaseAt, record.expiry + OPTIMISM_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, optimism);
    }

    function test_requestTransferValidation_Success_WhenANativeHolderSendsToASatellite() public {
        vm.prank(agent);
        token.mint(alice, 50);

        uint256 id = _requestValidation(alice, nativeAlice, bobSat, 10, 200);

        assertEq(polygonGateway.queueLength(), 1);
        assertEq(optimismGateway.queueLength(), 0);
        assertEq(token.pinnedRouteFor(id, polygon), address(polygonGateway));
        assertEq(boundCompliance.validationOf(id).amountMax, 50);
    }

    function test_requestTransferValidation_Success_WhenTheSpenderTravelsWithTheObject() public {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("operatorOnPolygon"));

        vm.prank(address(aliceIdentity));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 90, spender);

        assertEq(_decodeQueuedValidation(polygonGateway, 0).spender, spender);
    }

    function test_requestTransferValidation_Success_WhenSlippageIsCappedAtTheBalance() public {
        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 90, 110);

        MessageTypesLib.ComplianceValidation memory sent = _decodeQueuedValidation(polygonGateway, 0);
        assertEq(sent.amountMin, 90);
        assertEq(sent.amountMax, BALANCE);
        assertEq(boundCompliance.validationOf(id).amountMax, BALANCE);
    }

    /* ----- Authorization ----- */

    function test_requestTransferValidation_Success_WhenAnAgentAsksForAnotherWallet() public {
        assertEq(_requestValidation(agent, aliceSat, bobSat, 10, 90), 1);
    }

    function test_requestTransferValidation_RevertWhen_AStrangerAsks() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, another, aliceSat));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 90, "");
    }

    /* ----- Eligibility ----- */

    function test_requestTransferValidation_RevertWhen_TheRecipientWasRevoked() public {
        _revokeWallet(bobIdentity, bobSat);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, bobSat));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 90, "");
    }

    /// @notice A revoked sender keeps its position and may still move it out.
    function test_requestTransferValidation_Success_WhenTheSenderWasRevoked() public {
        _revokeWallet(aliceIdentity, aliceSat);

        assertEq(_requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90), 1);
    }

    /* ----- Fail closed ----- */

    function test_requestTransferValidation_RevertWhen_TheGatewayIsNoLongerTrusted() public {
        trustedGatewayRegistry.setTrustedGateway(address(polygonGateway), false);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 90, "");

        assertEq(boundCompliance.nextValidationId(), 0);
        assertEq(boundCompliance.validationOf(1).hash, bytes32(0));
        assertEq(polygonGateway.queueLength(), 0);
    }

    /// @notice A cross-chain request with one chain closed sends nothing at all.
    function test_requestTransferValidation_RevertWhen_TheSecondLegHasNoRoute() public {
        vm.prank(deployer);
        token.setRoute(bytes2(0x0000), hex"0a", address(0));

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, optimism));
        boundCompliance.requestTransferValidation(aliceSat, bobOptimism, 10, 90, "");

        assertEq(polygonGateway.queueLength(), 0);
        assertEq(boundCompliance.nextValidationId(), 0);
    }

    function test_requestTransferValidation_Success_WhenARouteSwitchPinsTheNewGatewayForNewIdsOnly() public {
        uint256 first = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
        ERC7786GatewayMock replacement = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(replacement));

        uint256 second = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);

        assertEq(token.pinnedRouteFor(first, polygon), address(polygonGateway));
        assertEq(token.pinnedRouteFor(second, polygon), address(replacement));
        assertEq(replacement.queueLength(), 1);
    }

    function test_requestTransferValidation_Success_WhenPauseAndUnpauseRoundTrip() public {
        vm.prank(deployer);
        boundCompliance.pauseValidationIssuance(polygon);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 90, "");

        vm.prank(deployer);
        boundCompliance.unpauseValidationIssuance(polygon);

        assertEq(_requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90), 1);
        assertEq(polygonGateway.queueLength(), 1);
    }

    function test_requestTransferValidation_Success_WhenAnnouncingBeforeDispatching() public {
        vm.warp(1_700_000_000);

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.TransferValidationIssued(
            1, aliceSat, bobSat, "", 10, 90, uint64(1_700_000_000 + VALIDITY_WINDOW), POLYGON_WINDOW
        );
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.ValidationRoutePinned(1, polygon, address(polygonGateway));
        _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 90);
    }

}

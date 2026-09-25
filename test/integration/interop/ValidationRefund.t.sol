// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The way out of a pair of which one leg never came.
///
///      A two-leg validation whose burn leg landed waits for its mint leg for as long as it takes, because the
///      satellite already burned and a discard would invent supply. When the mint never comes, the operator
///      gives up on the pair: the burned amount goes back to the wallet it left and the reservation is released.
///      When it is the mint that landed and the burn that never came, nothing on this chain can be returned, so
///      the chain that owes the burn stops being issued to instead.
contract ValidationRefundTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;
    uint256 internal constant EXECUTED = 95;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobOptimism;
    uint256 internal issuedAt;
    uint256 internal id;
    /// A second reconciliation window past `releaseAt`. The pair spans both chains, so the window is the longer.
    uint256 internal refundableAt;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        vm.prank(agent);
        token.unpause();

        issuedAt = block.timestamp;
        id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        refundableAt = issuedAt + VALIDITY_WINDOW + 2 * OPTIMISM_WINDOW;
    }

    /* ----- Burn leg in, mint leg never came ----- */

    /// @notice The burned amount goes back to the wallet it left, the reservation is released, and the pair is
    ///         closed as refunded.
    function test_refundValidation_Success_WhenTheMintNeverCame() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        assertEq(token.inTransitOf(id), EXECUTED, "the burned amount waits in transit");
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - EXECUTED, "and left the wallet");

        vm.warp(refundableAt + 1);
        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ValidationRefunded(id, EXECUTED);
        vm.prank(keeper);
        boundCompliance.refundValidation(id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Refunded));
        assertEq(token.inTransitOf(id), 0, "nothing in transit any more");
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE, "the wallet has its tokens back");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 0, "released");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingOutOf(address(aliceIdentity)), 0, "released");
        assertEq(IComplianceLedger(address(boundCompliance)).positionOf(address(aliceIdentity)), BALANCE);
    }

    /// @notice A mint leg arriving after the refund is a leg for tokens that no longer wait anywhere: it halts the
    ///         token, the way a replayed leg does.
    function test_handleSettlement_HaltsTheToken_WhenTheMintArrivesAfterTheRefund() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        vm.warp(refundableAt + 1);
        vm.prank(keeper);
        boundCompliance.refundValidation(id);

        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, EXECUTED)));

        assertTrue(token.paused(), "the token halted itself");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Refunded));
        assertEq(token.bridgedBalanceOf(bobOptimism), 0, "nothing was credited");
    }

    /// @notice A leg that is merely slow is a late reconciliation, never a refund: the gate is a second
    ///         reconciliation window past `releaseAt`.
    function test_refundValidation_RevertWhen_TooEarly() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        vm.warp(refundableAt);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotYetRefundable.selector, id, uint64(refundableAt)));
        boundCompliance.refundValidation(id);
    }

    /// @notice A discarded validation whose burn leg then lands late is refundable the same way: the discard
    ///         released the reservation, the late leg put tokens in transit, and those still need a way home.
    function test_refundValidation_Success_WhenTheBurnCameLateAfterADiscard() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + OPTIMISM_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        assertEq(token.inTransitOf(id), EXECUTED);

        vm.warp(refundableAt + 1);
        vm.prank(keeper);
        boundCompliance.refundValidation(id);

        assertEq(token.inTransitOf(id), 0);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Refunded));
    }

    /* ----- Mint leg in, burn leg never came ----- */

    /// @notice Nothing on this chain can be returned, so the chain that owes the burn is paused for issuance and
    ///         the validation is left as it is.
    function test_refundValidation_PausesTheBurnChain_WhenTheBurnNeverCame() public {
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, EXECUTED)));
        assertFalse(boundCompliance.isIssuancePaused(polygon));

        vm.warp(refundableAt + 1);
        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ValidationStuck(id, polygon);
        vm.prank(keeper);
        boundCompliance.refundValidation(id);

        assertTrue(boundCompliance.isIssuancePaused(polygon), "no more issuance toward the chain that owes");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.LegConfirmed));
        assertFalse(token.paused());

        // The burn leg, however late, still completes the pair.
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
    }

    /* ----- What is not a stuck pair ----- */

    /// @notice A validation nobody executed is discarded, not refunded; one fully settled has nothing to refund.
    function test_refundValidation_RevertWhen_NotExactlyOneLegIn() public {
        vm.warp(refundableAt + 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotRefundable.selector, id));
        boundCompliance.refundValidation(id);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, EXECUTED)));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotRefundable.selector, id));
        boundCompliance.refundValidation(id);
    }

    function test_refundValidation_RevertWhen_RefundedTwice() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        vm.warp(refundableAt + 1);
        vm.startPrank(keeper);
        boundCompliance.refundValidation(id);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotRefundable.selector, id));
        boundCompliance.refundValidation(id);
        vm.stopPrank();
    }

    function test_refundValidation_RevertWhen_NotAuthorized() public {
        vm.prank(another);
        vm.expectRevert();
        boundCompliance.refundValidation(id);
    }

}

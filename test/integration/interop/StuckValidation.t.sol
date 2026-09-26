// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The way out of a pair of which one leg never arrived.
///
///      A two-leg validation cannot be discarded once a satellite has executed its half: the tokens that half
///      burned are real and gone, and rolling the reservation back would invent supply. So such a pair used to
///      have no exit at all, and its tokens waited in transit for a leg that was never coming.
///
///      `resolveStuckValidation` is that exit, gated a second reconciliation window past `releaseAt` so a leg
///      that is merely slow still reconciles late instead of being written off.
contract StuckValidationTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;
    uint256 internal constant EXECUTED = 95;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    bytes internal aliceSat;
    bytes internal bobOptimism;
    uint256 internal issuedAt;
    uint256 internal id;
    /// Past `releaseAt` plus one more reconciliation window; the pair spans both chains, so it is the longer.
    uint256 internal resolvableAt;

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
        resolvableAt = issuedAt + VALIDITY_WINDOW + 2 * OPTIMISM_WINDOW;
    }

    /* ----- The burn leg landed and the mint never came ----- */

    /// @notice The burned amount goes back to the wallet it left, the reservation is released, and the pair ends
    ///         in `Resolved`.
    function test_resolveStuckValidation_Success_WhenTheMintNeverCame() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        assertEq(token.inTransitOf(id), EXECUTED, "the burned amount waits in transit");
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - EXECUTED, "and has left the wallet");

        vm.warp(resolvableAt + 1);
        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ValidationResolved(id, EXECUTED);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(id);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Resolved));
        assertEq(token.inTransitOf(id), 0, "nothing waits in transit any more");
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE, "the wallet has its tokens back");
        assertEq(token.reservedOf(aliceSat), 0, "and its room back");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 0, "released");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingOutOf(address(aliceIdentity)), 0, "released");
    }

    /// @notice A mint leg arriving after the resolution is a leg for tokens that no longer wait anywhere, so it
    ///         halts the token the way a replayed leg does.
    function test_handleSettlement_HaltsTheToken_WhenAMintArrivesAfterTheResolution() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        vm.warp(resolvableAt + 1);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(id);

        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, EXECUTED)));

        assertTrue(token.paused(), "the token halted itself");
        assertEq(token.bridgedBalanceOf(bobOptimism), 0, "nothing was credited");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Resolved));
    }

    /// @notice A pair discarded before its late burn leg landed is stuck in the same way, and resolves the same
    ///         way: the discard released the reservation, the late leg put tokens in transit, and those still
    ///         need a way home.
    function test_resolveStuckValidation_Success_WhenTheBurnCameLateAfterADiscard() public {
        vm.warp(issuedAt + VALIDITY_WINDOW + OPTIMISM_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        assertEq(token.inTransitOf(id), EXECUTED);

        vm.warp(resolvableAt + 1);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(id);

        assertEq(token.inTransitOf(id), 0);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Resolved));
    }

    /* ----- The mint leg landed and the burn never came ----- */

    /// @notice Nothing on this chain can be returned, so the chain that owes the burn stops being issued to and
    ///         an operator investigates.
    function test_resolveStuckValidation_PausesTheBurnChain_WhenTheBurnNeverCame() public {
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, EXECUTED)));
        assertFalse(boundCompliance.isIssuancePaused(polygon));

        vm.warp(resolvableAt + 1);
        vm.expectEmit(address(boundCompliance));
        emit EventsLib.ValidationResolved(id, 0);
        vm.prank(keeper);
        boundCompliance.resolveStuckValidation(id);

        assertTrue(boundCompliance.isIssuancePaused(polygon), "no more issuance toward the chain that owes");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Resolved));
        assertFalse(token.paused());
    }

    /* ----- What is not a stuck pair ----- */

    /// @notice A leg that is merely slow must still reconcile late, so the gate is a second window.
    function test_resolveStuckValidation_RevertWhen_TooEarly() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        vm.warp(resolvableAt);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationNotYetResolvable.selector, id, uint64(resolvableAt)));
        boundCompliance.resolveStuckValidation(id);
    }

    /// @notice A validation nobody executed is discarded, not resolved; one fully settled has nothing to undo.
    function test_resolveStuckValidation_RevertWhen_NoLegOrBothLegsAreIn() public {
        vm.warp(resolvableAt + 1);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotStuck.selector, id, uint8(ITransferValidation.ValidationStatus.Pending)
            )
        );
        boundCompliance.resolveStuckValidation(id);

        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, EXECUTED)));
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotStuck.selector, id, uint8(ITransferValidation.ValidationStatus.Settled)
            )
        );
        boundCompliance.resolveStuckValidation(id);
    }

    function test_resolveStuckValidation_RevertWhen_ResolvedTwice() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, EXECUTED)));
        vm.warp(resolvableAt + 1);

        vm.startPrank(keeper);
        boundCompliance.resolveStuckValidation(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotStuck.selector, id, uint8(ITransferValidation.ValidationStatus.Resolved)
            )
        );
        boundCompliance.resolveStuckValidation(id);
        vm.stopPrank();
    }

    function test_resolveStuckValidation_RevertWhen_NotTheKeeper() public {
        vm.prank(another);
        vm.expectRevert();
        boundCompliance.resolveStuckValidation(id);
    }

}

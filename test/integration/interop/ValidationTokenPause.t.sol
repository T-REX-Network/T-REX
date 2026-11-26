// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The token's pause stops validations going out, as the per-chain issuance pause does for one chain: no new
///      request, no resend, until the pauser unpauses.
contract ValidationTokenPauseTest is InteropSuiteTest {

    ERC7786GatewayMock polygonGateway;

    bytes aliceSat;
    bytes bobSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), 1000);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        vm.prank(agent);
        token.unpause();
    }

    function _pause() private {
        vm.prank(agent);
        token.pause();
    }

    function _unpause() private {
        vm.prank(agent);
        token.unpause();
    }

    function _request() private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 100);
    }

    function _resend(bytes32 id) private {
        vm.prank(address(aliceIdentity));
        boundCompliance.resendValidation(id, polygon, bobSat, "");
    }

    /* ----- requestTransferValidation ----- */

    function test_requestTransferValidation_RevertWhen_TheTokenIsPaused() public {
        _pause();

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        _request();

        assertEq(polygonGateway.queueLength(), 0, "nothing sent");
        assertEq(token.reservedOf(aliceSat), 0, "nothing reserved");
    }

    function test_requestTransferValidation_Success_OnceTheTokenIsUnpaused() public {
        _pause();
        _unpause();

        bytes32 id = _request();

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(polygonGateway.queueLength(), 1);
    }

    /// @dev An agent the AccessManager authorises for the selector is refused like the identity.
    function test_requestTransferValidation_RevertWhen_TheTokenIsPaused_ForAnAuthorisedAgent() public {
        _pause();

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        _requestValidation(agent, aliceSat, bobSat, 10, 100);
    }

    /* ----- resendValidation ----- */

    /// @dev Refused while paused: `ValidationResend.t.sol`, `test_resendValidation_RevertWhen_TheTokenIsPaused`.
    function test_resendValidation_Success_OnceTheTokenIsUnpaused() public {
        bytes32 id = _request();
        _pause();
        _unpause();

        _resend(id);

        assertEq(polygonGateway.queueLength(), 2);
        assertEq(polygonGateway.queuedMessage(1).payload, polygonGateway.queuedMessage(0).payload, "byte for byte");
    }

    /* ----- discardExpiredValidations ----- */

    /// @dev The pause outlasts the validation's windows while the satellite's report waits at the gateway. The
    ///      validation is not discarded under the pause, so its reservation is not released for another request
    ///      to take, and the report settles it once the token runs again.
    function test_discardExpiredValidations_RevertWhen_TheTokenIsPaused_ThenTheHeldLegSettles() public {
        bytes32 id = _request();
        uint256 leg = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 100));
        _pause();
        vm.warp(block.timestamp + VALIDITY_WINDOW + 2 * POLYGON_WINDOW + 1);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.discardExpiredValidations(ids);
        assertEq(token.reservedOf(aliceSat), 100, "the reservation stays while the leg may be waiting");

        _unpause();
        polygonGateway.relay(leg);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(token.bridgedBalanceOf(bobSat), 100);
        assertFalse(boundCompliance.isIssuancePaused(polygon), "settled, not reconciled late");
    }

    /// @dev Once the token runs again, a validation nobody executed is discarded as before.
    function test_discardExpiredValidations_Success_OnceTheTokenIsUnpaused() public {
        bytes32 id = _request();
        _pause();
        vm.warp(block.timestamp + VALIDITY_WINDOW + 2 * POLYGON_WINDOW + 1);
        _unpause();
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;

        boundCompliance.discardExpiredValidations(ids);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertEq(token.reservedOf(aliceSat), 0);
    }

    /// @dev The pause takes nothing back: a validation issued before it stays `Pending`, its reservation held,
    ///      and the satellite's report waits at the gateway until the unpause, as every settlement does.
    function test_pause_LeavesAValidationIssuedBeforeItPending() public {
        bytes32 id = _request();
        _pause();

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.reservedOf(aliceSat), 100);
    }

}

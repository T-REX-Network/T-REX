// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule, RuleOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Why reservations exist: two validations issued against one cap cannot jointly breach it, because the
///      first is counted at its worst case until it settles or is discarded.
///
///      The compliance keeps those pending amounts itself, per identity, so a rule reads them instead of
///      keeping its own copy. That is what closes the two issuance bugs this suite pins: a validation can no
///      longer be counted against nobody, and moving tokens between two wallets of one identity no longer eats
///      that identity's own room.
contract PendingReservationTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    bytes internal aliceSat;
    bytes internal bobSat;
    CappedRecipientModule internal cappedRule;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (CAP)), address(cappedRule));
        vm.stopPrank();
    }

    // ==== reservation Tests ====

    /// @notice The first validation is counted against the recipient at its worst case.
    function test_requestTransferValidation_Success_WhenTheFirstValidationReservesItsMaximum() public {
        uint256 id = _issue(10, 60);

        assertEq(id, 1);
        assertEq(_max(id), 60);
        assertEq(_pendingIn(), 60, "counted at the maximum it may execute");
        assertEq(_pendingOut(address(aliceIdentity)), 60, "and against the sender too");
    }

    /// @notice The second validation is narrowed by what the first one already promised.
    function test_requestTransferValidation_Success_WhenTheSecondValidationIsNarrowedByTheFirst() public {
        _issue(10, 60);

        uint256 id = _issue(10, 60);

        assertEq(_max(id), 40, "only the remainder of the cap is left");
        assertEq(_pendingIn(), CAP);
    }

    /// @notice With the cap fully promised, a third validation is refused before any write.
    function test_requestTransferValidation_RevertWhen_TheCapIsFullyReserved() public {
        _issue(10, 60);
        _issue(10, 60);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 1, 1, "");

        assertEq(boundCompliance.lastValidationId(), 2, "nothing was issued");
    }

    /// @notice A rule that keeps no counter of its own is never told about a reservation: the compliance
    ///         records it, and the rule simply reads it on the next question.
    function test_requestTransferValidation_Success_WhenAPlainRuleIsUntouched() public {
        RuleOnlyModule plain = RuleOnlyModule(
            address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(plain));

        _issue(10, 60);

        assertEq(plain.totalHookCalls(), 0, "no action hook on an issuance");
        assertEq(_pendingIn(), 60);
    }

    /// @notice Issue #81, second bug: moving tokens between two wallets of one identity changes no position,
    ///         so it must not consume that identity's own room. Before the fix the reservation was written
    ///         unconditionally and a relocation blocked a legitimate purchase.
    function test_requestTransferValidation_Success_WhenARelocationReservesNothing() public {
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, aliceOther, 10, CAP, "");

        assertTrue(boundCompliance.validationOf(id).relocation, "no reservation against the identity");
        assertEq(_pendingIn(address(aliceIdentity)), 0, "alice's own room is untouched");
        assertEq(_pendingOut(address(aliceIdentity)), 0);
        assertEq(_max(_issue(10, CAP)), CAP, "a third party can still acquire the whole cap");
    }

    // ==== release Tests ====

    /// @notice A settlement releases the whole reservation and applies what was executed, so the room the
    ///         validation did not use comes back.
    function test_handleSettlement_Success_WhenSettlingBelowTheReservation() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        vm.prank(agent);
        token.unpause();
        uint256 first = _issue(10, 60);
        _issue(10, 40);
        assertEq(_pendingIn(), CAP);

        gateway.relay(_liteSettles(gateway, token, _settlement(first, aliceSat, bobSat, 50)));

        assertEq(_pendingIn(), 40, "the settled reservation is gone");
        assertEq(_position(), 50, "and the executed amount became a position");
    }

    /// @notice The keeper's discard releases the reservation, so the next validation gets the full cap.
    function test_discardExpiredValidations_Success_WhenReissuingAfterADiscard() public {
        uint256 id = _issue(10, CAP);
        assertEq(_pendingIn(), CAP);

        _discard(id);

        assertEq(_pendingIn(), 0, "the reservation is released");
        assertEq(_max(_issue(10, CAP)), CAP);
    }

    /// @notice A late settlement is applied anyway, and it breaches when the executed amount is above what the
    ///         rules allow once its reservation is released. The chain that sent it stops issuing.
    function test_handleSettlement_Success_WhenALateSettlementBreachesTheCap() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        vm.prank(agent);
        token.unpause();
        uint256 late = _issue(10, CAP);
        _discard(late);
        uint256 fresh = _issue(10, CAP);
        assertEq(_pendingIn(), CAP, "the fresh validation now holds the whole cap");

        gateway.relay(_liteSettles(gateway, token, _settlement(late, aliceSat, bobSat, CAP)));

        assertEq(_position(), CAP, "the late settlement is applied regardless");
        assertEq(_pendingIn(), CAP, "the fresh reservation still stands");
        assertEq(
            uint8(boundCompliance.statusOf(fresh)),
            uint8(ITransferValidation.ValidationStatus.Pending),
            "the fresh validation is still holding its reservation"
        );
        assertTrue(boundCompliance.isIssuancePaused(polygon), "the origin chain is stopped");

        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, false);
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 1, 1, "");
    }

    /// @notice Issue #81, first bug: a rule bound after a validation was issued still sees its settlement,
    ///         because the position it reads belongs to the compliance and not to the rule. The old slot
    ///         design booked such a settlement against nobody.
    function test_handleSettlement_Success_WhenARuleIsBoundAfterIssuance() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        vm.prank(agent);
        token.unpause();
        uint256 id = _issue(10, 60);

        CappedRecipientModule latecomer = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(latecomer));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (CAP)), address(latecomer));
        vm.stopPrank();

        gateway.relay(_liteSettles(gateway, token, _settlement(id, aliceSat, bobSat, 60)));

        assertEq(_position(), 60, "the settlement landed on bob's identity, not on nobody");
        assertEq(latecomer.transferActionCalls(), 1, "the latecomer was told");
        assertEq(_max(_issue(10, CAP)), 40, "and it now narrows against the real position");
    }

    function _issue(uint256 requestedMin, uint256 requestedMax) private returns (uint256) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, requestedMin, requestedMax);
    }

    function _discard(uint256 id) private {
        vm.warp(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);
    }

    function _max(uint256 id) private view returns (uint256) {
        ITransferValidation.Validation memory validation = boundCompliance.validationOf(id);
        return validation.amountMax;
    }

    function _ledger() private view returns (IComplianceLedger) {
        return IComplianceLedger(address(boundCompliance));
    }

    function _pendingIn() private view returns (uint256) {
        return _pendingIn(address(bobIdentity));
    }

    function _pendingIn(address identity) private view returns (uint256) {
        return _ledger().pendingInOf(identity);
    }

    function _pendingOut(address identity) private view returns (uint256) {
        return _ledger().pendingOutOf(identity);
    }

    function _position() private view returns (uint256) {
        return _ledger().positionOf(address(bobIdentity));
    }

}

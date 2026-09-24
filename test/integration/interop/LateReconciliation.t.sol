// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The exceptional path #32 promised: a settlement that lands after the keeper discarded its validation is
///      applied anyway, the modules catch up with no live reservation, the issuer is warned, and issuance toward
///      that chain stops until the manager resumes it.
contract LateReconciliationTest is InteropSuiteTest {

    uint256 internal constant CAP = 100;
    uint256 internal constant BALANCE = 1000;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    CappedRecipientModule internal cappedRule;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal bobOptimism;
    bytes internal carolSat;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));
        carolSat = _linkSatelliteWallet(charlieIdentity, POLYGON, makeAccount("carolOnPolygon"));

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        boundCompliance.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (CAP)), address(cappedRule));
        vm.stopPrank();
        vm.prank(agent);
        token.unpause();
    }

    /// @notice The full journey: discard, re-issue, then the old settlement lands and is applied regardless.
    function test_handleSettlement_Success_WhenASameChainSettlementLandsAfterTheDiscard() public {
        uint256 late = _issue(aliceSat, bobSat, 10, CAP);
        _discard(late);
        uint256 fresh = _issue(aliceSat, bobSat, 10, CAP);
        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)),
            CAP,
            "the fresh one holds the whole cap"
        );
        uint256 index = _liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP));

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(aliceSat), keccak256(bobSat), late, aliceSat, bobSat, CAP);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(late, polygon, CAP);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.LateReconciliation(late, polygon);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.ValidationIssuancePaused(polygon);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertEq(uint8(boundCompliance.statusOf(fresh)), uint8(ITransferValidation.ValidationStatus.Pending));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - CAP);
        assertEq(token.bridgedBalanceOf(bobSat), CAP);
        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)),
            CAP,
            "caught up with no reservation"
        );
        assertTrue(boundCompliance.isIssuancePaused(polygon));
        assertFalse(token.paused(), "a late leg is an exception, not an emergency");

        // Issuance toward polygon is stopped until the manager resumes it.
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, polygon));
        boundCompliance.requestTransferValidation(aliceSat, carolSat, 10, 50, "");

        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, false);
        // Toward another identity, which has a cap of its own and nothing pending against it.
        assertEq(boundCompliance.validationOf(_issue(aliceSat, carolSat, 10, 50)).amountMax, 50);
    }

    /// @notice A late burn leg records itself and warns; the late mint leg completes the pair and warns again.
    ///         Neither pauses: a first leg commits no module, and the pair leaves the cap intact.
    function test_handleSettlement_Success_WhenACrossChainSettlementLandsAfterTheDiscard() public {
        uint256 late = _issue(aliceSat, bobOptimism, 90, 100);
        _discard(late);
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(late, token, aliceSat, 95));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(late, token, bobOptimism, 95));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationLegConfirmed(late, polygon, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.LateReconciliation(late, polygon);
        polygonGateway.relay(burn);

        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITransferValidation.ValidationStatus.Discarded));
        assertTrue(boundCompliance.validationOf(late).fromLegConsumed);
        assertFalse(boundCompliance.isIssuancePaused(polygon), "a first leg commits nothing, so it breaches nothing");
        assertFalse(boundCompliance.isIssuancePaused(optimism));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - 95, "a late burn leg holds all the same");
        assertEq(token.inTransitOf(late), 95);
        assertEq(token.bridgedBalanceOf(bobOptimism), 0, "nothing credited on the first leg");

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(late, optimism, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.LateReconciliation(late, optimism);
        optimismGateway.relay(mint);

        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - 95);
        assertEq(token.inTransitOf(late), 0);
        assertEq(token.bridgedBalanceOf(bobOptimism), 95);
        assertFalse(boundCompliance.isIssuancePaused(optimism), "95 against a cap of 100 breaches nothing");
    }

    /// @notice A late leg delivered twice is a replay like any other: the token halts.
    function test_handleSettlement_Success_WhenALateLegIsReplayed() public {
        uint256 late = _issue(aliceSat, bobSat, 10, CAP);
        _discard(late);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP)));
        uint256 replay = _liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(late, polygon);
        polygonGateway.relay(replay);

        assertTrue(token.paused());
        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertEq(token.bridgedBalanceOf(bobSat), CAP, "applied once");
    }

    /// @notice The warning never reverts: a chain the manager already paused stays paused, the leg settles.
    function test_handleSettlement_Success_WhenTheChainWasAlreadyPaused() public {
        uint256 late = _issue(aliceSat, bobSat, 10, CAP);
        _discard(late);
        vm.prank(deployer);
        boundCompliance.setIssuancePaused(polygon, true);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(late, aliceSat, bobSat, CAP));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.LateReconciliation(late, polygon);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
        assertTrue(boundCompliance.isIssuancePaused(polygon));
        assertEq(token.bridgedBalanceOf(bobSat), CAP);
    }

    function _issue(bytes memory from, bytes memory to, uint256 min, uint256 max) private returns (uint256) {
        return _requestValidation(address(aliceIdentity), from, to, min, max);
    }

    function _discard(uint256 id) private {
        vm.warp(block.timestamp + VALIDITY_WINDOW + OPTIMISM_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Discarded));
    }

}

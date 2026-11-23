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

/// @dev Late reports warn individually; only completing a movement can breach a rule and pause issuance.
contract LateSettlementPausePolicyTest is InteropSuiteTest {

    uint256 private constant BALANCE = 1000;
    uint256 private constant EXECUTED_AMOUNT = 100;

    ERC7786GatewayMock private polygonGateway;
    ERC7786GatewayMock private optimismGateway;
    CappedRecipientModule private recipientCap;
    bytes private aliceSatellite;
    bytes private bobSatellite;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        aliceSatellite = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("alicePolygon"), BALANCE);
        bobSatellite = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOptimism"));

        recipientCap = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(recipientCap));
        boundCompliance.callModuleFunction(
            abi.encodeCall(CappedRecipientModule.setCap, (BALANCE)), address(recipientCap)
        );
        vm.stopPrank();
        vm.prank(agent);
        token.unpause();
    }

    function test_handleSettlement_pausesOnlyCompletingChainWhenLateBurnThenMintBreaches() public {
        _settleDiscardedPair(true, true);
    }

    function test_handleSettlement_pausesOnlyCompletingChainWhenLateMintThenBurnBreaches() public {
        _settleDiscardedPair(false, true);
    }

    function test_handleSettlement_keepsIssuanceOpenWhenLateBurnThenMintFitsRules() public {
        _settleDiscardedPair(true, false);
    }

    function test_handleSettlement_keepsIssuanceOpenWhenLateMintThenBurnFitsRules() public {
        _settleDiscardedPair(false, false);
    }

    function _settleDiscardedPair(bool _burnFirst, bool _breachesRule) private {
        uint256 validationId = _issueAndDiscard();
        if (_breachesRule) {
            vm.prank(deployer);
            boundCompliance.callModuleFunction(
                abi.encodeCall(CappedRecipientModule.setCap, (EXECUTED_AMOUNT - 1)), address(recipientCap)
            );
        }

        // Both reports together ask the rule once. Asking on the first report as well would fail this count.
        vm.expectCall(address(recipientCap), abi.encodeWithSelector(IModule.allowedAmount.selector), 1);
        bytes32 firstChain = _burnFirst ? polygon : optimism;
        bytes32 completingChain = _burnFirst ? optimism : polygon;
        uint256 firstReport = _queueReport(validationId, _burnFirst);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationLegConfirmed(validationId, firstChain, EXECUTED_AMOUNT);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.LateReconciliation(validationId, firstChain);
        _relayReport(firstReport, _burnFirst);

        ITransferValidation.ValidationStatus expectedStatus = _burnFirst
            ? ITransferValidation.ValidationStatus.DiscardedAwaitingMint
            : ITransferValidation.ValidationStatus.DiscardedAwaitingBurn;
        assertEq(uint8(boundCompliance.statusOf(validationId)), uint8(expectedStatus), "first report only recorded");
        assertFalse(boundCompliance.isIssuancePaused(polygon), "first report cannot pause sender chain");
        assertFalse(boundCompliance.isIssuancePaused(optimism), "first report cannot pause recipient chain");
        assertFalse(token.paused(), "first report cannot halt the token");
        assertEq(recipientCap.totalHookCalls(), 0, "trackers wait for movement completion");
        assertEq(token.bridgedBalanceOf(bobSatellite), 0, "recipient not credited before pair completes");
        assertEq(token.inTransitOf(validationId), _burnFirst ? EXECUTED_AMOUNT : 0, "only a burn creates transit");

        uint256 completingReport = _queueReport(validationId, !_burnFirst);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(validationId, completingChain, EXECUTED_AMOUNT);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.LateReconciliation(validationId, completingChain);
        if (_breachesRule) {
            vm.expectEmit(true, false, false, true, address(boundCompliance));
            emit EventsLib.ValidationIssuancePaused(completingChain);
        }
        _relayReport(completingReport, !_burnFirst);

        assertEq(
            uint8(boundCompliance.statusOf(validationId)),
            uint8(ITransferValidation.ValidationStatus.LateReconciled),
            "both late reports reconciled"
        );
        assertFalse(boundCompliance.isIssuancePaused(firstChain), "first report's chain remains open");
        assertEq(boundCompliance.isIssuancePaused(completingChain), _breachesRule, "pause follows current rules");
        assertFalse(token.paused(), "late reconciliation never adds a global halt");
        _assertCompletedAccounting(validationId);

        if (_breachesRule) {
            vm.prank(address(aliceIdentity));
            vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ValidationIssuancePaused.selector, completingChain));
            boundCompliance.requestTransferValidation(aliceSatellite, bobSatellite, 1, 1, "");
        }
    }

    function _issueAndDiscard() private returns (uint256 validationId) {
        validationId = _requestValidation(
            address(aliceIdentity), aliceSatellite, bobSatellite, EXECUTED_AMOUNT, EXECUTED_AMOUNT
        );
        vm.warp(boundCompliance.validationOf(validationId).releaseAt + 1);
        uint256[] memory validationIds = new uint256[](1);
        validationIds[0] = validationId;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(validationIds);

        assertEq(token.reservedOf(aliceSatellite), 0, "discard released the wallet reservation");
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(ledger.pendingOutOf(address(aliceIdentity)), 0, "discard released sender reservation");
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "discard released recipient reservation");
    }

    function _queueReport(uint256 _validationId, bool _burnReport) private returns (uint256) {
        if (_burnReport) {
            return _liteSettles(polygonGateway, token, _burnLeg(_validationId, token, aliceSatellite, EXECUTED_AMOUNT));
        }
        return _liteSettles(optimismGateway, token, _mintLeg(_validationId, token, bobSatellite, EXECUTED_AMOUNT));
    }

    function _relayReport(uint256 _messageIndex, bool _burnReport) private {
        if (_burnReport) polygonGateway.relay(_messageIndex);
        else optimismGateway.relay(_messageIndex);
    }

    function _assertCompletedAccounting(uint256 _validationId) private view {
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(token.bridgedBalanceOf(aliceSatellite), BALANCE - EXECUTED_AMOUNT, "sender debited once");
        assertEq(token.bridgedBalanceOf(bobSatellite), EXECUTED_AMOUNT, "recipient credited despite any breach");
        assertEq(token.inTransitOf(_validationId), 0, "transit consumed on completion");
        assertEq(token.totalInTransit(), 0, "no outstanding transit");
        assertEq(token.totalSupply(), BALANCE, "supply conserved");
        assertEq(token.totalBridged(), BALANCE, "bridged total conserved");
        assertEq(ledger.positionOf(address(aliceIdentity)), BALANCE - EXECUTED_AMOUNT, "sender position correct");
        assertEq(ledger.positionOf(address(bobIdentity)), EXECUTED_AMOUNT, "recipient position correct");
        assertEq(ledger.positionOf(address(charlieIdentity)), 0, "unused identity position unchanged");
        uint256 totalPositions = ledger.positionOf(address(aliceIdentity)) + ledger.positionOf(address(bobIdentity))
            + ledger.positionOf(address(charlieIdentity));
        assertEq(totalPositions, token.totalSupply(), "actual positions sum to supply");
        assertEq(ledger.pendingOutOf(address(aliceIdentity)), 0, "no sender reservation resurrected");
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "no recipient reservation resurrected");
        assertEq(token.reservedOf(aliceSatellite), 0, "no wallet reservation resurrected");
        assertEq(recipientCap.transferActionCalls(), 1, "tracker caught up exactly once");
    }

}

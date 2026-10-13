// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { AuthorizedRequesterModule } from "contracts/compliance/modular/modules/AuthorizedRequesterModule.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderVerificationModule } from "contracts/compliance/modular/modules/SpenderVerificationModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Issue #127: an institution decides every satellite transfer from data it keeps offchain. The sender's
///      identity asks on chain, the institution's backend reads the ask, runs its private check and requests
///      the validation with the amount it allows. The module lets only the approver role request. Nothing waits
///      on chain, so the issued validation, its reservation and its expiry are those of any other request.
contract AuthorizedRequesterModuleTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 2000;
    /// @dev The approver role, a role of the deployment's choosing.
    uint64 internal constant APPROVER_ROLE = 7777;

    AuthorizedRequesterModule internal rule;
    /// @dev Holds AGENT, which the suite binds to `requestTransferValidation`, and the approver role.
    address internal backend = makeAddr("institutionBackend");
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        rule = _newRule();
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AuthorizedRequesterModule.setApproverRole, (APPROVER_ROLE));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(rule), settings);

        _grantAgentRole(backend);
        suiteManager.grantRole(APPROVER_ROLE, backend, NO_EXECUTION_DELAY);

        vm.prank(agent);
        token.unpause();
    }

    // ==== Declaration Tests ====

    function test_moduleTypes_NamesOnlyRule() public view {
        assertEq(rule.moduleTypes().length, 1);
        assertEq(uint8(rule.moduleTypes()[0]), uint8(IModule.ModuleType.TRANSFER_CHECK));
        assertEq(boundCompliance.getModulesByType(IModule.ModuleType.TRANSFER_CHECK)[0], address(rule));
        assertTrue(rule.isPlugAndPlay());
        assertEq(rule.name(), "AuthorizedRequesterModule");
        assertEq(rule.approverRoleOf(address(boundCompliance)), APPROVER_ROLE);
    }

    function test_setApproverRole_RevertWhen_CalledDirectly() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        rule.setApproverRole(APPROVER_ROLE);
    }

    /// @notice Role zero is the AccessManager's admin role, and what an unset role reads as.
    function test_setApproverRole_RevertWhen_TheRoleIsZero() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        boundCompliance.callModuleFunction(
            abi.encodeCall(AuthorizedRequesterModule.setApproverRole, (0)), address(rule)
        );
    }

    /// @notice Bound without a role, the module refuses every issuance, the approver's included.
    function test_requestTransferValidation_RevertWhen_NoApproverRoleIsSet() public {
        vm.startPrank(deployer);
        boundCompliance.removeModule(address(rule));
        boundCompliance.addModule(address(rule));
        vm.stopPrank();

        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "");
    }

    // ==== .askTransferValidation Tests ====

    /// @notice The identity asks; nothing is stored, reserved or sent, only announced.
    function test_askTransferValidation_Success_WhenTheSenderIdentityAsks() public {
        uint256 freeBefore = token.availableOf(aliceSat);

        vm.expectEmit(address(boundCompliance));
        emit EventsLib.TransferValidationAsked(address(aliceIdentity), aliceSat, bobSat, "", 10, 150);
        vm.prank(address(aliceIdentity));
        boundCompliance.askTransferValidation(aliceSat, bobSat, 10, 150, "");

        assertEq(boundCompliance.lastValidationId(), 0, "nothing issued");
        assertEq(token.availableOf(aliceSat), freeBefore, "nothing reserved");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingOutOf(address(aliceIdentity)), 0);
    }

    /// @notice Only the identity the wallet is linked to may ask: the event says whose movement it is.
    function test_askTransferValidation_RevertWhen_TheCallerIsNotTheSenderIdentity() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, backend, aliceSat));
        boundCompliance.askTransferValidation(aliceSat, bobSat, 10, 150, "");
    }

    function test_askTransferValidation_RevertWhen_TheRangeIsInverted() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRequestedRange.selector, 150, 10));
        boundCompliance.askTransferValidation(aliceSat, bobSat, 150, 10, "");
    }

    // ==== .requestTransferValidation Tests ====

    /// @notice Bound, the module refuses what the sender's identity requests itself: the rule answers 0, so the
    ///         range is empty and nothing is reserved or sent.
    function test_requestTransferValidation_RevertWhen_TheSenderIdentityRequestsItself() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "");

        assertEq(boundCompliance.lastValidationId(), 0, "nothing issued");
    }

    /// @notice An agent may call `requestTransferValidation`, but without the approver role the module refuses
    ///         it: the guarantee does not depend on who else the AccessManager lets call.
    function test_requestTransferValidation_RevertWhen_AnAgentWithoutTheApproverRoleRequests() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "");
    }

    /// @notice The whole flow: alice asks, the backend answers with the amount its private check allows, and
    ///         the validation is issued at that amount, reserved, with an expiry counted from the answer.
    function test_requestTransferValidation_Success_WhenTheBackendAnswersAnAsk() public {
        vm.prank(address(aliceIdentity));
        boundCompliance.askTransferValidation(aliceSat, bobSat, 0, 150, "");
        vm.warp(block.timestamp + 1 hours);

        uint256 id = _requestValidation(backend, aliceSat, bobSat, 0, 100);

        ITransferValidation.Validation memory issued = boundCompliance.validationOf(id);
        assertEq(issued.amountMax, 100, "the backend's verdict is the maximum");
        assertEq(issued.fromIdentity, address(aliceIdentity), "the movement is still alice's");
        assertEq(issued.expiry, block.timestamp + VALIDITY_WINDOW, "expiry starts at the answer");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 100);
    }

    /// @notice The recommended deployment: `requestTransferValidation` bound to the approver role alone, so the
    ///         backend holds none of AGENT's other powers.
    function test_requestTransferValidation_Success_WhenTheSelectorIsBoundToTheApproverRole() public {
        address dedicated = makeAddr("dedicatedBackend");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ITransferValidation.requestTransferValidation.selector;
        suiteManager.setTargetFunctionRole(address(boundCompliance), selectors, APPROVER_ROLE);
        suiteManager.grantRole(APPROVER_ROLE, dedicated, NO_EXECUTION_DELAY);

        uint256 id = _requestValidation(dedicated, aliceSat, bobSat, 0, 100);

        assertEq(boundCompliance.validationOf(id).amountMax, 100);
    }

    /// @notice The backend's verdict is a maximum, not a grant: the other rules still narrow it.
    function test_requestTransferValidation_Success_WhenAnotherRuleNarrowsTheVerdict() public {
        MaxBalancePerIdentityModule cap = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(new MaxBalancePerIdentityModule()),
                    abi.encodeCall(MaxBalancePerIdentityModule.initialize, (address(suiteManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (60));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(cap), settings);

        uint256 id = _requestValidation(backend, aliceSat, bobSat, 0, 100);

        assertEq(boundCompliance.validationOf(id).amountMax, 60, "the onchain cap still applies");
    }

    /// @notice The requester reaches the `SPENDER` modules too, in the same `data`.
    function test_requestTransferValidation_Success_WhenTheSpenderCheckIsToldTheRequester() public {
        SpenderVerificationModule spenderRule = SpenderVerificationModule(
            address(
                new ModuleProxy(
                    address(new SpenderVerificationModule()),
                    abi.encodeCall(SpenderVerificationModule.initialize, (address(suiteManager)))
                )
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(spenderRule));

        IModule.TransferContext memory expected = IModule.TransferContext({
            compliance: address(boundCompliance),
            fromIdentity: address(aliceIdentity),
            toIdentity: address(bobIdentity),
            fromWallet: keccak256(aliceSat),
            toWallet: keccak256(bobSat),
            amountMin: 10,
            amountMax: 100,
            kind: MovementKindLib.CROSS_CHAIN,
            isIssuance: true,
            spender: bobSat,
            data: abi.encode(backend)
        });
        vm.expectCall(address(spenderRule), abi.encodeCall(IModule.checkSpender, (expected)), 1);
        vm.prank(backend);
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, bobSat);
    }

    /// @notice An address the AccessManager never authorised is refused before any rule is asked.
    function test_requestTransferValidation_RevertWhen_TheCallerIsNotAuthorised() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, stranger, aliceSat));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 0, 100, "");
    }

    /// @notice The backend asks, it does not execute: the validation settles only on what the satellite
    ///         reports, exactly as one the identity requested.
    function test_handleSettlement_Success_WhenABackendRequestedValidationSettles() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        uint256 id = _requestValidation(backend, aliceSat, bobSat, 0, 100);

        gateway.relay(_liteSettles(gateway, token, _settlement(id, aliceSat, bobSat, 80)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(IComplianceLedger(address(boundCompliance)).positionOf(address(bobIdentity)), 80);
    }

    /// @notice A relocation between one identity's wallets changes no position and never asks the rules, so
    ///         the identity still requests it itself.
    function test_requestTransferValidation_Success_WhenTheIdentityRelocatesItsOwnTokens() public {
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, aliceOther, 10, 150, "");

        assertTrue(boundCompliance.validationOf(id).relocation);
    }

    /// @notice Unbound, the identity requests itself again: the module is the whole switch.
    function test_requestTransferValidation_Success_WhenTheModuleIsRemoved() public {
        vm.prank(deployer);
        boundCompliance.removeModule(address(rule));

        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 150);

        assertEq(boundCompliance.validationOf(id).amountMax, 150);
    }

    // ==== Native movement Tests ====

    /// @notice Native movements are not judged: they have no requester and cannot wait. A rule over total
    ///         holdings holds over satellite movements only.
    function test_transfer_Success_WhenTheMovementIsNative() public {
        vm.prank(agent);
        token.mint(charlie, 100);

        vm.prank(charlie);
        token.transfer(bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    // ==== Context Tests ====

    /// @notice The module reads the requester from `data` on an issuance and ignores everything else.
    function test_checkTransfer_Success_WhenAskedDirectly() public view {
        IModule.TransferContext memory ctx;
        ctx.compliance = address(boundCompliance);
        ctx.fromIdentity = address(aliceIdentity);
        ctx.isIssuance = true;

        ctx.data = abi.encode(address(aliceIdentity));
        assertEq(rule.checkTransfer(ctx), 0, "the sender's identity is refused");

        ctx.data = abi.encode(backend);
        assertEq(rule.checkTransfer(ctx), type(uint256).max, "the approver is not limited");

        ctx.isIssuance = false;
        ctx.data = "";
        assertEq(rule.checkTransfer(ctx), type(uint256).max, "a native movement is not judged");
    }

    // ==== Helpers ====

    function _newRule() private returns (AuthorizedRequesterModule) {
        return AuthorizedRequesterModule(
            address(
                new ModuleProxy(
                    address(new AuthorizedRequesterModule()),
                    abi.encodeCall(AuthorizedRequesterModule.initialize, (address(suiteManager)))
                )
            )
        );
    }

}

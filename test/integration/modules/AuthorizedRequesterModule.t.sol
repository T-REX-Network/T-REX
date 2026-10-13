// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { AuthorizedRequesterModule } from "contracts/compliance/modular/modules/AuthorizedRequesterModule.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Issue #127: an institution decides every satellite transfer from data it keeps offchain. Its backend
///      runs the private check and requests the validation with the amount it allows; the module makes sure
///      the sender's identity cannot request around it. Nothing waits on chain, so the issued validation, its
///      reservation and its expiry are exactly those of any other request.
contract AuthorizedRequesterModuleTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 2000;
    /// @dev A role of the deployment's choosing, bound to `requestTransferValidation` alone, so the backend
    ///      holds no other power of the agent.
    uint64 internal constant REQUESTER_ROLE = 7777;

    AuthorizedRequesterModule internal rule;
    address internal backend = makeAddr("institutionBackend");
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        rule = AuthorizedRequesterModule(
            address(
                new ModuleProxy(
                    address(new AuthorizedRequesterModule()),
                    abi.encodeCall(AuthorizedRequesterModule.initialize, (address(suiteManager)))
                )
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(rule));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ITransferValidation.requestTransferValidation.selector;
        suiteManager.setTargetFunctionRole(address(boundCompliance), selectors, REQUESTER_ROLE);
        suiteManager.grantRole(REQUESTER_ROLE, backend, NO_EXECUTION_DELAY);

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
    }

    // ==== Issuance Tests ====

    /// @notice Bound, the module refuses what the sender's identity requests itself: the rule answers 0, so the
    ///         range is empty and nothing is reserved or sent.
    function test_requestTransferValidation_RevertWhen_TheSenderIdentityRequestsItself() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "");

        assertEq(boundCompliance.lastValidationId(), 0, "nothing issued");
    }

    /// @notice The backend requests the amount its private check allows. The validation is issued as any other:
    ///         reserved at that amount, with an expiry counted from now.
    function test_requestTransferValidation_Success_WhenTheBackendRequestsItsVerdict() public {
        uint256 id = _requestValidation(backend, aliceSat, bobSat, 0, 100);

        ITransferValidation.Validation memory issued = boundCompliance.validationOf(id);
        assertEq(issued.amountMax, 100, "the backend's verdict is the maximum");
        assertEq(issued.fromIdentity, address(aliceIdentity), "the movement is still alice's");
        assertEq(issued.expiry, block.timestamp + VALIDITY_WINDOW, "expiry starts at the request, as always");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 100);
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

    // ==== Native movement Tests ====

    /// @notice Native movements are not judged: the token's own `transfer` has no requester to check.
    function test_transfer_Success_WhenTheMovementIsNative() public {
        vm.prank(agent);
        token.mint(charlie, 100);

        vm.prank(charlie);
        token.transfer(bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Unbound, the identity requests itself again: the module is the whole switch.
    function test_requestTransferValidation_Success_WhenTheModuleIsRemoved() public {
        vm.prank(deployer);
        boundCompliance.removeModule(address(rule));

        uint256 id = _requestValidation(address(aliceIdentity), aliceSat, bobSat, 10, 150);

        assertEq(boundCompliance.validationOf(id).amountMax, 150);
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
        assertEq(rule.checkTransfer(ctx), type(uint256).max, "an authorised requester is not limited");

        ctx.isIssuance = false;
        ctx.data = "";
        assertEq(rule.checkTransfer(ctx), type(uint256).max, "a native movement is not judged");
    }

}

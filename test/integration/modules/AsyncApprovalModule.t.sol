// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { OffchainApprovalModule } from "contracts/compliance/modular/modules/OffchainApprovalModule.sol";
import { SpenderVerificationModule } from "contracts/compliance/modular/modules/SpenderVerificationModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Issue #127: a service outside the chain approves every transfer of a token, and the compliance stays
///      as it is. A satellite movement: the sender's identity asks the module, the service answers by having
///      the module request the validation, with the approval alive only inside that transaction. A native
///      transfer: the service stores an approval with a count and an expiry, and the transfer uses one up.
contract OffchainApprovalModuleTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 2000;
    /// @dev Bound to `requestTransferValidation` alone, in place of AGENT, and granted to the module.
    uint64 internal constant REQUEST_ROLE = 7777;
    /// @dev Bound to the module's validator functions, and granted to the service.
    uint64 internal constant VALIDATOR_ROLE = 8888;

    OffchainApprovalModule internal module;
    address internal service = makeAddr("validationService");
    uint256 internal approvalCount;
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        module = _newModule();
        _bindRequestRoleTo(address(module), 0);
        vm.prank(deployer);
        boundCompliance.addModule(address(module));

        bytes4[] memory validatorFunctions = new bytes4[](3);
        validatorFunctions[0] = OffchainApprovalModule.approveCrossChainTransfer.selector;
        validatorFunctions[1] = OffchainApprovalModule.approveTransfer.selector;
        validatorFunctions[2] = OffchainApprovalModule.revokeApproval.selector;
        suiteManager.setTargetFunctionRole(address(module), validatorFunctions, VALIDATOR_ROLE);
        suiteManager.grantRole(VALIDATOR_ROLE, service, NO_EXECUTION_DELAY);

        vm.prank(agent);
        token.unpause();
    }

    // ==== Declaration Tests ====

    function test_moduleTypes_NamesRuleAndTracker() public view {
        IModule.ModuleType[] memory types = module.moduleTypes();
        assertEq(types.length, 2);
        assertEq(uint8(types[0]), uint8(IModule.ModuleType.TRANSFER_CHECK));
        assertEq(uint8(types[1]), uint8(IModule.ModuleType.AFTER));
        assertFalse(module.isPlugAndPlay());
        assertEq(module.name(), "OffchainApprovalModule");
    }

    // ==== Binding Tests ====

    /// @notice A module that cannot request validations would only fail later, at the compliance: refuse it now.
    function test_addModule_RevertWhen_TheModuleCannotRequest() public {
        OffchainApprovalModule unprivileged = _newModule();

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ComplianceNotSuitableForBindingToModule.selector, address(unprivileged))
        );
        boundCompliance.addModule(address(unprivileged));
    }

    /// @notice The module calls the compliance directly and cannot schedule, so a delayed grant is refused too.
    function test_addModule_RevertWhen_TheRequestRoleHasADelay() public {
        OffchainApprovalModule delayed = _newModule();
        suiteManager.grantRole(REQUEST_ROLE, address(delayed), 1 days);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.ComplianceNotSuitableForBindingToModule.selector, address(delayed))
        );
        boundCompliance.addModule(address(delayed));
    }

    // ==== .askApproval Tests ====

    /// @notice The investor's one step: an event, nothing stored, reserved or issued.
    function test_askApproval_Success_WhenTheSenderIdentityAsks() public {
        uint256 freeBefore = token.availableOf(aliceSat);

        vm.expectEmit(address(module));
        emit OffchainApprovalModule.ApprovalAsked(
            address(boundCompliance), address(aliceIdentity), aliceSat, bobSat, "", 10, 150
        );
        vm.prank(address(aliceIdentity));
        module.askApproval(address(boundCompliance), aliceSat, bobSat, 10, 150, "");

        assertEq(boundCompliance.lastValidationId(), 0, "nothing issued");
        assertEq(token.availableOf(aliceSat), freeBefore, "nothing reserved");
    }

    /// @notice A native transfer is asked for the same way, with both bounds at the amount.
    function test_askApproval_Success_WhenTheSenderIsNative() public {
        bytes memory nativeCharlie = InteroperableAddress.formatEvmV1(block.chainid, charlie);
        bytes memory nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        vm.expectEmit(address(module));
        emit OffchainApprovalModule.ApprovalAsked(
            address(boundCompliance), address(charlieIdentity), nativeCharlie, nativeBob, "", 100, 100
        );
        vm.prank(address(charlieIdentity));
        module.askApproval(address(boundCompliance), nativeCharlie, nativeBob, 100, 100, "");
    }

    function test_askApproval_RevertWhen_TheCallerIsNotTheSenderIdentity() public {
        vm.prank(service);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, service, aliceSat));
        module.askApproval(address(boundCompliance), aliceSat, bobSat, 10, 150, "");
    }

    function test_askApproval_RevertWhen_TheWalletIsLinkedToNoIdentity() public {
        bytes memory unlinked = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("unlinkedOnPolygon"));
        vm.prank(address(aliceIdentity));
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, address(aliceIdentity), unlinked)
        );
        module.askApproval(address(boundCompliance), unlinked, bobSat, 10, 150, "");
    }

    function test_askApproval_RevertWhen_TheRangeIsInverted() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidRequestedRange.selector, 150, 10));
        module.askApproval(address(boundCompliance), aliceSat, bobSat, 150, 10, "");
    }

    /// @notice A compliance that never bound the module gets no asks: they would be events nobody answers.
    function test_askApproval_RevertWhen_TheComplianceDidNotBindTheModule() public {
        OffchainApprovalModule unbound = _newModule();
        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.ComplianceNotBound.selector);
        unbound.askApproval(address(boundCompliance), aliceSat, bobSat, 10, 150, "");
    }

    // ==== .approveCrossChainTransfer Tests ====

    /// @notice The whole satellite flow: ask, then the service's answer issues the validation at its amount,
    ///         reserved, with an expiry counted from the answer.
    function test_approveCrossChainTransfer_Success_WhenTheServiceAnswersAnAsk() public {
        vm.prank(address(aliceIdentity));
        module.askApproval(address(boundCompliance), aliceSat, bobSat, 0, 150, "");
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(address(module));
        emit OffchainApprovalModule.CrossChainTransferApproved(
            address(boundCompliance), 1, bytes32(uint256(1)), aliceSat, bobSat, 0, 100
        );
        uint256 id = _approveCrossChainTransfer(0, 100);

        ITransferValidation.Validation memory issued = boundCompliance.validationOf(id);
        assertEq(issued.amountMax, 100, "the service's answer is the maximum");
        assertEq(issued.fromIdentity, address(aliceIdentity), "the movement is still alice's");
        assertEq(issued.expiry, block.timestamp + VALIDITY_WINDOW, "expiry starts at the answer");
        assertEq(IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 100);
    }

    /// @notice The compliance caps the range at the wallet's free balance before it asks the rules, so the
    ///         approval must not depend on the requested maximum.
    function test_approveCrossChainTransfer_Success_WhenTheRequestExceedsTheFreeBalance() public {
        uint256 id = _approveCrossChainTransfer(0, BALANCE * 2);

        assertEq(boundCompliance.validationOf(id).amountMax, BALANCE, "capped at what alice holds");
    }

    /// @notice The service's answer is a maximum, not a grant: another rule still narrows it.
    function test_approveCrossChainTransfer_Success_WhenAnotherRuleNarrowsTheAnswer() public {
        _bindCap(60);

        uint256 id = _approveCrossChainTransfer(0, 100);

        assertEq(boundCompliance.validationOf(id).amountMax, 60, "the onchain cap decides");
    }

    /// @notice Another rule refusing reverts the whole answer: nothing is approved that the chain refuses, and
    ///         no approval is left behind for a later request to find.
    function test_approveCrossChainTransfer_RevertWhen_AnotherRuleRefuses() public {
        _bindCap(0);

        vm.prank(service);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ZeroValue.selector));
        module.approveCrossChainTransfer(address(boundCompliance), _nextApprovalId(), aliceSat, bobSat, 0, 100, "");

        assertFalse(module.isApprovalIdUsed(address(boundCompliance), bytes32(approvalCount)), "free for a retry");

        _grantRequestRole(address(aliceIdentity));
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 100, "");
    }

    /// @notice A named spender goes through to the compliance, where the `SPENDER` modules judge it as today.
    function test_approveCrossChainTransfer_Success_WhenASpenderIsNamed() public {
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

        vm.prank(service);
        uint256 id = module.approveCrossChainTransfer(
            address(boundCompliance), _nextApprovalId(), aliceSat, bobSat, 0, 100, bobSat
        );

        assertEq(boundCompliance.validationOf(id).amountMax, 100);
    }

    function test_approveCrossChainTransfer_RevertWhen_TheCallerIsNotAValidator() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        module.approveCrossChainTransfer(address(boundCompliance), _nextApprovalId(), aliceSat, bobSat, 0, 100, "");
    }

    /// @notice A validation the service approved settles on what the satellite reports, as any other.
    function test_handleSettlement_Success_WhenAnApprovedValidationSettles() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        uint256 id = _approveCrossChainTransfer(0, 100);

        gateway.relay(_liteSettles(gateway, token, _settlement(id, aliceSat, bobSat, 80)));

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        assertEq(IComplianceLedger(address(boundCompliance)).positionOf(address(bobIdentity)), 80);
    }

    // ==== Requests around the module ====

    /// @notice With the request role bound to the module alone, the sender's identity may still call
    ///         `requestTransferValidation` for its own wallet, but finds no approval and is refused.
    function test_requestTransferValidation_RevertWhen_TheSenderIdentityRequestsItself() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "");
    }

    /// @notice With a zero lower bound the range is `[0, 0]`, which the compliance refuses rather than issuing a
    ///         validation for nothing.
    function test_requestTransferValidation_RevertWhen_TheSenderIdentityRequestsFromZero() public {
        vm.prank(address(aliceIdentity));
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 0, 150, "");

        assertEq(boundCompliance.lastValidationId(), 0, "nothing issued");
    }

    /// @notice Another holder of the request role, an agent here, finds no approval either.
    function test_requestTransferValidation_RevertWhen_AnotherRequesterBypassesTheModule() public {
        _grantRequestRole(agent);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.requestTransferValidation(aliceSat, bobSat, 10, 150, "");
    }

    /// @notice A relocation between one identity's wallets changes no position and never asks the rules, so
    ///         the identity still requests it itself.
    function test_requestTransferValidation_Success_WhenTheIdentityRelocatesItsOwnTokens() public {
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));

        vm.prank(address(aliceIdentity));
        uint256 id = boundCompliance.requestTransferValidation(aliceSat, aliceOther, 10, 150, "");

        assertTrue(boundCompliance.validationOf(id).relocation);
    }

    // ==== Native transfer Tests ====

    /// @notice One approval, one transfer: the first passes and uses it up, the second is refused.
    function test_transfer_Success_WhenApprovedOnce() public {
        _mintTo(charlie, 200);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.prank(charlie);
        token.transfer(bob, 100);
        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 0, "used up");

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 100);
    }

    /// @notice Two identical transfers approved twice: both pass.
    function test_transfer_Success_WhenApprovedTwice() public {
        _mintTo(charlie, 200);
        uint64 expiry = uint64(block.timestamp + 1 days);
        _approveNative(charlie, bob, 100, expiry);
        _approveNative(charlie, bob, 100, expiry);

        vm.startPrank(charlie);
        token.transfer(bob, 100);
        token.transfer(bob, 100);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 200);
    }

    /// @notice An approval is for an exact amount: any other amount is refused.
    function test_transfer_RevertWhen_TheAmountDiffers() public {
        _mintTo(charlie, 200);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 99);
    }

    /// @notice An offchain "yes" is not valid forever. An expired approval can still be revoked.
    function test_transfer_RevertWhen_TheExpiryInPast() public {
        _mintTo(charlie, 200);
        uint64 expiry = uint64(block.timestamp + 1 days);
        _approveNative(charlie, bob, 100, expiry);
        vm.warp(expiry);

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 100);

        vm.prank(service);
        module.revokeApproval(address(boundCompliance), charlie, bob, 100);
        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 0);
    }

    function test_transfer_RevertWhen_TheApprovalWasRevoked() public {
        _mintTo(charlie, 200);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));
        vm.prank(service);
        module.revokeApproval(address(boundCompliance), charlie, bob, 100);

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 100);
    }

    function test_revokeApproval_RevertWhen_NothingIsApproved() public {
        vm.prank(service);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransferNotApproved.selector, charlie, bob, 100));
        module.revokeApproval(address(boundCompliance), charlie, bob, 100);
    }

    function test_approveTransfer_RevertWhen_TheExpiryHasPassed() public {
        vm.prank(service);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ExpiryInPast.selector, uint64(block.timestamp)));
        module.approveTransfer(address(boundCompliance), _nextApprovalId(), charlie, bob, 100, uint64(block.timestamp));
    }

    function test_approveTransfer_RevertWhen_TheAmountIsZero() public {
        vm.prank(service);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        module.approveTransfer(
            address(boundCompliance), _nextApprovalId(), charlie, bob, 0, uint64(block.timestamp + 1 days)
        );
    }

    function test_approveTransfer_RevertWhen_TheCallerIsNotAValidator() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, charlie));
        module.approveTransfer(
            address(boundCompliance), _nextApprovalId(), charlie, bob, 100, uint64(block.timestamp + 1 days)
        );
    }

    /// @notice An unbind discards every approval: a rebind starts empty.
    function test_addModule_Success_WhenARebindDiscardsTheApprovals() public {
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.startPrank(deployer);
        boundCompliance.removeModule(address(module));
        boundCompliance.addModule(address(module));
        vm.stopPrank();

        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 0);
    }

    /// @notice A mint is the issuer's own action, and is not judged.
    function test_mint_Success_WithoutAnApproval() public {
        _mintTo(bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @notice Moving tokens between one identity's own wallets changes no position, and is not judged.
    function test_transfer_Success_WhenRelocatingBetweenOwnWallets() public {
        address charlieSecond = makeAddr("charlieSecondWallet");
        vm.startPrank(agent);
        token.identityRegistry().registerIdentity(charlieSecond, charlieIdentity, 1);
        token.mint(charlie, 100);
        vm.stopPrank();

        vm.prank(charlie);
        token.transfer(charlieSecond, 100);

        assertEq(token.balanceOf(charlieSecond), 100);
    }

    /// @notice An agent's forced transfer never reaches a `TRANSFER_CHECK` module, and uses up no approval.
    function test_forcedTransfer_Success_WithoutAnApproval() public {
        _mintTo(charlie, 100);
        _approveNative(charlie, bob, 100, uint64(block.timestamp + 1 days));

        vm.prank(agent);
        token.forcedTransfer(charlie, bob, 100);

        assertEq(token.balanceOf(bob), 100);
        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 1, "left for a transfer");
    }

    // ==== Approval id Tests ====

    /// @notice A decision delivered twice, a service retry for instance, approves one movement, not two.
    function test_approveCrossChainTransfer_RevertWhen_TheApprovalIdWasUsed() public {
        bytes32 approvalId = keccak256("ask tx hash, log index");
        vm.startPrank(service);
        module.approveCrossChainTransfer(address(boundCompliance), approvalId, aliceSat, bobSat, 0, 100, "");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApprovalIdAlreadyUsed.selector, approvalId));
        module.approveCrossChainTransfer(address(boundCompliance), approvalId, aliceSat, bobSat, 0, 100, "");
        vm.stopPrank();

        assertEq(boundCompliance.lastValidationId(), 1, "one validation");
        assertTrue(module.isApprovalIdUsed(address(boundCompliance), approvalId));
    }

    /// @notice The same for a native transfer: one transfer is approved, the retry is refused.
    function test_approveTransfer_RevertWhen_TheApprovalIdWasUsed() public {
        bytes32 approvalId = keccak256("ask tx hash, log index");
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.startPrank(service);
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApprovalIdAlreadyUsed.selector, approvalId));
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);
        vm.stopPrank();

        assertEq(module.approvalOf(address(boundCompliance), charlie, bob, 100).count, 1);
    }

    /// @notice A rebind discards the approvals but not the used ids, so a decision retried after it is refused.
    function test_approveTransfer_RevertWhen_TheApprovalIdWasUsedBeforeARebind() public {
        bytes32 approvalId = keccak256("ask tx hash, log index");
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(service);
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);

        vm.startPrank(deployer);
        boundCompliance.removeModule(address(module));
        boundCompliance.addModule(address(module));
        vm.stopPrank();

        vm.prank(service);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ApprovalIdAlreadyUsed.selector, approvalId));
        module.approveTransfer(address(boundCompliance), approvalId, charlie, bob, 100, expiry);
    }

    // ==== Helpers ====

    function _newModule() private returns (OffchainApprovalModule) {
        return OffchainApprovalModule(
            address(
                new ModuleProxy(
                    address(new OffchainApprovalModule()),
                    abi.encodeCall(OffchainApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );
    }

    /// @dev Binds `requestTransferValidation` to the request role alone, in place of AGENT, and grants it.
    function _bindRequestRoleTo(address account, uint32 delay) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ITransferValidation.requestTransferValidation.selector;
        suiteManager.setTargetFunctionRole(address(boundCompliance), selectors, REQUEST_ROLE);
        suiteManager.grantRole(REQUEST_ROLE, account, delay);
    }

    function _grantRequestRole(address account) private {
        suiteManager.grantRole(REQUEST_ROLE, account, NO_EXECUTION_DELAY);
    }

    function _approveCrossChainTransfer(uint256 min, uint256 max) private returns (uint256) {
        vm.prank(service);
        return
            module.approveCrossChainTransfer(
                address(boundCompliance), _nextApprovalId(), aliceSat, bobSat, min, max, ""
            );
    }

    function _approveNative(address from, address to, uint256 amount, uint64 expiry) private {
        vm.prank(service);
        module.approveTransfer(address(boundCompliance), _nextApprovalId(), from, to, amount, expiry);
    }

    /// @dev A fresh id per decision, as a service would give it.
    function _nextApprovalId() private returns (bytes32) {
        return bytes32(++approvalCount);
    }

    function _mintTo(address holder, uint256 amount) private {
        vm.prank(agent);
        token.mint(holder, amount);
    }

    function _bindCap(uint256 cap) private {
        MaxBalancePerIdentityModule capRule = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(new MaxBalancePerIdentityModule()),
                    abi.encodeCall(MaxBalancePerIdentityModule.initialize, (address(suiteManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (cap));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(capRule), settings);
    }

}

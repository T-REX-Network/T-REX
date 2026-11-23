// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderWhitelistModule } from "contracts/compliance/modular/modules/SpenderWhitelistModule.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { RecordingModule, SpenderOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { PreviewContextModule } from "test/integration/mocks/PreviewContextModule.sol";

contract TransferFromCheckTest is TREXSuiteTest {

    UtilityChecker internal checker;
    ModularCompliance internal compliance;
    uint256 internal constant AMOUNT = 100;

    function setUp() public override {
        super.setUp();
        compliance = ModularCompliance(address(token.compliance()));
        checker = UtilityChecker(
            address(
                new UtilityCheckerProxy(address(new UtilityChecker()), abi.encodeCall(UtilityChecker.initialize, ()))
            )
        );
        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();
    }

    function test_getTransferFromStatus_AllowsExactAndUnlimitedApproval() public {
        vm.prank(alice);
        token.approve(charlie, AMOUNT);
        _assertAllPass(_status(AMOUNT));
        assertEq(token.allowance(alice, charlie), AMOUNT, "preview leaves the approval untouched");

        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.allowance(alice, charlie), 0, "the real transfer consumes exact approval");

        vm.prank(alice);
        token.approve(charlie, type(uint256).max);
        _assertAllPass(_status(AMOUNT));
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.allowance(alice, charlie), type(uint256).max, "unlimited approval remains unlimited");
        assertEq(token.balanceOf(bob), AMOUNT * 2, "both previewed transfers execute");
    }

    function test_getTransferFromStatus_SeparatesSpenderDenialFromApprovalAndDirectTransfer() public {
        _bindWhitelist(false);
        vm.prank(alice);
        token.approve(charlie, AMOUNT);

        UtilityChecker.TransferFromStatus memory status = _status(AMOUNT);
        assertTrue(status.inputsValid);
        assertTrue(status.freezeStatus);
        assertTrue(status.eligibilityStatus);
        assertTrue(status.complianceStatus);
        assertFalse(status.spenderStatus, "the bound whitelist denies this spender");
        assertTrue(status.allowanceStatus, "approval does not imply spender permission");

        (bool freezeStatus, bool eligibilityStatus, bool complianceStatus) =
            checker.getTransferStatus(address(token), alice, bob, AMOUNT);
        assertTrue(freezeStatus && eligibilityStatus && complianceStatus, "direct preview keeps its own scope");

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, charlie, alice, bob, AMOUNT));
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.allowance(alice, charlie), AMOUNT, "denial consumes no allowance");
        assertEq(token.balanceOf(bob), 0, "denial moves no tokens");

        vm.prank(alice);
        token.transfer(bob, AMOUNT);
        assertEq(token.balanceOf(bob), AMOUNT, "holder transfer does not consult spender policy");
    }

    function test_getTransferFromStatus_SeparatesInsufficientApprovalFromAllowedSpender() public {
        _bindWhitelist(true);
        vm.prank(alice);
        token.approve(charlie, AMOUNT - 1);

        UtilityChecker.TransferFromStatus memory status = _status(AMOUNT);
        assertTrue(status.spenderStatus, "listed spender passes policy");
        assertFalse(status.allowanceStatus, "approval must cover the full amount");

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, charlie, AMOUNT - 1, AMOUNT)
        );
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.balanceOf(bob), 0, "failed approval check moves nothing");
    }

    function test_getTransferFromStatus_RequiresEverySpenderModuleToAgree() public {
        _bindWhitelist(true);
        SpenderOnlyModule refusing = SpenderOnlyModule(
            address(new ModuleProxy(address(new SpenderOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        compliance.addModule(address(refusing));
        refusing.setSpenderAllowed(false);
        vm.prank(alice);
        token.approve(charlie, AMOUNT);

        assertFalse(_status(AMOUNT).spenderStatus, "one refusal outweighs the other module's permission");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, charlie, alice, bob, AMOUNT));
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
    }

    function test_getTransferFromStatus_PassesTheCompleteContextToRulesAndSpenderModules() public {
        PreviewContextModule module = _bindContextModule();
        bytes32 expected = _contextHash(charlie, AMOUNT);
        module.setExpectedContext(expected);
        vm.prank(alice);
        token.approve(charlie, AMOUNT);

        _assertAllPass(_status(AMOUNT));
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(module.lastContextHash(), expected, "real tracker receives the same complete context");
        assertEq(token.balanceOf(bob), AMOUNT, "both read-only gates and execution agree");
    }

    function test_getTransferFromStatus_RuleCanRefuseOnlyDelegatedTransfers() public {
        PreviewContextModule module = _bindContextModule();
        module.setExpectedContext(_contextHash(address(0), AMOUNT));
        vm.prank(alice);
        token.approve(charlie, AMOUNT);

        assertFalse(_status(AMOUNT).complianceStatus, "rules see the actual spender, not an empty direct context");
        // The same module also refuses the spender, so allow that gate independently to reach the real rule.
        vm.mockCall(address(module), abi.encodeWithSelector(IModule.moduleCheckSpender.selector), abi.encode(true));
        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
    }

    function test_getTransferStatus_AndDetailsUseTheSameKindAsAnOrdinaryTransfer() public {
        PreviewContextModule module = _bindContextModule();
        bytes32 expected = _contextHash(address(0), AMOUNT);
        module.setExpectedContext(expected);

        (bool freezeStatus, bool eligibilityStatus, bool complianceStatus) =
            checker.getTransferStatus(address(token), alice, bob, AMOUNT);
        assertTrue(freezeStatus && eligibilityStatus && complianceStatus, "direct rule context matches execution");
        UtilityChecker.ComplianceCheckDetails[] memory details =
            checker.getTransferDetails(address(token), alice, bob, AMOUNT);
        assertEq(details.length, 1);
        assertTrue(details[0].pass, "rule details carry the TRANSFER kind too");

        vm.prank(alice);
        token.transfer(bob, AMOUNT);
        assertEq(module.lastContextHash(), expected, "tracker confirms the expected direct movement context");
    }

    function test_getTransferFromStatus_ReportsPauseFreeBalanceAndRecipientAdmission() public {
        vm.prank(alice);
        token.approve(charlie, AMOUNT);
        vm.startPrank(agent);
        token.freezePartialTokens(alice, 950);
        token.pause();
        vm.stopPrank();

        UtilityChecker.TransferFromStatus memory status = _status(AMOUNT);
        assertFalse(status.freezeStatus, "pause and insufficient free balance are movement restrictions");
        assertTrue(status.allowanceStatus);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);

        status = checker.getTransferFromStatus(address(token), charlie, alice, another, AMOUNT);
        assertFalse(status.eligibilityStatus, "unknown recipient fails admission independently");
    }

    function test_getTransferFromStatus_AllowsZeroAmountWithZeroApproval() public {
        _assertAllPass(_status(0));
        vm.prank(charlie);
        token.transferFrom(alice, bob, 0);
        assertEq(token.balanceOf(alice), 1000, "zero transfer leaves the source unchanged");
        assertEq(token.balanceOf(bob), 0, "zero transfer credits nothing");
        assertEq(token.allowance(alice, charlie), 0, "zero transfer requires no positive approval");
    }

    function test_getTransferFromStatus_RejectsZeroWalletInputs() public view {
        assertFalse(checker.getTransferFromStatus(address(token), address(0), alice, bob, AMOUNT).inputsValid);
        assertFalse(checker.getTransferFromStatus(address(token), charlie, address(0), bob, AMOUNT).inputsValid);
        assertFalse(checker.getTransferFromStatus(address(token), charlie, alice, address(0), AMOUNT).inputsValid);
    }

    function testFuzz_getTransferFromStatus_AgreesWithAllowanceAndActualMovement(uint256 amount, uint256 approval)
        public
    {
        amount = bound(amount, 0, 1000);
        approval = bound(approval, 0, 1000);
        vm.prank(alice);
        token.approve(charlie, approval);

        UtilityChecker.TransferFromStatus memory status = _status(amount);
        assertTrue(status.inputsValid && status.freezeStatus && status.eligibilityStatus);
        assertTrue(status.complianceStatus && status.spenderStatus, "the suite imposes no module restriction");
        assertEq(status.allowanceStatus, approval >= amount, "approval flag agrees with the requested amount");
        assertEq(token.allowance(alice, charlie), approval, "preview does not consume the approval");

        if (approval < amount) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, charlie, approval, amount)
            );
            vm.prank(charlie);
            token.transferFrom(alice, bob, amount);
            assertEq(token.balanceOf(alice), 1000, "rejected movement leaves the source unchanged");
            assertEq(token.balanceOf(bob), 0, "rejected movement leaves the recipient unchanged");
            assertEq(token.allowance(alice, charlie), approval, "rejected movement preserves approval");
        } else {
            vm.prank(charlie);
            token.transferFrom(alice, bob, amount);
            assertEq(token.balanceOf(alice), 1000 - amount, "covered movement debits the source");
            assertEq(token.balanceOf(bob), amount, "covered movement credits the recipient");
            assertEq(token.allowance(alice, charlie), approval - amount, "only execution consumes approval");
        }
    }

    function test_getTransferFromStatus_PropagatesModuleReverts() public {
        PreviewContextModule module = _bindContextModule();
        module.setRevertOnCheck(true);
        vm.expectRevert(PreviewContextModule.PreviewCheckReverted.selector);
        checker.getTransferFromStatus(address(token), charlie, alice, bob, AMOUNT);
    }

    function test_getTransferFromStatus_DoesNotPromiseThatPostMovementHooksSucceed() public {
        PreviewContextModule module = _bindContextModule();
        module.setExpectedContext(_contextHash(charlie, AMOUNT));
        module.setRevertOnTransfer(true);
        vm.prank(alice);
        token.approve(charlie, AMOUNT);

        _assertAllPass(_status(AMOUNT));
        vm.expectRevert(PreviewContextModule.PreviewHookReverted.selector);
        vm.prank(charlie);
        token.transferFrom(alice, bob, AMOUNT);
        assertEq(token.balanceOf(bob), 0, "failed hook rolls the real operation back");
        assertEq(token.allowance(alice, charlie), AMOUNT, "failed operation restores the approval");
    }

    function _status(uint256 amount) private view returns (UtilityChecker.TransferFromStatus memory) {
        return checker.getTransferFromStatus(address(token), charlie, alice, bob, amount);
    }

    function _assertAllPass(UtilityChecker.TransferFromStatus memory status) private pure {
        assertTrue(status.inputsValid, "wallet inputs are valid");
        assertTrue(status.freezeStatus, "native movement restrictions pass");
        assertTrue(status.eligibilityStatus, "recipient admission passes");
        assertTrue(status.complianceStatus, "rules permit the amount");
        assertTrue(status.spenderStatus, "spender policy permits the caller");
        assertTrue(status.allowanceStatus, "approval covers the amount");
    }

    function _bindWhitelist(bool allow) private returns (SpenderWhitelistModule module) {
        module = SpenderWhitelistModule(
            address(
                new ModuleProxy(
                    address(new SpenderWhitelistModule()),
                    abi.encodeCall(SpenderWhitelistModule.initialize, (address(accessManager)))
                )
            )
        );
        vm.startPrank(deployer);
        compliance.addModule(address(module));
        if (allow) {
            compliance.callModuleFunction(
                abi.encodeCall(
                    SpenderWhitelistModule.allowSpender, (InteroperableAddress.formatEvmV1(block.chainid, charlie))
                ),
                address(module)
            );
        }
        vm.stopPrank();
    }

    function _bindContextModule() private returns (PreviewContextModule module) {
        module = PreviewContextModule(
            address(
                new ModuleProxy(
                    address(new PreviewContextModule()), abi.encodeCall(PreviewContextModule.initialize, ())
                )
            )
        );
        vm.prank(deployer);
        compliance.addModule(address(module));
    }

    function _contextHash(address spender, uint256 amount) private view returns (bytes32) {
        IModule.TransferContext memory context;
        context.compliance = address(compliance);
        context.fromIdentity = address(aliceIdentity);
        context.toIdentity = address(bobIdentity);
        context.fromWallet = bytes32(uint256(uint160(alice)));
        context.toWallet = bytes32(uint256(uint160(bob)));
        context.amountMin = amount;
        context.amountMax = amount;
        context.kind = MovementKindLib.TRANSFER;
        if (spender != address(0)) context.spender = InteroperableAddress.formatEvmV1(block.chainid, spender);
        return keccak256(abi.encode(context));
    }

}

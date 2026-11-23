// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { UtilityChecker } from "contracts/utils/UtilityChecker.sol";
import { UtilityCheckerProxy } from "contracts/utils/UtilityCheckerProxy.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { PreviewContextModule } from "test/integration/mocks/PreviewContextModule.sol";

contract MintBurnCheckTest is TREXSuiteTest {

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
        vm.prank(agent);
        token.mint(alice, 1000);
    }

    function test_getMintStatus_AllowsPausedMintToAnAddressFrozenRecipient() public {
        vm.prank(agent);
        token.setAddressFrozen(bob, true);
        assertTrue(token.paused(), "new suites start paused");

        UtilityChecker.MintStatus memory status = checker.getMintStatus(address(token), bob, AMOUNT);
        assertTrue(status.inputsValid);
        assertTrue(status.eligibilityStatus);
        assertTrue(status.complianceStatus);
        (bool legacyFreezeStatus,,) = checker.getTransferStatus(address(token), address(0), bob, AMOUNT);
        assertFalse(legacyFreezeStatus, "the ordinary-transfer endpoint retains its legacy zero-side behavior");

        vm.prank(agent);
        token.mint(bob, AMOUNT);
        assertEq(token.balanceOf(bob), AMOUNT, "mint does not inherit ordinary-transfer freeze or pause gates");
        assertTrue(token.isFrozen(bob), "mint does not clear the address freeze");
    }

    function test_getMintStatus_PassesTheSameMintContextAsTheActualOperation() public {
        PreviewContextModule module = _bindContextModule();
        bytes32 expected = _mintContextHash(bob, AMOUNT);
        module.setExpectedContext(expected);

        UtilityChecker.MintStatus memory status = checker.getMintStatus(address(token), bob, AMOUNT);
        assertTrue(status.inputsValid && status.eligibilityStatus && status.complianceStatus, "MINT context passes");
        vm.prank(agent);
        token.mint(bob, AMOUNT);
        assertEq(module.lastContextHash(), expected, "mint's tracker receives the same context that the rule saw");
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    function test_getMintStatus_ReportsRuleDenialAndRecipientAdmissionSeparately() public {
        PreviewContextModule module = _bindContextModule();
        module.setExpectedContext(_mintContextHash(bob, AMOUNT));

        UtilityChecker.MintStatus memory denied = checker.getMintStatus(address(token), bob, AMOUNT + 1);
        assertTrue(denied.eligibilityStatus, "holder is eligible regardless of rule denial");
        assertFalse(denied.complianceStatus, "the bound rule refuses this mint amount");
        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        vm.prank(agent);
        token.mint(bob, AMOUNT + 1);

        UtilityChecker.MintStatus memory unknown = checker.getMintStatus(address(token), another, AMOUNT);
        assertFalse(unknown.eligibilityStatus, "an unknown recipient fails admission");
        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(agent);
        token.mint(another, AMOUNT);
    }

    function test_getMintStatus_PropagatesReadOnlyModuleReverts() public {
        PreviewContextModule module = _bindContextModule();
        module.setRevertOnCheck(true);
        vm.expectRevert(PreviewContextModule.PreviewCheckReverted.selector);
        checker.getMintStatus(address(token), bob, AMOUNT);
    }

    function test_getMintStatus_ExcludesCallerAuthorizationAndPostMovementHooks() public {
        PreviewContextModule module = _bindContextModule();
        module.setExpectedContext(_mintContextHash(bob, AMOUNT));
        module.setRevertOnTransfer(true);
        UtilityChecker.MintStatus memory status = checker.getMintStatus(address(token), bob, AMOUNT);
        assertTrue(status.inputsValid && status.eligibilityStatus && status.complianceStatus);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        vm.prank(alice);
        token.mint(bob, AMOUNT);

        vm.expectRevert(PreviewContextModule.PreviewHookReverted.selector);
        vm.prank(agent);
        token.mint(bob, AMOUNT);
        assertEq(token.balanceOf(bob), 0, "reverting post-mint hook rolls issuance back");
        assertEq(token.totalSupply(), 1000);
    }

    function test_getBurnStatus_AllowsFreeBalanceWithoutRecipientAdmission() public {
        UtilityChecker.BurnStatus memory status = checker.getBurnStatus(address(token), alice, AMOUNT);
        assertTrue(status.inputsValid);
        assertTrue(status.balanceStatus);
        assertEq(status.unfreezeAmount, 0, "burn stays inside free balance");
        assertEq(token.balanceOf(alice), 1000, "preview moves no tokens");

        vm.prank(agent);
        token.burn(alice, AMOUNT);
        assertEq(token.balanceOf(alice), 1000 - AMOUNT);
        assertEq(token.totalSupply(), 1000 - AMOUNT, "real burn reduces issuance");
    }

    function test_getBurnStatus_ReportsExactUnfreezeWhilePausedAndAddressFrozen() public {
        vm.startPrank(agent);
        token.setAddressFrozen(alice, true);
        token.freezePartialTokens(alice, 950);
        vm.stopPrank();

        UtilityChecker.BurnStatus memory status = checker.getBurnStatus(address(token), alice, AMOUNT);
        assertTrue(status.inputsValid && status.balanceStatus, "all native tokens are burnable");
        assertEq(status.unfreezeAmount, 50, "only the shortfall beyond free balance is released");
        assertEq(token.getFrozenTokens(alice), 950, "preview leaves the freeze intact");

        vm.prank(agent);
        token.burn(alice, AMOUNT);
        assertEq(token.getFrozenTokens(alice), 900, "actual burn releases exactly the previewed amount");
        assertEq(token.balanceOf(alice), 900);
        assertTrue(token.paused(), "burn leaves the pause intact");
        assertTrue(token.isFrozen(alice), "burn leaves the address freeze intact");
    }

    function test_getBurnStatus_RejectsAnAmountAboveTotalBalanceWithoutAnUnfreeze() public {
        vm.prank(agent);
        token.freezePartialTokens(alice, 950);
        UtilityChecker.BurnStatus memory status = checker.getBurnStatus(address(token), alice, 1001);
        assertTrue(status.inputsValid);
        assertFalse(status.balanceStatus);
        assertEq(status.unfreezeAmount, 0, "an impossible burn has no prospective freeze release");

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1000, 1001));
        vm.prank(agent);
        token.burn(alice, 1001);
        assertEq(token.getFrozenTokens(alice), 950, "rejected burn preserves frozen tokens");
    }

    function test_getBurnStatus_SkipsRulesEvenWhenTheyRevert() public {
        PreviewContextModule module = _bindContextModule();
        module.setRevertOnCheck(true);
        UtilityChecker.BurnStatus memory status = checker.getBurnStatus(address(token), alice, AMOUNT);
        assertTrue(status.balanceStatus, "burn preview asks no admission or rule questions");
        vm.prank(agent);
        token.burn(alice, AMOUNT);
        assertEq(token.balanceOf(alice), 1000 - AMOUNT, "real burn also skips the reverting rule");
    }

    function test_getBurnStatus_DoesNotPromiseThatThePostMovementHookSucceeds() public {
        PreviewContextModule module = _bindContextModule();
        module.setRevertOnTransfer(true);
        assertTrue(checker.getBurnStatus(address(token), alice, AMOUNT).balanceStatus);

        vm.expectRevert(PreviewContextModule.PreviewHookReverted.selector);
        vm.prank(agent);
        token.burn(alice, AMOUNT);
        assertEq(token.balanceOf(alice), 1000, "failed tracker restores the burned balance");
    }

    function test_mintAndBurnPreviews_AllowZeroAmounts() public {
        UtilityChecker.MintStatus memory mintStatus = checker.getMintStatus(address(token), bob, 0);
        UtilityChecker.BurnStatus memory burnStatus = checker.getBurnStatus(address(token), alice, 0);
        assertTrue(mintStatus.inputsValid && mintStatus.eligibilityStatus && mintStatus.complianceStatus);
        assertTrue(burnStatus.inputsValid && burnStatus.balanceStatus);
        assertEq(burnStatus.unfreezeAmount, 0);
        vm.startPrank(agent);
        token.mint(bob, 0);
        token.burn(alice, 0);
        vm.stopPrank();
        assertEq(token.totalSupply(), 1000, "zero operations leave issuance unchanged");
        assertEq(token.balanceOf(bob), 0);
    }

    function test_mintAndBurnPreviews_RejectZeroWallets() public view {
        UtilityChecker.MintStatus memory mintStatus = checker.getMintStatus(address(token), address(0), AMOUNT);
        assertFalse(mintStatus.inputsValid || mintStatus.eligibilityStatus || mintStatus.complianceStatus);
        UtilityChecker.BurnStatus memory burnStatus = checker.getBurnStatus(address(token), address(0), AMOUNT);
        assertFalse(burnStatus.inputsValid || burnStatus.balanceStatus);
        assertEq(burnStatus.unfreezeAmount, 0);
    }

    function testFuzz_getBurnStatus_MatchesTheActualFreezeRelease(uint256 frozenAmount, uint256 burnAmount) public {
        frozenAmount = bound(frozenAmount, 0, 1000);
        burnAmount = bound(burnAmount, 0, 1000);
        vm.prank(agent);
        token.freezePartialTokens(alice, frozenAmount);
        UtilityChecker.BurnStatus memory status = checker.getBurnStatus(address(token), alice, burnAmount);
        assertTrue(status.balanceStatus, "bounded burn is covered by total balance");

        vm.prank(agent);
        token.burn(alice, burnAmount);
        assertEq(
            token.getFrozenTokens(alice), frozenAmount - status.unfreezeAmount, "predicted release equals execution"
        );
        assertEq(token.balanceOf(alice), 1000 - burnAmount, "predicted burn amount equals execution");
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

    function _mintContextHash(address recipient, uint256 amount) private view returns (bytes32) {
        IModule.TransferContext memory context;
        context.compliance = address(compliance);
        context.toIdentity = address(bobIdentity);
        context.toWallet = bytes32(uint256(uint160(recipient)));
        context.amountMin = amount;
        context.amountMax = amount;
        context.kind = MovementKindLib.MINT;
        return keccak256(abi.encode(context));
    }

}

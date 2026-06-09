// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TestModule } from "../mocks/TestModule.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TokenTransferTest is TREXSuiteTest {

    IdentityRegistry public identityRegistry;

    function setUp() public override {
        super.setUp();

        identityRegistry = IdentityRegistry(address(token.identityRegistry()));

        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.mint(bob, 500);
        token.unpause();
        vm.stopPrank();
    }

    /// @notice Helper to deploy TestModule + ModularCompliance setup for compliance tests
    function _deployComplianceSetup() internal returns (ModularCompliance, TestModule) {
        // Deploy TestModule
        TestModule testModuleImplementation = new TestModule();
        bytes memory moduleInitData = abi.encodeCall(TestModule.initialize, ());
        ModuleProxy testModuleProxy = new ModuleProxy(address(testModuleImplementation), moduleInitData);
        TestModule testModule = TestModule(address(testModuleProxy));

        // Add module to compliance
        ModularCompliance compliance = ModularCompliance(address(token.compliance()));
        vm.prank(deployer);
        compliance.addModule(address(testModule));

        return (compliance, testModule);
    }

    // ============ approve() Tests ============

    /// @notice Should approve a contract to spend a certain amount of tokens
    function test_approve_Success() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Approval(alice, another, 100);
        token.approve(another, 100);

        assertEq(token.allowance(alice, another), 100);
    }

    // ============ transfer() Tests ============

    /// @notice Should revert when token is paused
    function test_transfer_RevertWhen_Paused() public {
        vm.prank(agent);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transfer(bob, 100);
    }

    /// @notice Should revert when recipient balance is frozen
    function test_transfer_RevertWhen_RecipientFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(bob, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, bob));
        token.transfer(bob, 100);
    }

    /// @notice Should revert when sender balance is frozen
    function test_transfer_RevertWhen_SenderFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, alice));
        token.transfer(bob, 100);
    }

    /// @notice Should revert when sender has not enough balance
    function test_transfer_RevertWhen_InsufficientBalance() public {
        uint256 balance = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1000)
        );
        token.transfer(bob, balance + 1000);
    }

    /// @notice Should revert when sender has not enough balance unfrozen
    function test_transfer_RevertWhen_InsufficientUnfrozenBalance() public {
        uint256 balance = token.balanceOf(alice);
        vm.prank(agent);
        token.freezePartialTokens(alice, balance - 100);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100, balance));
        token.transfer(bob, balance);
    }

    /// @notice Should revert when recipient identity is not verified
    function test_transfer_RevertWhen_RecipientNotVerified() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        token.transfer(another, 100);
    }

    /// @notice Should revert when transfer breaks compliance rules (covers AND condition: isVerified=true, canTransfer=false)
    function test_transfer_RevertWhen_ComplianceBreaks() public {
        (ModularCompliance compliance, TestModule testModule) = _deployComplianceSetup();

        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Block transfers in module
        bytes memory blockModuleCall = abi.encodeWithSignature("blockModule(bool)", true);
        vm.prank(deployer);
        compliance.callModuleFunction(blockModuleCall, address(testModule));

        // bob is verified but compliance blocks transfer (covers isVerified=true && canTransfer=false branch)
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 100);
    }

    /// @notice Should transfer tokens when transfer is compliant
    function test_transfer_Success() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 100);
        token.transfer(bob, 100);
    }

    // ============ batchTransfer() Tests ============

    /// @notice Should transfer tokens
    function test_batchTransfer_Success() public {
        address[] memory toList = new address[](2);
        toList[0] = bob;
        toList[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 100);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 200);
        token.batchTransfer(toList, amounts);
    }

    // ============ transferFrom() Tests ============

    /// @notice Should revert when token is paused
    function test_transferFrom_RevertWhen_Paused() public {
        // Approve before pausing so allowance check passes when transferFrom runs.
        vm.prank(alice);
        token.approve(alice, 100);

        vm.prank(agent);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transferFrom(alice, bob, 100);
    }

    /// @notice Should revert when sender address is frozen
    function test_transferFrom_RevertWhen_SenderFrozen() public {
        vm.prank(alice);
        token.approve(alice, 100);

        vm.prank(agent);
        token.setAddressFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, alice));
        token.transferFrom(alice, bob, 100);
    }

    /// @notice Should revert when recipient address is frozen
    function test_transferFrom_RevertWhen_RecipientFrozen() public {
        vm.prank(alice);
        token.approve(alice, 100);

        vm.prank(agent);
        token.setAddressFrozen(bob, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, bob));
        token.transferFrom(alice, bob, 100);
    }

    /// @notice Should revert when sender has not enough balance
    function test_transferFrom_RevertWhen_InsufficientBalance() public {
        uint256 balance = token.balanceOf(alice);

        // Approve the excessive amount so allowance check passes; balance check fires inside _update.
        vm.prank(alice);
        token.approve(alice, balance + 1000);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1000)
        );
        token.transferFrom(alice, bob, balance + 1000);
    }

    /// @notice Should revert when sender has not enough balance unfrozen
    function test_transferFrom_RevertWhen_InsufficientUnfrozenBalance() public {
        uint256 balance = token.balanceOf(alice);
        vm.prank(agent);
        token.freezePartialTokens(alice, balance - 100);

        // Approve the attempted amount so allowance check passes; free-balance check fires inside _update.
        vm.prank(alice);
        token.approve(alice, balance);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100, balance));
        token.transferFrom(alice, bob, balance);
    }

    /// @notice Should revert when recipient identity is not verified
    function test_transferFrom_RevertWhen_RecipientNotVerified() public {
        vm.prank(alice);
        token.approve(alice, 100);

        vm.prank(alice);
        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        token.transferFrom(alice, another, 100);
    }

    /// @notice Should revert when transfer breaks compliance rules (covers AND condition: isVerified=true, canTransfer=false)
    function test_transferFrom_RevertWhen_ComplianceBreaks() public {
        (ModularCompliance compliance, TestModule testModule) = _deployComplianceSetup();

        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Block transfers in module
        bytes memory blockModuleCall = abi.encodeWithSignature("blockModule(bool)", true);
        vm.prank(deployer);
        compliance.callModuleFunction(blockModuleCall, address(testModule));

        vm.prank(alice);
        token.approve(alice, 100);

        // bob is verified but compliance blocks transfer (covers isVerified=true && canTransfer=false branch)
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        token.transferFrom(alice, bob, 100);
    }

    /// @notice Should transfer tokens and reduce allowance of transferred value
    function test_transferFrom_Success() public {
        vm.prank(alice);
        token.approve(another, 100);

        vm.prank(another);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 100);
        token.transferFrom(alice, bob, 100);

        assertEq(token.allowance(alice, another), 0);
    }

    /// @notice Should decrease allowance when default allowance is NOT enabled (first part of OR condition)
    function test_transferFrom_DecreasesAllowance_WhenDefaultAllowanceNotEnabled() public {
        // Ensure default allowance is NOT enabled for another
        vm.prank(alice);
        token.approve(another, 200);

        vm.prank(another);
        token.transferFrom(alice, bob, 100);

        // Allowance should be decreased
        assertEq(token.allowance(alice, another), 100);
    }

    // ============ forcedTransfer() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_forcedTransfer_RevertWhen_NotAgent() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        token.forcedTransfer(alice, bob, 100);
    }

    /// @notice Should revert when agent permission is restricted
    function test_forcedTransfer_RevertWhen_AgentRestricted() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: true,
            disablePause: false
        });

        vm.prank(deployer);
        token.setAgentRestrictions(agent, restrictions);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "force transfer disabled"));
        token.forcedTransfer(alice, bob, 100);
    }

    /// @notice Should revert when source wallet has not enough balance
    function test_forcedTransfer_RevertWhen_InsufficientBalance() public {
        uint256 balance = token.balanceOf(alice);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1000)
        );
        token.forcedTransfer(alice, bob, balance + 1000);
    }

    /// @notice Should revert when recipient identity is not verified
    function test_forcedTransfer_RevertWhen_RecipientNotVerified() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        token.forcedTransfer(alice, another, 100);
    }

    /// @notice Should still transfer tokens when transfer breaks compliance rules
    function test_forcedTransfer_Success_WhenComplianceBreaks() public {
        (ModularCompliance compliance, TestModule testModule) = _deployComplianceSetup();

        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Block transfers in module
        bytes memory blockModuleCall = abi.encodeWithSignature("blockModule(bool)", true);
        vm.prank(deployer);
        compliance.callModuleFunction(blockModuleCall, address(testModule));

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 100);
        token.forcedTransfer(alice, bob, 100);
    }

    /// @notice Should unfreeze tokens when amount is greater than unfrozen balance
    function test_forcedTransfer_Success_UnfreezesTokens() public {
        uint256 balance = token.balanceOf(alice);
        vm.prank(agent);
        token.freezePartialTokens(alice, balance - 100);

        uint256 transferAmount = balance - 50;
        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, transferAmount);
        token.forcedTransfer(alice, bob, transferAmount);

        // Check unfrozen tokens separately (event order may vary)
        assertEq(token.getFrozenTokens(alice), 50);
    }

    /// @notice Should transfer without unfreezing when amount is less than or equal to free balance
    function test_forcedTransfer_Success_NoUnfreezing() public {
        uint256 balance = token.balanceOf(alice);
        vm.prank(agent);
        token.freezePartialTokens(alice, 200);

        // Transfer amount less than free balance (no unfreezing needed)
        uint256 transferAmount = balance - 300;
        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, transferAmount);
        token.forcedTransfer(alice, bob, transferAmount);

        // Frozen tokens should remain unchanged
        assertEq(token.getFrozenTokens(alice), 200);
    }

    // ============ mint() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_mint_RevertWhen_NotAgent() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        token.mint(alice, 100);
    }

    /// @notice Should revert when agent permission is restricted
    function test_mint_RevertWhen_AgentRestricted() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        vm.prank(deployer);
        token.setAgentRestrictions(agent, restrictions);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "mint disabled"));
        token.mint(alice, 100);
    }

    /// @notice Should revert when recipient identity is not verified
    function test_mint_RevertWhen_RecipientNotVerified() public {
        vm.prank(agent);
        vm.expectRevert();
        token.mint(another, 100);
    }

    /// @notice Should revert when the mint breaks compliance rules
    function test_mint_RevertWhen_ComplianceBreaks() public {
        (ModularCompliance compliance, TestModule testModule) = _deployComplianceSetup();

        vm.prank(deployer);
        token.setCompliance(address(compliance));

        // Block transfers in module
        bytes memory blockModuleCall = abi.encodeWithSignature("blockModule(bool)", true);
        vm.prank(deployer);
        compliance.callModuleFunction(blockModuleCall, address(testModule));

        vm.prank(agent);
        vm.expectRevert();
        token.mint(alice, 100);
    }

    // ============ burn() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_burn_RevertWhen_NotAgent() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        token.burn(alice, 100);
    }

    /// @notice Should revert when agent permission is restricted
    function test_burn_RevertWhen_AgentRestricted() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: true,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        vm.prank(deployer);
        token.setAgentRestrictions(agent, restrictions);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "burn disabled"));
        token.burn(alice, 100);
    }

    /// @notice Should revert when source wallet has not enough balance
    function test_burn_RevertWhen_InsufficientBalance() public {
        uint256 balance = token.balanceOf(alice);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1000)
        );
        token.burn(alice, balance + 1000);
    }

    /// @notice Should burn and decrease frozen balance when amount to burn is greater than unfrozen balance
    function test_burn_Success_DecreasesFrozenBalance() public {
        uint256 balance = token.balanceOf(alice);
        vm.prank(agent);
        token.freezePartialTokens(alice, balance - 100);

        uint256 burnAmount = balance - 50;
        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, address(0), burnAmount);
        token.burn(alice, burnAmount);

        // Check frozen tokens (event order may vary)
        assertEq(token.getFrozenTokens(alice), 50);
    }

    // ============ freezePartialTokens() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_freezePartialTokens_RevertWhen_NotAgent() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        token.freezePartialTokens(alice, 100);
    }

    /// @notice Should revert when agent permission is restricted
    function test_freezePartialTokens_RevertWhen_AgentRestricted() public {
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: true,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        vm.prank(deployer);
        token.setAgentRestrictions(agent, restrictions);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "partial freeze disabled"));
        token.freezePartialTokens(alice, 100);
    }

    // ============ unfreezePartialTokens() Tests ============

    /// @notice Should revert when sender is not an agent
    function test_unfreezePartialTokens_RevertWhen_NotAgent() public {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        token.unfreezePartialTokens(alice, 100);
    }

    /// @notice Should revert when agent permission is restricted
    function test_unfreezePartialTokens_RevertWhen_AgentRestricted() public {
        // Freeze some tokens first (before restrictions are set)
        vm.prank(agent);
        token.freezePartialTokens(alice, 200);

        // Now set restrictions to disable partial freeze
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: true,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        vm.prank(deployer);
        token.setAgentRestrictions(agent, restrictions);

        // Now try to unfreeze, should revert because partial freeze is disabled
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "partial freeze disabled"));
        token.unfreezePartialTokens(alice, 100);
    }

    /// @notice Should revert when amount exceeds frozen tokens
    function test_unfreezePartialTokens_RevertWhen_AmountExceedsFrozen() public {
        vm.prank(agent);
        token.freezePartialTokens(alice, 200);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AmountAboveFrozenTokens.selector, 5000, 200));
        token.unfreezePartialTokens(alice, 5000);
    }

    /// @notice Should unfreeze when freeze amount does not exceed the balance
    function test_unfreezePartialTokens_Success() public {
        vm.prank(agent);
        token.freezePartialTokens(alice, 200);

        vm.prank(agent);
        vm.expectEmit(true, false, false, false, address(token));
        emit ERC3643EventsLib.TokensUnfrozen(alice, 100);
        token.unfreezePartialTokens(alice, 100);
    }

    // ============ batchForcedTransfer() Tests ============

    /// @notice Should perform batch forced transfers
    function test_batchForcedTransfer_Success() public {
        address[] memory fromList = new address[](2);
        fromList[0] = alice;
        fromList[1] = alice;
        address[] memory toList = new address[](2);
        toList[0] = bob;
        toList[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 100);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, bob, 200);
        token.batchForcedTransfer(fromList, toList, amounts);

        assertEq(token.balanceOf(bob), 500 + 300);
    }

    // ============ batchMint() Tests ============

    /// @notice Should perform batch minting
    function test_batchMint_Success() public {
        address[] memory toList = new address[](2);
        toList[0] = alice;
        toList[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(address(0), alice, 100);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(address(0), bob, 200);
        token.batchMint(toList, amounts);

        assertEq(token.balanceOf(alice), 1000 + 100);
        assertEq(token.balanceOf(bob), 500 + 200);
    }

    // ============ batchBurn() Tests ============

    /// @notice Should perform batch burning
    function test_batchBurn_Success() public {
        address[] memory userAddresses = new address[](2);
        userAddresses[0] = alice;
        userAddresses[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(alice, address(0), 100);
        vm.expectEmit(true, true, false, false, address(token));
        emit IERC20.Transfer(bob, address(0), 200);
        token.batchBurn(userAddresses, amounts);

        assertEq(token.balanceOf(alice), 1000 - 100);
        assertEq(token.balanceOf(bob), 500 - 200);
    }

    // ============ Zero Address Checks (via internal functions) ============

    /// @notice Should revert when trying to approve zero address (tests _approve internal)
    function test_approve_RevertWhen_ZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 100);
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import {
    BurnOnlyModule,
    CheckTransferOnlyModule,
    MintOnlyModule,
    MockAttributeSyncModule,
    MockRevertingSyncModule,
    RecordingModule,
    SpenderCheckOnlyModule,
    TransferHookOnlyModule,
    UndeclaredCheckModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @dev The point of the whole capability design: a module is reached at the dispatch points it
///      declared and at no other. Every test here asserts the negative as well as the positive.
contract ComplianceDispatchTest is TREXSuiteTest {

    ModularCompliance internal mc;

    RecordingModule internal mintOnly;
    RecordingModule internal burnOnly;
    RecordingModule internal transferOnly;

    function setUp() public override {
        super.setUp();

        mc = ModularCompliance(address(token.compliance()));

        // fund and unpause first, so the fixtures below start with clean counters
        vm.startPrank(agent);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();

        mintOnly = RecordingModule(_deploy(address(new MintOnlyModule())));
        burnOnly = RecordingModule(_deploy(address(new BurnOnlyModule())));
        transferOnly = RecordingModule(_deploy(address(new TransferHookOnlyModule())));

        vm.startPrank(deployer);
        mc.addModule(address(mintOnly));
        mc.addModule(address(burnOnly));
        mc.addModule(address(transferOnly));
        vm.stopPrank();
    }

    // ==== .created routing Tests ====

    /// @notice A mint reaches the mint hook and nothing else.
    function test_created_Success_WhenOnlyTheMintHookIsDeclared() public {
        vm.prank(agent);
        token.mint(bob, 100);

        assertEq(mintOnly.mintHookCalls(), 1);
        assertEq(burnOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    // ==== .destroyed routing Tests ====

    /// @notice A burn reaches the burn hook and nothing else.
    function test_destroyed_Success_WhenOnlyTheBurnHookIsDeclared() public {
        vm.prank(agent);
        token.burn(alice, 100);

        assertEq(burnOnly.burnHookCalls(), 1);
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    // ==== .transferred routing Tests ====

    /// @notice A transfer reaches the transfer hook and nothing else.
    function test_transferred_Success_WhenOnlyTheTransferHookIsDeclared() public {
        vm.prank(alice);
        token.transfer(bob, 100);

        assertEq(transferOnly.transferHookCalls(), 1);
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(burnOnly.totalHookCalls(), 0);
    }

    /// @notice Across a full mint, transfer and burn cycle each module is reached exactly once.
    function test_dispatch_Success_WhenDrivingEveryDispatchPoint() public {
        vm.prank(agent);
        token.mint(bob, 100);
        vm.prank(alice);
        token.transfer(bob, 100);
        vm.prank(agent);
        token.burn(alice, 100);

        assertEq(mintOnly.mintHookCalls(), 1);
        assertEq(mintOnly.transferHookCalls(), 0);
        assertEq(mintOnly.burnHookCalls(), 0);

        assertEq(burnOnly.burnHookCalls(), 1);
        assertEq(burnOnly.mintHookCalls(), 0);
        assertEq(burnOnly.transferHookCalls(), 0);

        assertEq(transferOnly.transferHookCalls(), 1);
        assertEq(transferOnly.mintHookCalls(), 0);
        assertEq(transferOnly.burnHookCalls(), 0);
    }

    /// @notice The declared hook is genuinely invoked, not merely counted.
    function test_created_Success_WhenExpectingTheCallOnTheDeclaringModule() public {
        vm.expectCall(address(mintOnly), abi.encodeCall(IModule.moduleMintAction, (bob, 100)));
        vm.prank(agent);
        token.mint(bob, 100);
    }

    // ==== .canTransfer routing Tests ====

    /// @notice A rejecting module that declared the check blocks the transfer.
    function test_canTransfer_Success_WhenDeclaringModuleRejects() public {
        CheckTransferOnlyModule checker = CheckTransferOnlyModule(_deploy(address(new CheckTransferOnlyModule())));
        vm.prank(deployer);
        mc.addModule(address(checker));

        assertTrue(mc.canTransfer(alice, bob, 100));

        checker.setAllow(false);
        assertFalse(mc.canTransfer(alice, bob, 100));
    }

    /// @notice A module that rejects but never declared the check is not consulted at all.
    function test_canTransfer_Success_WhenRejectingModuleDidNotDeclareTheCheck() public {
        UndeclaredCheckModule liar = UndeclaredCheckModule(_deploy(address(new UndeclaredCheckModule())));
        vm.prank(deployer);
        mc.addModule(address(liar));

        // its moduleCheck returns false, but CHECK_TRANSFER was never declared
        assertTrue(mc.canTransfer(alice, bob, 100));

        vm.prank(alice);
        token.transfer(bob, 100);

        // the hook it did declare still fires on a mint
        vm.prank(agent);
        token.mint(bob, 100);
        assertEq(liar.mintHookCalls(), 1);
    }

    // ==== .canSpenderCall routing Tests ====

    /// @notice With no spender-aware module bound, nothing objects.
    function test_canSpenderCall_Success_WhenNoModuleDeclaresTheSpenderCheck() public view {
        assertTrue(mc.canSpenderCall(charlie, alice, bob, 100));
    }

    /// @notice A bound spender module decides the answer.
    function test_canSpenderCall_Success_WhenDeclaringModuleRejects() public {
        SpenderCheckOnlyModule spenderCheck = SpenderCheckOnlyModule(_deploy(address(new SpenderCheckOnlyModule())));
        vm.prank(deployer);
        mc.addModule(address(spenderCheck));

        assertTrue(mc.canSpenderCall(charlie, alice, bob, 100));

        spenderCheck.setAllow(false);
        assertFalse(mc.canSpenderCall(charlie, alice, bob, 100));
    }

    /// @notice The spender check leaves the transfer path untouched.
    function test_canSpenderCall_Success_WhenTransferCheckIsUnaffected() public {
        SpenderCheckOnlyModule spenderCheck = SpenderCheckOnlyModule(_deploy(address(new SpenderCheckOnlyModule())));
        vm.prank(deployer);
        mc.addModule(address(spenderCheck));
        spenderCheck.setAllow(false);

        assertTrue(mc.canTransfer(alice, bob, 100));
        vm.prank(alice);
        token.transfer(bob, 100);
    }

    // ==== .attributeSynced routing Tests ====

    /// @notice A sync reaches only the module that declared the dispatch point.
    function test_attributeSynced_Success_WhenOnlyTheSyncPointIsDeclared() public {
        MockAttributeSyncModule sync = MockAttributeSyncModule(_deploy(address(new MockAttributeSyncModule())));
        vm.prank(deployer);
        mc.addModule(address(sync));

        vm.prank(address(token));
        mc.attributeSynced(alice, COUNTRY_CLAIM_TOPIC, 250, 724, 1000);

        assertEq(sync.attributeSyncCalls(), 1);
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(burnOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    /// @notice The module receives exactly the payload the compliance was handed.
    function test_attributeSynced_Success_ForwardsThePayloadVerbatim() public {
        MockAttributeSyncModule sync = MockAttributeSyncModule(_deploy(address(new MockAttributeSyncModule())));
        vm.prank(deployer);
        mc.addModule(address(sync));

        vm.prank(address(token));
        mc.attributeSynced(alice, COUNTRY_CLAIM_TOPIC, 250, 724, 1000);

        assertEq(sync.lastInvestor(), alice);
        assertEq(sync.lastTopic(), COUNTRY_CLAIM_TOPIC);
        assertEq(sync.lastOldValue(), 250);
        assertEq(sync.lastNewValue(), 724);
        assertEq(sync.lastPosition(), 1000);
    }

    /// @notice A module that declared no sync point is never reached, so modules written before the
    ///         dispatch point existed keep working untouched.
    function test_attributeSynced_Success_WhenNoModuleDeclaresTheSyncPoint() public {
        vm.prank(address(token));
        mc.attributeSynced(alice, COUNTRY_CLAIM_TOPIC, 250, 724, 1000);

        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(burnOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    /// @notice A module reverting inside the sync is reported and stepped over: the call returns, and
    ///         the modules bound after it still run. The whole non-reverting design rests on this.
    function test_attributeSynced_Success_WhenAModuleReverts() public {
        MockRevertingSyncModule reverting = MockRevertingSyncModule(_deploy(address(new MockRevertingSyncModule())));
        MockAttributeSyncModule sync = MockAttributeSyncModule(_deploy(address(new MockAttributeSyncModule())));

        vm.startPrank(deployer);
        mc.addModule(address(reverting));
        mc.addModule(address(sync));
        vm.stopPrank();

        vm.expectEmit(true, true, true, false, address(mc));
        emit EventsLib.AttributeSyncFailed(address(reverting), alice, COUNTRY_CLAIM_TOPIC);

        vm.prank(address(token));
        mc.attributeSynced(alice, COUNTRY_CLAIM_TOPIC, 250, 724, 1000);

        assertEq(sync.attributeSyncCalls(), 1);
    }

    /// @notice Only the bound token may drive a sync.
    function test_attributeSynced_RevertWhen_CallerIsNotTheBoundToken() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.AddressNotATokenBoundToComplianceContract.selector);
        mc.attributeSynced(alice, COUNTRY_CLAIM_TOPIC, 250, 724, 1000);
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import {
    BurnTrackerOnlyModule,
    MintTrackerOnlyModule,
    RecordingModule,
    RuleOnlyModule,
    SpenderOnlyModule,
    TransferTrackerOnlyModule,
    UndeclaredRuleModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @dev The point of the whole capability design: a module is reached at the dispatch points it
///      declared and at no other. Every test here asserts the negative as well as the positive.
contract ComplianceDispatchTest is InteropSuiteTest {

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

        mintOnly = RecordingModule(_deploy(address(new MintTrackerOnlyModule())));
        burnOnly = RecordingModule(_deploy(address(new BurnTrackerOnlyModule())));
        transferOnly = RecordingModule(_deploy(address(new TransferTrackerOnlyModule())));

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

        assertEq(mintOnly.mintActionCalls(), 1);
        assertEq(burnOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    // ==== .destroyed routing Tests ====

    /// @notice A burn reaches the burn hook and nothing else.
    function test_destroyed_Success_WhenOnlyTheBurnHookIsDeclared() public {
        vm.prank(agent);
        token.burn(alice, 100);

        assertEq(burnOnly.burnActionCalls(), 1);
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    // ==== .transferred routing Tests ====

    /// @notice A transfer reaches the transfer hook and nothing else.
    function test_transferred_Success_WhenOnlyTheTransferHookIsDeclared() public {
        vm.prank(alice);
        token.transfer(bob, 100);

        assertEq(transferOnly.transferActionCalls(), 1);
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

        assertEq(mintOnly.mintActionCalls(), 1);
        assertEq(mintOnly.transferActionCalls(), 0);
        assertEq(mintOnly.burnActionCalls(), 0);

        assertEq(burnOnly.burnActionCalls(), 1);
        assertEq(burnOnly.mintActionCalls(), 0);
        assertEq(burnOnly.transferActionCalls(), 0);

        assertEq(transferOnly.transferActionCalls(), 1);
        assertEq(transferOnly.mintActionCalls(), 0);
        assertEq(transferOnly.burnActionCalls(), 0);
    }

    /// @notice A forced transfer reaches the transfer hook, like a normal transfer does.
    function test_transferred_Success_WhenForcedTransfer() public {
        vm.prank(agent);
        token.forcedTransfer(alice, bob, 100);

        assertEq(transferOnly.transferActionCalls(), 1);
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(burnOnly.totalHookCalls(), 0);
    }

    /// @notice A recovery reaches the transfer hook too. It moves the balance outside `_update`, so without an
    ///         explicit notification modules would keep crediting the lost wallet, and the lost wallet is
    ///         removed from the identity registry, so nothing could fix it afterwards.
    function test_transferred_Success_WhenRecoveringAWallet() public {
        uint256 aliceBalance = token.balanceOf(alice);

        // Both wallets resolve to the same identity during the hook, which is what keeps a recovery from
        // corrupting the position: see TokenRecovery.t.sol for the regression this protects.
        IModule.TransferContext memory expected = IModule.TransferContext({
            compliance: address(mc),
            fromIdentity: address(aliceIdentity),
            toIdentity: address(aliceIdentity),
            fromWallet: bytes32(uint256(uint160(alice))),
            toWallet: bytes32(uint256(uint160(another))),
            amountMin: aliceBalance,
            amountMax: aliceBalance,
            isIssuance: false
        });
        vm.expectCall(address(transferOnly), abi.encodeCall(IModule.moduleTransferAction, (expected, aliceBalance)), 1);
        vm.prank(agent);
        token.recoveryAddress(alice, another, address(aliceIdentity));

        assertEq(transferOnly.transferActionCalls(), 1);
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(burnOnly.totalHookCalls(), 0);
    }

    /// @notice The declared hook is genuinely invoked, not merely counted.
    function test_created_Success_WhenExpectingTheCallOnTheDeclaringModule() public {
        // A mint has no sender, so the from side of the context is zero throughout.
        IModule.TransferContext memory expected = IModule.TransferContext({
            compliance: address(mc),
            fromIdentity: address(0),
            toIdentity: address(bobIdentity),
            fromWallet: bytes32(0),
            toWallet: bytes32(uint256(uint160(bob))),
            amountMin: 100,
            amountMax: 100,
            isIssuance: false
        });
        vm.expectCall(address(mintOnly), abi.encodeCall(IModule.moduleMintAction, (expected, 100)), 1);
        vm.prank(agent);
        token.mint(bob, 100);

        assertEq(mintOnly.lastAmount(), 100);
    }

    // ==== .canTransfer routing Tests ====

    /// @notice A rejecting module that declared the check blocks the transfer.
    function test_canTransfer_Success_WhenDeclaringModuleRejects() public {
        RuleOnlyModule checker = RuleOnlyModule(_deploy(address(new RuleOnlyModule())));
        vm.prank(deployer);
        mc.addModule(address(checker));

        assertTrue(mc.canTransfer(alice, bob, 100));

        checker.setAllow(false);
        assertFalse(mc.canTransfer(alice, bob, 100));
    }

    /// @notice A module that refuses but never named itself a rule is not consulted at all.
    function test_canTransfer_Success_WhenRejectingModuleDidNotDeclareTheCheck() public {
        UndeclaredRuleModule liar = UndeclaredRuleModule(_deploy(address(new UndeclaredRuleModule())));
        vm.prank(deployer);
        mc.addModule(address(liar));

        // its allowedAmount returns 0, but it never named itself a RULE
        assertTrue(mc.canTransfer(alice, bob, 100));

        vm.prank(alice);
        token.transfer(bob, 100);

        // the hook it did declare still fires on a mint
        vm.prank(agent);
        token.mint(bob, 100);
        assertEq(liar.mintActionCalls(), 1);
    }

    // ==== .canSpenderCall routing Tests ====

    /// @notice With no spender-aware module bound, nothing objects.
    function test_canSpenderCall_Success_WhenNoModuleDeclaresTheSpenderCheck() public view {
        assertTrue(mc.canSpenderCall(charlie, alice, bob, 100));
    }

    /// @notice A bound spender module decides the answer.
    function test_canSpenderCall_Success_WhenDeclaringModuleRejects() public {
        SpenderOnlyModule spenderCheck = SpenderOnlyModule(_deploy(address(new SpenderOnlyModule())));
        vm.prank(deployer);
        mc.addModule(address(spenderCheck));

        assertTrue(mc.canSpenderCall(charlie, alice, bob, 100));

        spenderCheck.setAllow(false);
        assertFalse(mc.canSpenderCall(charlie, alice, bob, 100));
    }

    /// @notice The spender check leaves the transfer path untouched.
    function test_canSpenderCall_Success_WhenTransferCheckIsUnaffected() public {
        SpenderOnlyModule spenderCheck = SpenderOnlyModule(_deploy(address(new SpenderOnlyModule())));
        vm.prank(deployer);
        mc.addModule(address(spenderCheck));
        spenderCheck.setAllow(false);

        assertTrue(mc.canTransfer(alice, bob, 100));
        vm.prank(alice);
        token.transfer(bob, 100);
    }

    // ==== .requestTransferValidation routing Tests ====

    /// @notice Issuance asks every rule for an amount, and touches no tracker: nothing has moved yet.
    function test_requestTransferValidation_Success_WhenEveryRuleIsAsked() public {
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        bytes memory from = _delegatedSatelliteWallet(100);
        bytes memory to = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        RuleOnlyModule firstRule = RuleOnlyModule(_deploy(address(new RuleOnlyModule())));
        RuleOnlyModule secondRule = RuleOnlyModule(_deploy(address(new RuleOnlyModule())));
        vm.startPrank(deployer);
        mc.addModule(address(firstRule));
        mc.addModule(address(secondRule));
        vm.stopPrank();

        IModule.TransferContext memory expected = IModule.TransferContext({
            compliance: address(mc),
            fromIdentity: address(aliceIdentity),
            toIdentity: address(bobIdentity),
            fromWallet: keccak256(from),
            toWallet: keccak256(to),
            amountMin: 10,
            amountMax: 100,
            isIssuance: true
        });
        vm.expectCall(address(firstRule), abi.encodeCall(IModule.allowedAmount, (expected)), 1);
        vm.expectCall(address(secondRule), abi.encodeCall(IModule.allowedAmount, (expected)), 1);
        _requestValidation(address(aliceIdentity), from, to, 10, 100);

        assertEq(mintOnly.totalHookCalls(), 0, "no tracker is told: nothing moved yet");
        assertEq(burnOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    /// @notice A rule that allows less narrows the issued range, and the trackers stay untouched.
    function test_requestTransferValidation_Success_WhenARuleNarrowsTheRange() public {
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        bytes memory from = _delegatedSatelliteWallet(100);
        bytes memory to = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        RuleOnlyModule narrowing = RuleOnlyModule(_deploy(address(new RuleOnlyModule())));
        narrowing.setAllowedAmount(40);
        vm.prank(deployer);
        mc.addModule(address(narrowing));

        uint256 id = _requestValidation(address(aliceIdentity), from, to, 10, 100);

        assertEq(mc.validationOf(id).amountMax, 40, "narrowed to what the rule allows");
        assertEq(mintOnly.totalHookCalls(), 0);
        assertEq(burnOnly.totalHookCalls(), 0);
        assertEq(transferOnly.totalHookCalls(), 0);
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

    /// @dev A satellite wallet for alice holding `amount`, delegated out of the balance minted in `setUp` so the
    ///  module counters stay clean.
    function _delegatedSatelliteWallet(uint256 amount) private returns (bytes memory envelope) {
        envelope = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOnPolygon"));
        vm.prank(agent);
        TokenLedgerHarness(address(token)).delegateOut(alice, envelope, amount);
    }

}

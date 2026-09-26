// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import {
    AllTypesModule,
    CappedRecipientModule,
    DuplicateTypeModule,
    NoTypeModule,
    RecordingModule,
    RuleAndTrackerModule,
    RuleOnlyModule,
    SpenderOnlyModule,
    TrackerOnlyModule
} from "test/integration/mocks/CapabilityModules.sol";
import { ModuleNotPnP } from "test/integration/mocks/ModuleNotPnP.sol";
import { TestModule } from "test/integration/mocks/TestModule.sol";

/// @notice What a module declares itself to be, and what it answers where it declared nothing.
///
/// @dev A module names its types in `moduleTypes`, and the compliance files it under each one. This suite
/// covers the declaration in isolation, module by module; `ComplianceTypeRouting.t.sol` covers what the
/// compliance then does with it.
contract ModuleTypesUnitTest is Test {

    address private _stranger = makeAddr("stranger");

    /* ----- Declarations ----- */

    function test_moduleTypes_Success_WhenEachFixtureNamesOnlyItsOwn() public {
        _assertTypes(_deploy(address(new RuleOnlyModule())), _rule());
        _assertTypes(_deploy(address(new SpenderOnlyModule())), _spender());
        _assertTypes(_deploy(address(new TrackerOnlyModule())), _tracker());
    }

    function test_moduleTypes_Success_WhenAFixtureNamesSeveral() public {
        IModule.ModuleType[] memory ruleAndTracker = new IModule.ModuleType[](2);
        ruleAndTracker[0] = IModule.ModuleType.RULE;
        ruleAndTracker[1] = IModule.ModuleType.TRACKER;

        _assertTypes(_deploy(address(new RuleAndTrackerModule())), ruleAndTracker);
        _assertTypes(_deploy(address(new CappedRecipientModule())), ruleAndTracker);

        IModule.ModuleType[] memory all = new IModule.ModuleType[](3);
        all[0] = IModule.ModuleType.RULE;
        all[1] = IModule.ModuleType.SPENDER;
        all[2] = IModule.ModuleType.TRACKER;
        _assertTypes(_deploy(address(new AllTypesModule())), all);
    }

    /// @notice The two declarations a compliance refuses to bind. Asserted here on the module alone, so the
    ///         fixtures are known to produce what the binding tests expect to be rejected.
    function test_moduleTypes_Success_WhenRejectionFixturesNameUnbindableSets() public {
        assertEq(IModule(_deploy(address(new NoTypeModule()))).moduleTypes().length, 0, "names nothing");

        IModule.ModuleType[] memory duplicated = IModule(_deploy(address(new DuplicateTypeModule()))).moduleTypes();
        assertEq(duplicated.length, 2);
        assertEq(uint8(duplicated[0]), uint8(duplicated[1]), "names the same type twice");
    }

    function test_moduleTypes_Success_WhenTheShippedMocksAreRules() public {
        address testModule =
            address(new ModuleProxy(address(new TestModule()), abi.encodeCall(TestModule.initialize, ())));
        address notPnP =
            address(new ModuleProxy(address(new ModuleNotPnP()), abi.encodeCall(ModuleNotPnP.initialize, ())));

        _assertTypes(testModule, _rule());
        _assertTypes(notPnP, _rule());
    }

    /* ----- Defaults ----- */

    /// @notice A module that does not override a question answers the neutral answer, so naming a type it
    ///         forgot to implement never blocks a movement by accident.
    function test_defaults_Success_WhenTheQuestionsAreNotOverridden() public {
        IModule module = IModule(_deploy(address(new TrackerOnlyModule())));

        assertEq(module.allowedAmount(_context(1)), type(uint256).max, "no limit by default");
        assertTrue(module.moduleCheckSpender(_context(1)), "allowed by default");
    }

    function test_defaults_Success_WhenTheActionIsNotOverridden() public {
        IModule module = IModule(_deploy(address(new RuleOnlyModule())));
        module.bindCompliance(address(this));

        module.afterTransfer(_context(1));
    }

    /// @notice The action is the compliance's to call. Its default carries the guard too, so a module that
    ///         implements nothing still cannot be driven by a stranger.
    function test_defaults_RevertWhen_TheActionIsCalledByAnyoneElse() public {
        IModule module = IModule(_deploy(address(new RuleOnlyModule())));

        vm.prank(_stranger);
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.afterTransfer(_context(1));
    }

    /// @notice A tracker guards its own override the same way, so the guard is the module's, not the base's.
    function test_overrides_RevertWhen_TheActionIsCalledByAnyoneElse() public {
        IModule module = IModule(_deploy(address(new TrackerOnlyModule())));

        vm.prank(_stranger);
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.afterTransfer(_context(1));
    }

    function test_recorders_Success_WhenModuleIsFreshlyDeployed() public {
        RecordingModule module = RecordingModule(_deploy(address(new TrackerOnlyModule())));

        assertEq(module.totalHookCalls(), 0);
        assertEq(module.transferActionCalls(), 0);
        assertEq(module.mintActionCalls(), 0);
        assertEq(module.burnActionCalls(), 0);
    }

    /* ----- ERC-165 ----- */

    function test_supportsInterface_Success_WhenQueriedForIModule() public {
        assertTrue(AllTypesModule(_deploy(address(new AllTypesModule()))).supportsInterface(type(IModule).interfaceId));
    }

    function _assertTypes(address module, IModule.ModuleType[] memory expected) private view {
        IModule.ModuleType[] memory declared = IModule(module).moduleTypes();
        assertEq(declared.length, expected.length, "wrong number of types");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(uint8(declared[i]), uint8(expected[i]), "wrong type");
        }
    }

    function _rule() private pure returns (IModule.ModuleType[] memory types) {
        types = new IModule.ModuleType[](1);
        types[0] = IModule.ModuleType.RULE;
    }

    function _spender() private pure returns (IModule.ModuleType[] memory types) {
        types = new IModule.ModuleType[](1);
        types[0] = IModule.ModuleType.SPENDER;
    }

    function _tracker() private pure returns (IModule.ModuleType[] memory types) {
        types = new IModule.ModuleType[](1);
        types[0] = IModule.ModuleType.TRACKER;
    }

    function _context(uint256 amount) private view returns (IModule.TransferContext memory ctx) {
        ctx.compliance = address(this);
        ctx.fromIdentity = _stranger;
        ctx.toIdentity = _stranger;
        ctx.amountMin = amount;
        ctx.amountMax = amount;
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}

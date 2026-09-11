// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { ModuleCapabilitiesLib as Caps } from "contracts/libraries/ModuleCapabilitiesLib.sol";

import { BoundsAndCheckModule, BoundsModule } from "test/integration/mocks/BoundsModule.sol";
import {
    AllCapabilitiesModule,
    BurnOnlyModule,
    CheckTransferOnlyModule,
    MintOnlyModule,
    RecordingModule,
    SpenderCheckOnlyModule,
    TransferHookOnlyModule,
    UndefinedBitModule,
    ZeroCapabilityModule
} from "test/integration/mocks/CapabilityModules.sol";
import { ModuleNotPnP } from "test/integration/mocks/ModuleNotPnP.sol";
import { TestModule } from "test/integration/mocks/TestModule.sol";

contract ModuleCapabilitiesUnitTest is Test {

    address private _stranger = makeAddr("stranger");

    // ==== .moduleCapabilities flag layout Tests ====

    /// @notice Every flag is a distinct single bit.
    function test_capabilityFlags_Success_WhenEachIsADistinctSingleBit() public pure {
        uint256[6] memory flags =
            [Caps.CHECK_TRANSFER, Caps.CHECK_SPENDER, Caps.HOOK_TRANSFER, Caps.HOOK_MINT, Caps.HOOK_BURN, Caps.BOUNDS];

        uint256 seen;
        for (uint256 i = 0; i < flags.length; i++) {
            // a single bit set
            assertEq(flags[i] & (flags[i] - 1), 0);
            // not already used by an earlier flag
            assertEq(seen & flags[i], 0);
            seen |= flags[i];
        }
    }

    /// @notice ALL is exactly the union of the six flags.
    function test_capabilityFlags_Success_WhenAllIsTheUnionOfEveryFlag() public pure {
        assertEq(
            Caps.ALL,
            Caps.CHECK_TRANSFER | Caps.CHECK_SPENDER | Caps.HOOK_TRANSFER | Caps.HOOK_MINT | Caps.HOOK_BURN
                | Caps.BOUNDS
        );
        assertEq(Caps.ALL, 0x3f);
    }

    /// @notice BOUNDS is the sixth bit, above the five #23 flags and inside ALL.
    function test_capabilityFlags_Success_WhenBoundsIsTheSixthBit() public pure {
        assertEq(Caps.BOUNDS, 1 << 5);
        assertEq(Caps.BOUNDS & 0x1f, 0);
        assertEq(Caps.ALL & Caps.BOUNDS, Caps.BOUNDS);
    }

    // ==== .moduleCapabilities declaration Tests ====

    /// @notice Each fixture declares exactly its own capability and nothing else.
    function test_moduleCapabilities_Success_WhenEachFixtureDeclaresOnlyItsOwn() public {
        assertEq(IModule(_deploy(address(new MintOnlyModule()))).moduleCapabilities(), Caps.HOOK_MINT);
        assertEq(IModule(_deploy(address(new BurnOnlyModule()))).moduleCapabilities(), Caps.HOOK_BURN);
        assertEq(IModule(_deploy(address(new TransferHookOnlyModule()))).moduleCapabilities(), Caps.HOOK_TRANSFER);
        assertEq(IModule(_deploy(address(new CheckTransferOnlyModule()))).moduleCapabilities(), Caps.CHECK_TRANSFER);
        assertEq(IModule(_deploy(address(new SpenderCheckOnlyModule()))).moduleCapabilities(), Caps.CHECK_SPENDER);
        assertEq(IModule(_deploy(address(new AllCapabilitiesModule()))).moduleCapabilities(), Caps.ALL);
        assertEq(IModule(_deployBounds(address(new BoundsModule()))).moduleCapabilities(), Caps.BOUNDS);
        assertEq(
            IModule(_deployBounds(address(new BoundsAndCheckModule()))).moduleCapabilities(),
            Caps.BOUNDS | Caps.CHECK_TRANSFER
        );
    }

    /// @notice The rejection fixtures declare values a compliance must refuse.
    function test_moduleCapabilities_Success_WhenRejectionFixturesDeclareUnbindableValues() public {
        assertEq(IModule(_deploy(address(new ZeroCapabilityModule()))).moduleCapabilities(), 0);

        uint256 undefinedBits = IModule(_deploy(address(new UndefinedBitModule()))).moduleCapabilities();
        assertTrue(undefinedBits & ~Caps.ALL != 0);
    }

    /// @notice The pre-existing mocks declare the transfer check they implement.
    function test_moduleCapabilities_Success_WhenExistingMocksDeclareCheckTransfer() public {
        address testModule =
            address(new ModuleProxy(address(new TestModule()), abi.encodeCall(TestModule.initialize, ())));
        address notPnP =
            address(new ModuleProxy(address(new ModuleNotPnP()), abi.encodeCall(ModuleNotPnP.initialize, ())));

        assertEq(IModule(testModule).moduleCapabilities(), Caps.CHECK_TRANSFER);
        assertEq(IModule(notPnP).moduleCapabilities(), Caps.CHECK_TRANSFER);
    }

    // ==== AbstractModuleUpgradeable default body Tests ====

    /// @notice A module that overrides no check inherits a passing verdict on both.
    function test_defaults_Success_WhenChecksAreNotOverridden() public {
        IModule module = IModule(_deploy(address(new AllCapabilitiesModule())));

        assertTrue(module.moduleCheck(_stranger, _stranger, 1, address(this)));
        assertTrue(module.moduleCheckSpender(_stranger, _stranger, _stranger, 1, address(this)));
    }

    /// @notice A module that does not override the bounds hook returns the running range untouched.
    function test_defaults_Success_WhenValidationBoundsIsNotOverridden() public {
        IModule module = IModule(_deploy(address(new CheckTransferOnlyModule())));

        (uint256 min, uint256 max) =
            module.validationBounds(hex"0001000001890114", hex"00010000010a0114", 9, 11, address(this));

        assertEq(min, 9);
        assertEq(max, 11);
    }

    /// @notice The default hooks still refuse a caller that is not a bound compliance.
    function test_defaults_RevertWhen_HookCalledByNonBoundCompliance() public {
        IModule module = IModule(_deploy(address(new AllCapabilitiesModule())));

        vm.startPrank(_stranger);
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.moduleTransferAction(_stranger, _stranger, 1);

        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.moduleMintAction(_stranger, 1);

        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        module.moduleBurnAction(_stranger, 1);
        vm.stopPrank();
    }

    /// @notice A fresh fixture has recorded no dispatch yet.
    function test_recorders_Success_WhenModuleIsFreshlyDeployed() public {
        RecordingModule module = RecordingModule(_deploy(address(new MintOnlyModule())));

        assertEq(module.totalHookCalls(), 0);
        assertEq(module.transferHookCalls(), 0);
        assertEq(module.mintHookCalls(), 0);
        assertEq(module.burnHookCalls(), 0);
    }

    // ==== .supportsInterface Tests ====

    /// @notice The revised IModule id is still advertised by the base.
    function test_supportsInterface_Success_WhenQueriedForIModule() public {
        assertTrue(
            AllCapabilitiesModule(_deploy(address(new AllCapabilitiesModule())))
                .supportsInterface(type(IModule).interfaceId)
        );
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

    function _deployBounds(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(BoundsModule.initialize, ())));
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { console } from "@forge-std/console.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import {
    CheckAndMintHookModule,
    CheckAndTransferHookModule,
    CheckTransferOnlyModule,
    RecordingModule,
    UngatedCheckAndMintHookModule,
    UngatedCheckAndTransferHookModule,
    UngatedCheckTransferOnlyModule
} from "test/integration/mocks/CapabilityModules.sol";

/// @dev Before/after evidence for capability-gated dispatch, two eight-module sets on the same token:
/// a realistic set where all eight vet transfers, two keep transfer state and one keeps mint state, and
/// a baseline of the very same modules declaring every dispatch point — the pre-capability behaviour,
/// where the compliance called every module everywhere.
///
/// The two sets differ only in what they declare, never in what they do, so the delta is the routing
/// and nothing else. Each operation also runs once un-measured first, so both are timed against the
/// same warm state.
contract ComplianceCapabilityGasTest is TREXSuiteTest {

    uint256 private constant MODULE_COUNT = 8;
    uint256 private constant MODULE_CAP = 25;
    uint256 private constant DISPATCH_FIXED_READS = 2;
    uint256 private constant DISPATCH_READS_PER_MODULE = 3;

    ModularCompliance internal mc;

    function setUp() public override {
        super.setUp();

        mc = ModularCompliance(address(token.compliance()));

        vm.startPrank(agent);
        token.mint(alice, 1_000_000);
        token.unpause();
        vm.stopPrank();
    }

    /// @notice Gated dispatch costs less on every hook path and never more on the check path.
    function test_gas_Success_WhenComparingBaselineToDeclaredRouting() public {
        uint256[4] memory baseline = _measure(_deployBaselineSet());
        _unbindAll();
        uint256[4] memory realistic = _measure(_deployRealisticSet());

        console.log("--- 8 bound modules, gas per operation ---");
        _report("mint       ", baseline[0], realistic[0]);
        _report("burn       ", baseline[1], realistic[1]);
        _report("transfer   ", baseline[2], realistic[2]);
        _report("transferFrom", baseline[3], realistic[3]);

        // one mint-relevant module instead of eight
        assertLt(realistic[0], baseline[0], "mint did not get cheaper");
        // no burn-relevant module at all
        assertLt(realistic[1], baseline[1], "burn did not get cheaper");
        // two transfer hooks instead of eight, checks unchanged
        assertLe(realistic[2], baseline[2], "transfer regressed");
        assertLe(realistic[3], baseline[3], "transferFrom regressed");
    }

    /// @notice Binding pays for the routing the transaction path stops paying for.
    function test_gas_Success_WhenReportingTheBindCost() public {
        address module = _deploy(address(new CheckTransferOnlyModule()));

        vm.prank(deployer);
        uint256 before = gasleft();
        mc.addModule(module);
        uint256 spent = before - gasleft();

        console.log("--- cold path ---");
        console.log("addModule (records capabilities):", spent);
        assertTrue(mc.isModuleBound(module));
    }

    /// @notice A module is found in the same gas whether it bound first or last, at the 25-module cap.
    function test_gas_Success_WhenLookupDoesNotGrowWithTheModuleCount() public {
        address[] memory modules = new address[](MODULE_CAP);
        for (uint256 i = 0; i < MODULE_CAP; i++) {
            modules[i] = _deploy(address(new CheckTransferOnlyModule()));
        }
        _bindAll(modules);

        uint256 firstBound = _complianceReads(modules[0]);
        uint256 lastBound = _complianceReads(modules[MODULE_CAP - 1]);

        console.log("--- lookup at the 25-module cap ---");
        console.log("isModuleBound storage reads, first bound:", firstBound);
        console.log("isModuleBound storage reads,  last bound:", lastBound);

        // storage reads rather than gas: `forge test --gas-report` inflates a gasleft() bracket,
        // while the number of slots a lookup touches is what "constant time" actually means here
        assertEq(lastBound, firstBound, "lookup is not constant time: reads track the module's position");
        assertLe(firstBound, 2, "a lookup should resolve without walking the bound set");
    }

    /// @notice Dispatch touches a fixed number of slots per bound module and nothing beyond them.
    function test_gas_Success_WhenDispatchReadsThreeSlotsPerModule() public {
        _bindAll(_deployRealisticSet());
        uint256 eight = _dispatchReads();

        _unbindAll();
        _bindAll(_deployHalfSet());
        uint256 four = _dispatchReads();

        console.log("--- canTransfer storage reads on the compliance ---");
        console.log("with eight bound:", eight);
        console.log("with  four bound:", four);

        // per module the map costs the array bounds check on the key length, the key itself, and the
        // value it maps to. The two fixed reads are the length behind `length()` and its first re-read
        assertEq(eight, DISPATCH_FIXED_READS + DISPATCH_READS_PER_MODULE * MODULE_COUNT, "dispatch reads changed");
        assertEq(four, DISPATCH_FIXED_READS + DISPATCH_READS_PER_MODULE * (MODULE_COUNT / 2), "dispatch reads changed");
        assertEq(
            eight - four,
            DISPATCH_READS_PER_MODULE * (MODULE_COUNT / 2),
            "dispatch cost per module is no longer constant"
        );
    }

    function _deployHalfSet() private returns (address[] memory modules) {
        modules = new address[](MODULE_COUNT / 2);
        for (uint256 i = 0; i < modules.length; i++) {
            modules[i] = _deploy(address(new CheckTransferOnlyModule()));
        }
    }

    /// @return the number of compliance storage slots read while answering a `canTransfer` dispatch
    function _dispatchReads() private returns (uint256) {
        vm.record();
        mc.canTransfer(alice, bob, 100);
        (bytes32[] memory reads,) = vm.accesses(address(mc));
        return reads.length;
    }

    /// @return the number of compliance storage slots read while answering `isModuleBound` for `module`
    function _complianceReads(address module) private returns (uint256) {
        vm.record();
        mc.isModuleBound(module);
        (bytes32[] memory reads,) = vm.accesses(address(mc));
        return reads.length;
    }

    /// @return gasUsed gas spent on mint, burn, transfer and transferFrom, in that order
    function _measure(address[] memory modules) private returns (uint256[4] memory gasUsed) {
        _bindAll(modules);

        vm.prank(alice);
        token.approve(charlie, type(uint256).max);

        // warm-up pass, discarded
        _mint();
        _burn();
        _transfer();
        _transferFrom();

        uint256 before = gasleft();
        _mint();
        gasUsed[0] = before - gasleft();

        before = gasleft();
        _burn();
        gasUsed[1] = before - gasleft();

        before = gasleft();
        _transfer();
        gasUsed[2] = before - gasleft();

        before = gasleft();
        _transferFrom();
        gasUsed[3] = before - gasleft();
    }

    function _mint() private {
        vm.prank(agent);
        token.mint(bob, 100);
    }

    function _burn() private {
        vm.prank(agent);
        token.burn(alice, 100);
    }

    function _transfer() private {
        vm.prank(alice);
        token.transfer(bob, 100);
    }

    function _transferFrom() private {
        vm.prank(charlie);
        token.transferFrom(alice, bob, 100);
    }

    /// @dev The realistic set with every module declaring every dispatch point: same work per module,
    ///      but every transaction calls all of them everywhere.
    function _deployBaselineSet() private returns (address[] memory modules) {
        modules = new address[](MODULE_COUNT);
        modules[0] = _deploy(address(new UngatedCheckAndMintHookModule()));
        modules[1] = _deploy(address(new UngatedCheckAndTransferHookModule()));
        modules[2] = _deploy(address(new UngatedCheckAndTransferHookModule()));
        for (uint256 i = 3; i < MODULE_COUNT; i++) {
            modules[i] = _deploy(address(new UngatedCheckTransferOnlyModule()));
        }
    }

    /// @dev All eight vet transfers; two also keep transfer state, one also keeps mint state.
    function _deployRealisticSet() private returns (address[] memory modules) {
        modules = new address[](MODULE_COUNT);
        modules[0] = _deploy(address(new CheckAndMintHookModule()));
        modules[1] = _deploy(address(new CheckAndTransferHookModule()));
        modules[2] = _deploy(address(new CheckAndTransferHookModule()));
        for (uint256 i = 3; i < MODULE_COUNT; i++) {
            modules[i] = _deploy(address(new CheckTransferOnlyModule()));
        }
    }

    function _bindAll(address[] memory modules) private {
        vm.startPrank(deployer);
        for (uint256 i = 0; i < modules.length; i++) {
            mc.addModule(modules[i]);
        }
        vm.stopPrank();
    }

    function _unbindAll() private {
        address[] memory bound = mc.getModules();
        vm.startPrank(deployer);
        for (uint256 i = 0; i < bound.length; i++) {
            mc.removeModule(bound[i]);
        }
        vm.stopPrank();
    }

    /// @dev Reports the delta without asserting on it, so a regression reaches the assertion that names
    ///      it rather than panicking on an unsigned subtraction here.
    function _report(string memory label, uint256 baseline, uint256 realistic) private pure {
        console.log(string.concat(label, " baseline:"), baseline, "  declared-routing:", realistic);
        if (realistic <= baseline) {
            console.log("             saved:", baseline - realistic);
        } else {
            console.log("             REGRESSED by:", realistic - baseline);
        }
    }

    function _deploy(address implementation) private returns (address) {
        return address(new ModuleProxy(implementation, abi.encodeCall(RecordingModule.initialize, ())));
    }

}

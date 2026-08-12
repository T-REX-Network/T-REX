// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test, Vm } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/authority/TREXImplementationAuthority.sol";

/// @notice Unit tests for the new TREXRegistry surface on `TREXImplementationAuthority`.
/// @dev    Covers the `trexRegistryImplementation` field that was appended to the
///         `TREXContracts` struct, the `getTREXRegistryImplementation()` view, and the
///         `TREXRegistryImplementationSet(address)` event. The setter follows the same
///         "versioned struct" pattern as the legacy implementation slots — there is no
///         per-slot setter on the authority; the implementation is registered through
///         `addTREXVersion` / `addAndUseTREXVersion`.
contract TREXImplementationAuthorityTREXRegistryUnitTest is Test {

    address public deployer = makeAddr("deployer");
    address public accessManagerAdmin = makeAddr("accessManagerAdmin");
    address public another = makeAddr("another");

    AccessManager public accessManager;
    TREXImplementationAuthority public ia;

    address public tokenImpl = makeAddr("tokenImpl");
    address public ctrImpl = makeAddr("ctrImpl");
    address public irImpl = makeAddr("irImpl");
    address public irsImpl = makeAddr("irsImpl");
    address public tirImpl = makeAddr("tirImpl");
    address public mcImpl = makeAddr("mcImpl");
    address public trexRegistryImpl = makeAddr("trexRegistryImpl");

    function setUp() public {
        accessManager = new AccessManager(accessManagerAdmin);

        vm.prank(accessManagerAdmin);
        accessManager.grantRole(RolesLib.OWNER, deployer, 0);

        ia = new TREXImplementationAuthority(true, address(0), address(0), address(accessManager));
        vm.prank(accessManagerAdmin);
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, address(ia));
    }

    function _baseContracts() internal view returns (ITREXImplementationAuthority.TREXContracts memory) {
        return ITREXImplementationAuthority.TREXContracts({
            tokenImplementation: tokenImpl,
            ctrImplementation: ctrImpl,
            irImplementation: irImpl,
            irsImplementation: irsImpl,
            tirImplementation: tirImpl,
            mcImplementation: mcImpl,
            trexRegistryImplementation: trexRegistryImpl
        });
    }

    // ============ Default state ============

    /// @notice Should return zero before any TREX version is registered.
    function test_getTREXRegistryImplementation_DefaultZero() public view {
        assertEq(ia.getTREXRegistryImplementation(), address(0), "must default to zero");
    }

    // ============ Access control on setter (struct-based) ============

    /// @notice `addAndUseTREXVersion` must reject non-owner callers.
    function test_addAndUseTREXVersion_RevertWhen_NotOwner() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        ia.addAndUseTREXVersion(version, _baseContracts());
    }

    // ============ Getter returns the most recent value ============

    /// @notice Should expose the registry implementation address after a version is set.
    function test_getTREXRegistryImplementation_ReturnsLatestValue() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.prank(deployer);
        ia.addAndUseTREXVersion(version, _baseContracts());

        assertEq(
            ia.getTREXRegistryImplementation(),
            trexRegistryImpl,
            "getter must return the registered TREXRegistry implementation"
        );
    }

    /// @notice Should update the returned value when a new version is registered.
    function test_getTREXRegistryImplementation_UpdatesAcrossVersions() public {
        ITREXImplementationAuthority.Version memory v1 =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.prank(deployer);
        ia.addAndUseTREXVersion(v1, _baseContracts());
        assertEq(ia.getTREXRegistryImplementation(), trexRegistryImpl);

        // Register v5.0.1 with a different TREXRegistry implementation and switch to it.
        ITREXImplementationAuthority.Version memory v2 =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 1 });
        address newRegistryImpl = makeAddr("trexRegistryImplV2");
        ITREXImplementationAuthority.TREXContracts memory contracts = _baseContracts();
        contracts.trexRegistryImplementation = newRegistryImpl;

        vm.prank(deployer);
        ia.addAndUseTREXVersion(v2, contracts);

        assertEq(
            ia.getTREXRegistryImplementation(), newRegistryImpl, "getter must reflect the most recently used version"
        );
    }

    // ============ Event emission ============

    /// @notice `addTREXVersion` should emit `TREXRegistryImplementationSet` when the field is non-zero.
    function test_addAndUseTREXVersion_Emits_TREXRegistryImplementationSet() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

        vm.recordLogs();
        vm.prank(deployer);
        ia.addAndUseTREXVersion(version, _baseContracts());

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("TREXRegistryImplementationSet(address)");
        bool sawEvent;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(ia)) continue;
            if (entries[i].topics[0] == sig) {
                sawEvent = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), trexRegistryImpl);
                break;
            }
        }
        assertTrue(sawEvent, "TREXRegistryImplementationSet event must be emitted");
    }

    /// @notice Should NOT emit the event when registering a legacy version with zero TREXRegistry impl.
    function test_addAndUseTREXVersion_DoesNotEmit_WhenTREXRegistryIsZero() public {
        ITREXImplementationAuthority.Version memory version =
            ITREXImplementationAuthority.Version({ major: 4, minor: 0, patch: 0 });
        ITREXImplementationAuthority.TREXContracts memory contracts = _baseContracts();
        contracts.trexRegistryImplementation = address(0);

        vm.recordLogs();
        vm.prank(deployer);
        ia.addAndUseTREXVersion(version, contracts);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("TREXRegistryImplementationSet(address)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(ia) && entries[i].topics[0] == sig) {
                fail();
            }
        }
        assertEq(ia.getTREXRegistryImplementation(), address(0), "must remain zero");
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/beacon/TREXImplementationAuthority.sol";

/// @notice Unit tests for the merged-registry slot of `TREXImplementationAuthority`.
/// @dev    Covers the `trexRegistryImplementation` field of `SuiteImplementations`, the registry beacon
///         it drives, and the `VersionPublished` / `SuiteUpgraded` events that carry it. There is no
///         per-slot setter: the implementation is registered through `publish` / `publishAndUpgrade`,
///         both gated by VERSION_MANAGER.
contract TREXImplementationAuthorityTREXRegistryUnitTest is Test {

    address public deployer = makeAddr("deployer");
    address public accessManagerAdmin = makeAddr("accessManagerAdmin");
    address public another = makeAddr("another");

    AccessManager public accessManager;
    TREXImplementationAuthority public ia;

    DummyImpl public tokenImpl;
    DummyImpl public irsImpl;
    DummyImpl public mcImpl;
    DummyImpl public trexRegistryImpl;

    ITREXImplementationAuthority.Version private v0 =
        ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });
    ITREXImplementationAuthority.Version private v1 =
        ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 1 });

    function setUp() public {
        tokenImpl = new DummyImpl();
        irsImpl = new DummyImpl();
        mcImpl = new DummyImpl();
        trexRegistryImpl = new DummyImpl();

        accessManager = new AccessManager(accessManagerAdmin);

        ia = new TREXImplementationAuthority(address(accessManager), v0, _baseImpls());

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, address(ia));
        accessManager.grantRole(RolesLib.VERSION_MANAGER, deployer, 0);
        vm.stopPrank();
    }

    function _baseImpls() internal view returns (ITREXImplementationAuthority.SuiteImplementations memory) {
        return ITREXImplementationAuthority.SuiteImplementations({
            tokenImplementation: address(tokenImpl),
            trexRegistryImplementation: address(trexRegistryImpl),
            irsImplementation: address(irsImpl),
            mcImplementation: address(mcImpl)
        });
    }

    // ============ Seeded state ============

    /// @notice The constructor archives the merged-registry implementation for the seeded version.
    function test_constructor_ArchivesTREXRegistryImplementation() public view {
        assertEq(
            ia.implementationsFor(v0).trexRegistryImplementation,
            address(trexRegistryImpl),
            "seeded version must carry the TREXRegistry implementation"
        );
    }

    /// @notice The registry beacon is deployed, owned by the authority, and resolves to the implementation.
    function test_constructor_RegistryBeaconPointsToImplementation() public view {
        address beacon = ia.beacons().trexRegistryBeacon;

        assertTrue(beacon != address(0), "registry beacon must exist");
        assertEq(UpgradeableBeacon(beacon).owner(), address(ia), "authority must own the registry beacon");
        assertEq(UpgradeableBeacon(beacon).implementation(), address(trexRegistryImpl));
    }

    // ============ Access control ============

    /// @notice `publishAndUpgrade` must reject callers without VERSION_MANAGER.
    function test_publishAndUpgrade_RevertWhen_NotVersionManager() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        ia.publishAndUpgrade(v1, _baseImpls());
    }

    // ============ Registry implementation across versions ============

    /// @notice Upgrading to a version with a new registry implementation rotates the registry beacon.
    function test_publishAndUpgrade_RotatesRegistryBeaconAcrossVersions() public {
        address beacon = ia.beacons().trexRegistryBeacon;
        assertEq(UpgradeableBeacon(beacon).implementation(), address(trexRegistryImpl));

        DummyImpl newRegistryImpl = new DummyImpl();
        ITREXImplementationAuthority.SuiteImplementations memory impls = _baseImpls();
        impls.trexRegistryImplementation = address(newRegistryImpl);

        vm.prank(deployer);
        ia.publishAndUpgrade(v1, impls);

        assertEq(ia.beacons().trexRegistryBeacon, beacon, "the beacon address must not change");
        assertEq(
            UpgradeableBeacon(beacon).implementation(),
            address(newRegistryImpl),
            "beacon must resolve to the most recently activated registry implementation"
        );
        assertEq(ia.implementationsFor(v1).trexRegistryImplementation, address(newRegistryImpl));
    }

    /// @notice The earlier version's archive keeps its own registry implementation.
    function test_publishAndUpgrade_KeepsPreviousRegistryArchive() public {
        DummyImpl newRegistryImpl = new DummyImpl();
        ITREXImplementationAuthority.SuiteImplementations memory impls = _baseImpls();
        impls.trexRegistryImplementation = address(newRegistryImpl);

        vm.prank(deployer);
        ia.publishAndUpgrade(v1, impls);

        assertEq(ia.implementationsFor(v0).trexRegistryImplementation, address(trexRegistryImpl));
    }

    // ============ Event emission ============

    /// @notice `publish` emits `VersionPublished` carrying the registry implementation.
    function test_publish_EmitsVersionPublishedWithRegistryImplementation() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _baseImpls();

        vm.expectEmit(true, true, true, true);
        emit EventsLib.VersionPublished(v1, impls);

        vm.prank(deployer);
        ia.publish(v1, impls);
    }

    /// @notice `publishAndUpgrade` emits `SuiteUpgraded` carrying the registry implementation.
    function test_publishAndUpgrade_EmitsSuiteUpgradedWithRegistryImplementation() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _baseImpls();

        vm.expectEmit(true, true, true, true);
        emit EventsLib.SuiteUpgraded(v1, impls);

        vm.prank(deployer);
        ia.publishAndUpgrade(v1, impls);
    }

    // ============ Zero registry implementation ============

    /// @notice A version with a zero TREXRegistry implementation must be rejected outright: the factory
    ///         rejects such an authority, so publishing one would only produce an unusable version.
    function test_publish_RevertWhen_TREXRegistryIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _baseImpls();
        impls.trexRegistryImplementation = address(0);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        ia.publish(v1, impls);
    }

    /// @notice The constructor rejects a zero TREXRegistry implementation for the same reason.
    function test_constructor_RevertWhen_TREXRegistryIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _baseImpls();
        impls.trexRegistryImplementation = address(0);

        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        new TREXImplementationAuthority(address(accessManager), v0, impls);
    }

}

/// @dev A beacon's implementation must be a contract, so the slots are filled with distinct
///      non-empty contracts rather than plain addresses.
contract DummyImpl {

    function marker() external pure returns (string memory) {
        return "dummy";
    }

}

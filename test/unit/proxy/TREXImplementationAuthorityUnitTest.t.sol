// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { TREXImplementationAuthority } from "contracts/proxy/beacon/TREXImplementationAuthority.sol";

contract TREXImplementationAuthorityUnitTest is Test {

    TREXImplementationAuthority private authority;
    AccessManager private accessManager;

    address private versionManager = makeAddr("VersionManager");
    address private notVersionManager = makeAddr("NotVersionManager");

    // v0 implementations
    DummyTokenV0 private tokenImplV0;
    DummyTrexRegistryV0 private trexRegistryImplV0;
    DummyIrsV0 private irsImplV0;
    DummyMcV0 private mcImplV0;

    // v1 implementations
    DummyTokenV1 private tokenImplV1;
    DummyTrexRegistryV1 private trexRegistryImplV1;
    DummyIrsV1 private irsImplV1;
    DummyMcV1 private mcImplV1;

    ITREXImplementationAuthority.Version private v0 =
        ITREXImplementationAuthority.Version({ major: 4, minor: 1, patch: 0 });
    ITREXImplementationAuthority.Version private v1 =
        ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 });

    function setUp() public {
        tokenImplV0 = new DummyTokenV0();
        trexRegistryImplV0 = new DummyTrexRegistryV0();
        irsImplV0 = new DummyIrsV0();
        mcImplV0 = new DummyMcV0();

        tokenImplV1 = new DummyTokenV1();
        trexRegistryImplV1 = new DummyTrexRegistryV1();
        irsImplV1 = new DummyIrsV1();
        mcImplV1 = new DummyMcV1();

        accessManager = new AccessManager(address(this));
        authority = new TREXImplementationAuthority(address(accessManager), v0, _v0Impls());

        // publish / upgrade / publishAndUpgrade are gated by VERSION_MANAGER
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, address(authority));
        accessManager.grantRole(RolesLib.VERSION_MANAGER, versionManager, 0);
    }

    // ---------- constructor ----------

    function test_constructor_SetsAccessManagerAsOwner() public view {
        assertEq(authority.owner(), address(accessManager));
        assertEq(authority.authority(), address(accessManager));
    }

    function test_constructor_Deploys4BeaconsOwnedByRegistry() public view {
        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();

        assertTrue(bs.tokenBeacon != address(0));
        assertTrue(bs.trexRegistryBeacon != address(0));
        assertTrue(bs.irsBeacon != address(0));
        assertTrue(bs.mcBeacon != address(0));

        assertEq(UpgradeableBeacon(bs.tokenBeacon).owner(), address(authority));
        assertEq(UpgradeableBeacon(bs.trexRegistryBeacon).owner(), address(authority));
        assertEq(UpgradeableBeacon(bs.irsBeacon).owner(), address(authority));
        assertEq(UpgradeableBeacon(bs.mcBeacon).owner(), address(authority));
    }

    function test_constructor_BeaconsPointToProvidedImplementations() public view {
        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();

        assertEq(UpgradeableBeacon(bs.tokenBeacon).implementation(), address(tokenImplV0));
        assertEq(UpgradeableBeacon(bs.trexRegistryBeacon).implementation(), address(trexRegistryImplV0));
        assertEq(UpgradeableBeacon(bs.irsBeacon).implementation(), address(irsImplV0));
        assertEq(UpgradeableBeacon(bs.mcBeacon).implementation(), address(mcImplV0));
    }

    function test_constructor_SeedsLatestVersionWithV0() public view {
        ITREXImplementationAuthority.Version memory latest = authority.latestVersion();

        assertEq(latest.major, v0.major);
        assertEq(latest.minor, v0.minor);
        assertEq(latest.patch, v0.patch);
    }

    function test_constructor_SeedsCurrentVersionWithV0() public view {
        ITREXImplementationAuthority.Version memory active = authority.currentVersion();

        assertEq(active.major, v0.major);
        assertEq(active.minor, v0.minor);
        assertEq(active.patch, v0.patch);
    }

    function test_constructor_ArchivesV0Implementations() public view {
        ITREXImplementationAuthority.SuiteImplementations memory archived = authority.implementationsFor(v0);

        assertEq(archived.tokenImplementation, address(tokenImplV0));
        assertEq(archived.trexRegistryImplementation, address(trexRegistryImplV0));
        assertEq(archived.irsImplementation, address(irsImplV0));
        assertEq(archived.mcImplementation, address(mcImplV0));
    }

    function test_constructor_BeaconsAndCurrentReturnSameAddresses() public view {
        ITREXImplementationAuthority.SuiteBeacons memory fromCurrent = authority.current();
        ITREXImplementationAuthority.SuiteBeacons memory fromBeacons = authority.beacons();

        assertEq(fromCurrent.tokenBeacon, fromBeacons.tokenBeacon);
        assertEq(fromCurrent.trexRegistryBeacon, fromBeacons.trexRegistryBeacon);
        assertEq(fromCurrent.irsBeacon, fromBeacons.irsBeacon);
        assertEq(fromCurrent.mcBeacon, fromBeacons.mcBeacon);
    }

    function test_constructor_RevertWhen_AccessManagerIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new TREXImplementationAuthority(address(0), v0, _v0Impls());
    }

    function test_constructor_RevertWhen_TokenImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v0Impls();
        impls.tokenImplementation = address(0);

        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        new TREXImplementationAuthority(address(accessManager), v0, impls);
    }

    function test_constructor_RevertWhen_TrexRegistryImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v0Impls();
        impls.trexRegistryImplementation = address(0);

        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        new TREXImplementationAuthority(address(accessManager), v0, impls);
    }

    function test_constructor_RevertWhen_IrsImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v0Impls();
        impls.irsImplementation = address(0);

        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        new TREXImplementationAuthority(address(accessManager), v0, impls);
    }

    function test_constructor_RevertWhen_McImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v0Impls();
        impls.mcImplementation = address(0);

        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        new TREXImplementationAuthority(address(accessManager), v0, impls);
    }

    // ---------- publishAndUpgrade happy path ----------

    function test_publishAndUpgrade_VersionManagerCanPublishNewVersion() public {
        ITREXImplementationAuthority.SuiteBeacons memory beforeUpgrade = authority.current();

        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());

        ITREXImplementationAuthority.SuiteBeacons memory afterUpgrade = authority.current();

        // beacons must NOT change
        assertEq(beforeUpgrade.tokenBeacon, afterUpgrade.tokenBeacon);
        assertEq(beforeUpgrade.trexRegistryBeacon, afterUpgrade.trexRegistryBeacon);
        assertEq(beforeUpgrade.irsBeacon, afterUpgrade.irsBeacon);
        assertEq(beforeUpgrade.mcBeacon, afterUpgrade.mcBeacon);

        // implementations must switch to v1
        assertEq(UpgradeableBeacon(afterUpgrade.tokenBeacon).implementation(), address(tokenImplV1));
        assertEq(UpgradeableBeacon(afterUpgrade.trexRegistryBeacon).implementation(), address(trexRegistryImplV1));
        assertEq(UpgradeableBeacon(afterUpgrade.irsBeacon).implementation(), address(irsImplV1));
        assertEq(UpgradeableBeacon(afterUpgrade.mcBeacon).implementation(), address(mcImplV1));
    }

    function test_publishAndUpgrade_ArchivesV1Implementations() public {
        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());

        ITREXImplementationAuthority.SuiteImplementations memory archived = authority.implementationsFor(v1);

        assertEq(archived.tokenImplementation, address(tokenImplV1));
        assertEq(archived.trexRegistryImplementation, address(trexRegistryImplV1));
        assertEq(archived.irsImplementation, address(irsImplV1));
        assertEq(archived.mcImplementation, address(mcImplV1));
    }

    function test_publishAndUpgrade_UpdatesLatestVersion() public {
        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());

        ITREXImplementationAuthority.Version memory latest = authority.latestVersion();

        assertEq(latest.major, v1.major);
        assertEq(latest.minor, v1.minor);
        assertEq(latest.patch, v1.patch);
    }

    function test_publishAndUpgrade_KeepsV0ArchiveIntact() public {
        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());

        ITREXImplementationAuthority.SuiteImplementations memory archivedV0 = authority.implementationsFor(v0);

        assertEq(archivedV0.tokenImplementation, address(tokenImplV0));
        assertEq(archivedV0.trexRegistryImplementation, address(trexRegistryImplV0));
        assertEq(archivedV0.irsImplementation, address(irsImplV0));
        assertEq(archivedV0.mcImplementation, address(mcImplV0));
    }

    // ---------- publishAndUpgrade reverts ----------

    function test_publishAndUpgrade_RevertWhen_NotVersionManager() public {
        vm.prank(notVersionManager);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notVersionManager));
        authority.publishAndUpgrade(v1, _v1Impls());
    }

    function test_publishAndUpgrade_RevertWhen_DuplicateVersion() public {
        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.VersionAlreadyPublished.selector);
        authority.publishAndUpgrade(v0, _v1Impls());
    }

    function test_publishAndUpgrade_RevertWhen_TokenImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v1Impls();
        impls.tokenImplementation = address(0);

        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        authority.publishAndUpgrade(v1, impls);
    }

    function test_publishAndUpgrade_RevertWhen_TrexRegistryImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v1Impls();
        impls.trexRegistryImplementation = address(0);

        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        authority.publishAndUpgrade(v1, impls);
    }

    function test_publishAndUpgrade_RevertWhen_IrsImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v1Impls();
        impls.irsImplementation = address(0);

        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        authority.publishAndUpgrade(v1, impls);
    }

    function test_publishAndUpgrade_RevertWhen_McImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v1Impls();
        impls.mcImplementation = address(0);

        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        authority.publishAndUpgrade(v1, impls);
    }

    // ---------- publish (archive only) ----------

    function test_publish_DoesNotChangeBeaconImplementations() public {
        vm.prank(versionManager);
        authority.publish(v1, _v1Impls());

        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();

        // beacons still resolve to the v0 implementations: publish must not touch any beacon
        assertEq(UpgradeableBeacon(bs.tokenBeacon).implementation(), address(tokenImplV0));
        assertEq(UpgradeableBeacon(bs.trexRegistryBeacon).implementation(), address(trexRegistryImplV0));
        assertEq(UpgradeableBeacon(bs.irsBeacon).implementation(), address(irsImplV0));
        assertEq(UpgradeableBeacon(bs.mcBeacon).implementation(), address(mcImplV0));
    }

    function test_publish_AdvancesLatestVersionButNotCurrentVersion() public {
        vm.prank(versionManager);
        authority.publish(v1, _v1Impls());

        ITREXImplementationAuthority.Version memory latest = authority.latestVersion();
        assertEq(latest.major, v1.major);
        assertEq(latest.minor, v1.minor);
        assertEq(latest.patch, v1.patch);

        // active version stays at v0 until a separate upgrade rotates the beacons
        ITREXImplementationAuthority.Version memory active = authority.currentVersion();
        assertEq(active.major, v0.major);
        assertEq(active.minor, v0.minor);
        assertEq(active.patch, v0.patch);
    }

    function test_publish_ArchivesImplementations() public {
        vm.prank(versionManager);
        authority.publish(v1, _v1Impls());

        ITREXImplementationAuthority.SuiteImplementations memory archived = authority.implementationsFor(v1);
        assertEq(archived.tokenImplementation, address(tokenImplV1));
        assertEq(archived.mcImplementation, address(mcImplV1));
    }

    function test_publish_EmitsVersionPublished() public {
        vm.expectEmit(true, true, true, true);
        emit EventsLib.VersionPublished(v1, _v1Impls());

        vm.prank(versionManager);
        authority.publish(v1, _v1Impls());
    }

    function test_publish_RevertWhen_NotVersionManager() public {
        vm.prank(notVersionManager);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notVersionManager));
        authority.publish(v1, _v1Impls());
    }

    function test_publish_RevertWhen_DuplicateVersion() public {
        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.VersionAlreadyPublished.selector);
        authority.publish(v0, _v1Impls());
    }

    function test_publish_RevertWhen_McImplementationIsZero() public {
        ITREXImplementationAuthority.SuiteImplementations memory impls = _v1Impls();
        impls.mcImplementation = address(0);

        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.EmptyImplementations.selector);
        authority.publish(v1, impls);
    }

    // ---------- upgrade (rotate beacons to a published version) ----------

    function test_upgrade_RotatesBeaconsToPublishedVersion() public {
        vm.startPrank(versionManager);
        authority.publish(v1, _v1Impls());
        authority.upgrade(v1);
        vm.stopPrank();

        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();
        assertEq(UpgradeableBeacon(bs.tokenBeacon).implementation(), address(tokenImplV1));
        assertEq(UpgradeableBeacon(bs.trexRegistryBeacon).implementation(), address(trexRegistryImplV1));
        assertEq(UpgradeableBeacon(bs.irsBeacon).implementation(), address(irsImplV1));
        assertEq(UpgradeableBeacon(bs.mcBeacon).implementation(), address(mcImplV1));
    }

    function test_upgrade_UpdatesCurrentVersion() public {
        vm.startPrank(versionManager);
        authority.publish(v1, _v1Impls());
        authority.upgrade(v1);
        vm.stopPrank();

        ITREXImplementationAuthority.Version memory active = authority.currentVersion();
        assertEq(active.major, v1.major);
        assertEq(active.minor, v1.minor);
        assertEq(active.patch, v1.patch);
    }

    function test_upgrade_EmitsSuiteUpgraded() public {
        vm.prank(versionManager);
        authority.publish(v1, _v1Impls());

        vm.expectEmit(true, true, true, true);
        emit EventsLib.SuiteUpgraded(v1, _v1Impls());

        vm.prank(versionManager);
        authority.upgrade(v1);
    }

    function test_upgrade_CanRollBackToEarlierVersion() public {
        vm.startPrank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());
        // roll back to v0 — still a published version, beacons must return to the v0 implementations
        authority.upgrade(v0);
        vm.stopPrank();

        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();
        assertEq(UpgradeableBeacon(bs.tokenBeacon).implementation(), address(tokenImplV0));

        // latest published is still v1, active rolled back to v0
        assertEq(authority.latestVersion().major, v1.major);
        assertEq(authority.currentVersion().major, v0.major);
    }

    function test_upgrade_RevertWhen_UnknownVersion() public {
        vm.prank(versionManager);
        vm.expectRevert(ErrorsLib.UnknownVersion.selector);
        authority.upgrade(v1);
    }

    function test_upgrade_RevertWhen_NotVersionManager() public {
        vm.prank(versionManager);
        authority.publish(v1, _v1Impls());

        vm.prank(notVersionManager);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notVersionManager));
        authority.upgrade(v1);
    }

    // ---------- publishAndUpgrade wrapper ----------

    function test_publishAndUpgrade_UpdatesCurrentVersion() public {
        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());

        ITREXImplementationAuthority.Version memory active = authority.currentVersion();
        assertEq(active.major, v1.major);
        assertEq(active.minor, v1.minor);
        assertEq(active.patch, v1.patch);
    }

    function test_publishAndUpgrade_EmitsVersionPublishedThenSuiteUpgraded() public {
        vm.expectEmit(true, true, true, true);
        emit EventsLib.VersionPublished(v1, _v1Impls());
        vm.expectEmit(true, true, true, true);
        emit EventsLib.SuiteUpgraded(v1, _v1Impls());

        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());
    }

    // ---------- read API ----------

    function test_beaconsFor_ReturnsSameAddressesAsCurrent_ForKnownVersion() public view {
        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.beaconsFor(v0);
        ITREXImplementationAuthority.SuiteBeacons memory cs = authority.current();

        assertEq(bs.tokenBeacon, cs.tokenBeacon);
        assertEq(bs.trexRegistryBeacon, cs.trexRegistryBeacon);
        assertEq(bs.irsBeacon, cs.irsBeacon);
        assertEq(bs.mcBeacon, cs.mcBeacon);
    }

    function test_beaconsFor_RevertWhen_UnknownVersion() public {
        vm.expectRevert(ErrorsLib.UnknownVersion.selector);
        authority.beaconsFor(v1);
    }

    function test_implementationsFor_RevertWhen_UnknownVersion() public {
        vm.expectRevert(ErrorsLib.UnknownVersion.selector);
        authority.implementationsFor(v1);
    }

    function test_beacons_StableAcrossVersions() public {
        ITREXImplementationAuthority.SuiteBeacons memory beforeUpgrade = authority.beacons();

        vm.prank(versionManager);
        authority.publishAndUpgrade(v1, _v1Impls());

        ITREXImplementationAuthority.SuiteBeacons memory afterUpgrade = authority.beacons();

        assertEq(beforeUpgrade.tokenBeacon, afterUpgrade.tokenBeacon);
        assertEq(beforeUpgrade.trexRegistryBeacon, afterUpgrade.trexRegistryBeacon);
        assertEq(beforeUpgrade.irsBeacon, afterUpgrade.irsBeacon);
        assertEq(beforeUpgrade.mcBeacon, afterUpgrade.mcBeacon);
    }

    // ---------- beacon-level access control ----------

    function test_beacon_EOACannotCallUpgradeToDirectly() public {
        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();

        vm.prank(versionManager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, versionManager));
        UpgradeableBeacon(bs.tokenBeacon).upgradeTo(address(tokenImplV1));
    }

    function test_beacon_NonManagerEOACannotCallUpgradeToDirectly() public {
        ITREXImplementationAuthority.SuiteBeacons memory bs = authority.current();

        vm.prank(notVersionManager);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notVersionManager));
        UpgradeableBeacon(bs.tokenBeacon).upgradeTo(address(tokenImplV1));
    }

    // ---------- helpers ----------

    function _v0Impls() private view returns (ITREXImplementationAuthority.SuiteImplementations memory) {
        return ITREXImplementationAuthority.SuiteImplementations({
            tokenImplementation: address(tokenImplV0),
            trexRegistryImplementation: address(trexRegistryImplV0),
            irsImplementation: address(irsImplV0),
            mcImplementation: address(mcImplV0)
        });
    }

    function _v1Impls() private view returns (ITREXImplementationAuthority.SuiteImplementations memory) {
        return ITREXImplementationAuthority.SuiteImplementations({
            tokenImplementation: address(tokenImplV1),
            trexRegistryImplementation: address(trexRegistryImplV1),
            irsImplementation: address(irsImplV1),
            mcImplementation: address(mcImplV1)
        });
    }

}

// ---------- dummy implementations ----------
// Each dummy is a distinct contract so its address differs and so that
// UpgradeableBeacon._setImplementation's `code.length > 0` invariant holds.

contract DummyTokenV0 {

    function marker() external pure returns (string memory) {
        return "token-v0";
    }

}

contract DummyTokenV1 {

    function marker() external pure returns (string memory) {
        return "token-v1";
    }

}

contract DummyTrexRegistryV0 {

    function marker() external pure returns (string memory) {
        return "trex-registry-v0";
    }

}

contract DummyTrexRegistryV1 {

    function marker() external pure returns (string memory) {
        return "trex-registry-v1";
    }

}

contract DummyIrsV0 {

    function marker() external pure returns (string memory) {
        return "irs-v0";
    }

}

contract DummyIrsV1 {

    function marker() external pure returns (string memory) {
        return "irs-v1";
    }

}

contract DummyMcV0 {

    function marker() external pure returns (string memory) {
        return "mc-v0";
    }

}

contract DummyMcV1 {

    function marker() external pure returns (string memory) {
        return "mc-v1";
    }

}

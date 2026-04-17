// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

contract TREXRegistryIdentityUnitTest is TREXRegistryBaseUnitTest {

    function setUp() public override {
        super.setUp();
        _registerBaseIdentities();
    }

    // ============ registerIdentity() ============

    function test_registerIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.registerIdentity(another, aliceIdentity, 1);
    }

    function test_registerIdentity_Success_EmitsEvent() public {
        IIdentity newIdentity = _deployIdentity(another, "another");
        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(registry));
        emit ERC3643EventsLib.IdentityRegistered(another, newIdentity);
        registry.registerIdentity(another, newIdentity, 1);

        assertTrue(registry.contains(another));
        assertEq(address(registry.identity(another)), address(newIdentity));
    }

    // ============ updateIdentity() ============

    function test_updateIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.updateIdentity(bob, charlieIdentity);
    }

    function test_updateIdentity_Success_EmitsEvent() public {
        IIdentity old = registry.identity(bob);
        assertEq(address(old), address(bobIdentity));

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(registry));
        emit ERC3643EventsLib.IdentityUpdated(old, charlieIdentity);
        registry.updateIdentity(bob, charlieIdentity);

        assertEq(address(registry.identity(bob)), address(charlieIdentity));
    }

    // ============ updateCountry() ============

    /// @notice `updateCountry` is no longer wired to AGENT, so an agent is stopped by the
    ///         AccessManager before reaching the deprecated body.
    function test_updateCountry_RevertWhen_NotAdmin() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.updateCountry(bob, 999);
    }

    /// @notice The investor country now lives in a claim on the identity, so `updateCountry` is
    ///         deprecated. The selector defaults to ADMIN_ROLE, which this contract holds.
    function test_updateCountry_RevertWhen_Deprecated() public {
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.updateCountry(bob, 999);
    }

    // ============ deleteIdentity() ============

    function test_deleteIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.deleteIdentity(bob);
    }

    function test_deleteIdentity_Success() public {
        IIdentity old = registry.identity(bob);

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(registry));
        emit ERC3643EventsLib.IdentityRemoved(bob, old);
        registry.deleteIdentity(bob);

        // The local entry is gone; `contains` still resolves bob through the global IdFactory
        // fallback, so the local view is the one that moves.
        assertFalse(registry.isLocallyRegistered(bob));
        assertTrue(registry.contains(bob));
    }

    // ============ batchRegisterIdentity() ============

    /// @notice `batchRegisterIdentity` is not `restricted`, it just iterates `registerIdentity`.
    ///         When only `registerIdentity.selector` is granted to AGENT, the inner `restricted`
    ///         check reads `batchRegisterIdentity.selector` from calldata and reverts.
    function test_batchRegisterIdentity_RevertWhen_SelectorNotGrantedToAgent() public {
        IIdentity i1 = _deployIdentity(another, "another");

        address[] memory addrs = new address[](1);
        addrs[0] = another;
        IIdentity[] memory ids = new IIdentity[](1);
        ids[0] = i1;
        uint16[] memory countries = new uint16[](1);
        countries[0] = 1;

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        registry.batchRegisterIdentity(addrs, ids, countries);
    }

    /// @notice With the production wiring from `AccessManagerSetupLib`, which binds
    ///         `batchRegisterIdentity.selector` to AGENT precisely because the inner `restricted`
    ///         check reads the outer selector, an agent can batch-register.
    function test_batchRegisterIdentity_Success_WithProductionRoleWiring() public {
        // Re-wire with the real library (this contract is the AccessManager admin).
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, address(registry));

        address second = makeAddr("secondBatchUser");

        IIdentity firstIdentity = _deployIdentity(another, "another");
        IIdentity secondIdentity = _deployIdentity(second, "secondBatchUser");

        address[] memory addrs = new address[](2);
        addrs[0] = another;
        addrs[1] = second;
        IIdentity[] memory ids = new IIdentity[](2);
        ids[0] = firstIdentity;
        ids[1] = secondIdentity;
        uint16[] memory countries = new uint16[](2);
        countries[0] = 250;
        countries[1] = 840;

        vm.prank(agent);
        registry.batchRegisterIdentity(addrs, ids, countries);

        assertEq(address(registry.identity(another)), address(firstIdentity));
        assertEq(address(registry.identity(second)), address(secondIdentity));
        assertTrue(registry.isLocallyRegistered(another));
        assertTrue(registry.isLocallyRegistered(second));
        // The country passed to register is vestigial: `investorCountry` reads the identity's
        // country claim, and neither of these freshly deployed identities carries one.
        assertEq(registry.investorCountry(another), 0);
        assertEq(registry.investorCountry(second), 0);
    }

    // ============ setIdentityRegistryStorage() ============

    function test_setIdentityRegistryStorage_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.setIdentityRegistryStorage(address(0));
    }

    function test_setIdentityRegistryStorage_Success_EmitsEvent() public {
        vm.prank(deployer);
        vm.expectEmit(true, false, false, false, address(registry));
        emit ERC3643EventsLib.IdentityStorageSet(address(0));
        registry.setIdentityRegistryStorage(address(0));

        assertEq(address(registry.identityStorage()), address(0));
    }

    // ============ setClaimTopicsRegistry() / setTrustedIssuersRegistry() — deprecated ============

    function test_setClaimTopicsRegistry_RevertWhen_Deprecated_AsOwner() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setClaimTopicsRegistry(address(0xBEEF));
    }

    function test_setClaimTopicsRegistry_RevertWhen_Deprecated_AsOther() public {
        // Deprecation takes precedence — even non-owners get Deprecated, never the access-managed error.
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setClaimTopicsRegistry(address(0xBEEF));
    }

    function test_setTrustedIssuersRegistry_RevertWhen_Deprecated_AsOwner() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setTrustedIssuersRegistry(address(0xBEEF));
    }

    function test_setTrustedIssuersRegistry_RevertWhen_Deprecated_AsOther() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setTrustedIssuersRegistry(address(0xBEEF));
    }

    // ============ identityStorage / topicsRegistry / issuersRegistry ============

    function test_subRegistries_ReturnExpectedAddresses() public view {
        assertEq(address(registry.identityStorage()), address(identityRegistryStorage));
        assertEq(address(registry.topicsRegistry()), address(registry));
        assertEq(address(registry.issuersRegistry()), address(registry));
    }

}

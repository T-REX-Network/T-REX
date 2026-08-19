// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import {
    IERC3643IdentityRegistryStorage,
    IdentityRegistryStorage
} from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { MockContract } from "../mocks/MockContract.sol";
import { Countries } from "test/integration/helpers/Countries.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract IdentityRegistryStorageTest is TREXSuiteTest {

    // Contracts
    IdentityRegistryStorage public identityRegistryStorage;

    /// @notice Sets up IdentityRegistryStorage via proxy
    function setUp() public override {
        super.setUp();

        identityRegistryStorage = IdentityRegistryStorage(address(token.identityRegistry().identityStorage()));

        // bindIdentityRegistry is now gated by the transient IRS_BINDER role (not OWNER). deployer
        // already holds OWNER for the suite; grant it IRS_BINDER too so the bind-path tests can run.
        _grantIRSBinderRole(deployer);

        // Note: In Hardhat fixture, identityRegistry.target is bound to storage in setUp
        // For Foundry, we start with 0 bound registries (tests will bind as needed)
    }

    // ============ init() Tests ============

    /// @notice Should revert when contract was already initialized
    function test_init_RevertWhen_AlreadyInitialized() public {
        vm.prank(deployer);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        identityRegistryStorage.init(deployer, address(0), address(idFactory));
    }

    /// @notice Should revert when idFactory is the zero address. The proxy bubbles init's revert,
    ///         so the ZeroAddress error surfaces as-is.
    function test_init_RevertWhen_IdFactoryZeroAddress() public {
        address irsBeacon = trexImplementationAuthority.beacons().irsBeacon;

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new BeaconProxy(
            irsBeacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0), address(0)))
        );
    }

    // ============ addIdentityToStorage() Tests ============

    /// @notice Should revert when sender is not agent
    function test_addIdentityToStorage_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.addIdentityToStorage(charlie, charlieIdentity, Countries.UNITED_STATES);
    }

    /// @notice Should revert when identity is zero address
    function test_addIdentityToStorage_RevertWhen_IdentityZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.addIdentityToStorage(charlie, IIdentity(address(0)), Countries.UNITED_STATES);
    }

    /// @notice Should revert when wallet is zero address
    function test_addIdentityToStorage_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.addIdentityToStorage(address(0), charlieIdentity, Countries.UNITED_STATES);
    }

    /// @notice Should revert when wallet is already registered
    function test_addIdentityToStorage_RevertWhen_AlreadyStored() public {
        // Try to add bob again
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressAlreadyStored.selector);
        identityRegistryStorage.addIdentityToStorage(bob, charlieIdentity, Countries.FRANCE);
    }

    // ============ modifyStoredIdentity() Tests ============

    /// @notice Should revert when sender is not agent
    function test_modifyStoredIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.modifyStoredIdentity(charlie, charlieIdentity);
    }

    /// @notice Should revert when identity is zero address
    function test_modifyStoredIdentity_RevertWhen_IdentityZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.modifyStoredIdentity(charlie, IIdentity(address(0)));
    }

    /// @notice Should revert when wallet is zero address
    function test_modifyStoredIdentity_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.modifyStoredIdentity(address(0), charlieIdentity);
    }

    /// @notice Should revert when wallet is not registered
    function test_modifyStoredIdentity_RevertWhen_NotStored() public {
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(charlie);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        identityRegistryStorage.modifyStoredIdentity(charlie, charlieIdentity);
    }

    // ============ modifyStoredInvestorCountry() Tests ============

    /// @notice Should revert with Deprecated. modifyStoredInvestorCountry is no longer wired to any
    ///         role, so it defaults to ADMIN_ROLE, which the test contract holds.
    function test_modifyStoredInvestorCountry_RevertWhen_Deprecated() public {
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        identityRegistryStorage.modifyStoredInvestorCountry(bob, Countries.UNITED_STATES);
    }

    // ============ removeIdentityFromStorage() Tests ============

    /// @notice Should revert when sender is not agent
    function test_removeIdentityFromStorage_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.removeIdentityFromStorage(charlie);
    }

    /// @notice Should revert when wallet is zero address
    function test_removeIdentityFromStorage_RevertWhen_WalletZeroAddress() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.removeIdentityFromStorage(address(0));
    }

    /// @notice Should revert when wallet is not registered
    function test_removeIdentityFromStorage_RevertWhen_NotStored() public {
        vm.prank(agent);
        identityRegistryStorage.removeIdentityFromStorage(charlie);

        vm.prank(agent);
        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        identityRegistryStorage.removeIdentityFromStorage(charlie);
    }

    // ============ bindIdentityRegistry() Tests ============

    /// @notice Should revert when sender lacks the IRS_BINDER role
    function test_bindIdentityRegistry_RevertWhen_NotBinder() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.bindIdentityRegistry(address(charlieIdentity));
    }

    /// @notice bind is gated by IRS_BINDER, not OWNER: holding OWNER alone must not authorize a bind.
    function test_bindIdentityRegistry_RevertWhen_OwnerWithoutBinderRole() public {
        address ownerOnly = makeAddr("ownerOnly");
        _grantOwnerRole(ownerOnly);

        vm.prank(ownerOnly);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ownerOnly));
        identityRegistryStorage.bindIdentityRegistry(address(charlieIdentity));
    }

    /// @notice Should revert when identity registry is zero address. The onlySharedAuthority guard rejects
    ///         address(0) (it cannot share the storage's authority), so the bind never proceeds.
    function test_bindIdentityRegistry_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.AuthorityMismatch.selector);
        identityRegistryStorage.bindIdentityRegistry(address(0));
    }

    /// @notice Should revert when there are already 299 identity registries bound
    function test_bindIdentityRegistry_RevertWhen_MoreThan299Registries() public {
        // Add 300 registries (max is 300, so length 300 means we have 300 registries)
        // Check is length < 300, so when length is 299, we can add one more (300th)
        // When length is 300, we cannot add more (301st should fail)
        for (uint256 i = 1; i < 300; i++) {
            address registryAddress = vm.addr(i + 1000);
            // bindIdentityRegistry is gated by onlySharedAuthority: each registry must report the storage's
            // AccessManager as its authority.
            vm.mockCall(
                registryAddress,
                abi.encodeWithSelector(IAccessManaged.authority.selector),
                abi.encode(address(accessManager))
            );
            vm.prank(deployer);
            identityRegistryStorage.bindIdentityRegistry(registryAddress);
        }

        // Try to add 301st registry (should fail, length is now 300, not < 300). It must also share the
        // authority so it reaches the count check rather than reverting on onlySharedAuthority first.
        address extraRegistry = vm.addr(2000);
        vm.mockCall(
            extraRegistry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.MaxIRByIRSReached.selector, 300));
        identityRegistryStorage.bindIdentityRegistry(extraRegistry);
    }

    // ============ unbindIdentityRegistry() Tests ============

    /// @notice Should revert when sender is not owner
    function test_unbindIdentityRegistry_RevertWhen_NotOwner() public {
        // Bind first. bindIdentityRegistry is gated by onlySharedAuthority, so the bound address must report
        // the storage's AccessManager as its authority.
        vm.mockCall(
            address(charlieIdentity),
            abi.encodeWithSelector(IAccessManaged.authority.selector),
            abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(address(charlieIdentity));

        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.unbindIdentityRegistry(address(charlieIdentity));
    }

    /// @notice Should revert when identity registry is zero address
    function test_unbindIdentityRegistry_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.unbindIdentityRegistry(address(0));
    }

    /// @notice Should revert when identity registry is not bound
    function test_unbindIdentityRegistry_RevertWhen_NotBound() public {
        address identityRegistry = address(token.identityRegistry());

        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);

        vm.expectRevert(ErrorsLib.IdentityRegistryNotStored.selector);
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);
    }

    /// @notice Should unbind the identity registry
    function test_unbindIdentityRegistry_Success() public {
        address identityRegistry = address(token.identityRegistry());

        vm.expectEmit(true, false, false, false);
        emit ERC3643EventsLib.IdentityRegistryUnbound(identityRegistry);
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(identityRegistry);
    }

    /// @notice Should unbind a registry located past index 0 (exercises the loop increment)
    function test_unbindIdentityRegistry_Success_WhenNotFirst() public {
        address firstIR = address(token.identityRegistry());
        address secondIR = makeAddr("secondIR");

        // bindIdentityRegistry is gated by onlySharedAuthority: the bound address must report the
        // storage's AccessManager as its authority.
        vm.mockCall(
            secondIR, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(secondIR);

        // Unbind the second one — match is at index 1, so the loop increments past index 0
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(secondIR);

        address[] memory linked = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(linked.length, 1);
        assertEq(linked[0], firstIR);
    }

    // ============ linkedIdentityRegistries() Tests ============

    /// @notice Should return the list of bound identity registries
    function test_linkedIdentityRegistries_ReturnsBoundRegistries() public {
        address existingIR = address(token.identityRegistry());

        // Initially only the suite's IR is bound
        address[] memory initial = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(initial.length, 1);
        assertEq(initial[0], existingIR);

        // Bind another registry and verify it appears. It must share the storage's authority to pass
        // the onlySharedAuthority guard.
        address extraIR = makeAddr("extraIR");
        vm.mockCall(
            extraIR, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(extraIR);

        address[] memory updated = identityRegistryStorage.linkedIdentityRegistries();
        assertEq(updated.length, 2);
        assertEq(updated[0], existingIR);
        assertEq(updated[1], extraIR);
    }

    // ============ storedIdentity() Fallback Tests ============

    /// @notice storedIdentity returns the local identity when present (no fallback to global)
    function test_storedIdentity_UsesLocal_WhenPresent() public view {
        assertEq(address(identityRegistryStorage.storedIdentity(bob)), address(bobIdentity));
    }

    /// @notice storedIdentity falls back to the global identity registry when no local identity is stored
    function test_storedIdentity_FallsBackToGlobal_WhenLocalMissing() public {
        // `another` is a fresh wallet that has never been added to the local IRS.
        // Create its identity directly in the global IdentityFactory and check the fallback.
        address globalIdentity = address(_deployIdentity(another, "another"));

        assertEq(address(identityRegistryStorage.storedIdentity(another)), globalIdentity);
    }

    /// @notice storedIdentity returns address(0) when the wallet is unknown to both local and global
    function test_storedIdentity_ReturnsZero_WhenUnknownEverywhere() public view {
        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(0));
    }

    /// @notice storedInvestorCountry always returns 0 (country is now on the identity claim)
    function test_storedInvestorCountry_AlwaysReturnsZero() public view {
        assertEq(identityRegistryStorage.storedInvestorCountry(bob), 0);
        assertEq(identityRegistryStorage.storedInvestorCountry(another), 0);
    }

    // ============ setIdFactory() Tests ============

    /// @notice Should revert when sender is not authorized
    function test_setIdFactory_RevertWhen_NotOwner() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        identityRegistryStorage.setIdFactory(address(idFactory));
    }

    /// @notice Should revert when the new idFactory is the zero address
    function test_setIdFactory_RevertWhen_ZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        identityRegistryStorage.setIdFactory(address(0));
    }

    /// @notice Should update the idFactory and affect subsequent fallbacks
    function test_setIdFactory_Success() public {
        // Deploy a fresh IdentityFactory and register `another` only in it.
        IdentityFactory newIdFactory = _newIdentityFactory();
        newIdFactory.initializeBeacon(address(identityImplementation));
        address newGlobalIdentity = address(_deployIdentityIn(newIdFactory, another, "another"));

        vm.prank(deployer);
        identityRegistryStorage.setIdFactory(address(newIdFactory));

        assertEq(identityRegistryStorage.idFactory(), address(newIdFactory));
        assertEq(address(identityRegistryStorage.storedIdentity(another)), newGlobalIdentity);
    }

    // ============ supportsInterface() Tests ============

    /// @notice Should return false for unsupported interfaces
    function test_supportsInterface_ReturnsFalse_ForUnsupported() public view {
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(identityRegistryStorage.supportsInterface(unsupportedInterfaceId));
    }

    /// @notice Should correctly identify the IERC3643IdentityRegistryStorage interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC3643IdentityRegistryStorage() public view {
        assertTrue(identityRegistryStorage.supportsInterface(type(IERC3643IdentityRegistryStorage).interfaceId));
    }

    /// @notice IERC173 is part of the public interface via the AccessManagerOwnable ERC-173 ownership shim
    function test_supportsInterface_ReturnsTrue_ForIERC173() public view {
        assertTrue(identityRegistryStorage.supportsInterface(type(IERC173).interfaceId));
    }

    /// @notice Should correctly identify the IERC165 interface ID
    function test_supportsInterface_ReturnsTrue_ForIERC165() public view {
        assertTrue(identityRegistryStorage.supportsInterface(type(IERC165).interfaceId));
    }

    // ============ Constructor Tests ============

    /// @notice Should revert when the beacon is the zero address
    function test_constructor_RevertWhen_BeaconIsZeroAddress() public {
        vm.expectRevert();
        new BeaconProxy(
            address(0), abi.encodeCall(IdentityRegistryStorage.init, (deployer, address(0), address(idFactory)))
        );
    }

    /// @notice Should revert when initialization fails (implementation without init())
    function test_constructor_RevertWhen_InitializationFails() public {
        MockContract mockImpl = new MockContract();
        address beacon = address(new UpgradeableBeacon(address(mockImpl), address(this)));

        // the delegatecall to mockImpl.init() finds no such function, so the proxy constructor reverts
        vm.expectRevert();
        new BeaconProxy(
            beacon, abi.encodeCall(IdentityRegistryStorage.init, (deployer, address(0), address(idFactory)))
        );
    }

}

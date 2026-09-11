// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
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
import { EventsLib } from "contracts/libraries/EventsLib.sol";
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
        identityRegistryStorage.init(deployer, address(0));
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

    /// @notice The country argument is ignored: only `IdentityStored` is emitted and no country is recorded.
    function test_addIdentityToStorage_IgnoresCountry() public {
        vm.recordLogs();
        vm.prank(agent);
        identityRegistryStorage.addIdentityToStorage(another, charlieIdentity, Countries.FRANCE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], ERC3643EventsLib.IdentityStored.selector);
        assertEq(identityRegistryStorage.storedInvestorCountry(another), 0);
    }

    // ============ modifyStoredIdentity() Tests ============

    /// @notice `InvestorIdentityChanged` names the wallet the standard `IdentityModified` omits.
    function test_modifyStoredIdentity_EmitsInvestorIdentityChanged() public {
        vm.expectEmit(address(identityRegistryStorage));
        emit ERC3643EventsLib.IdentityModified(bobIdentity, charlieIdentity);
        vm.expectEmit(address(identityRegistryStorage));
        emit EventsLib.InvestorIdentityChanged(bob);
        vm.prank(agent);
        identityRegistryStorage.modifyStoredIdentity(bob, charlieIdentity);

        assertEq(address(identityRegistryStorage.storedIdentity(bob)), address(charlieIdentity));
    }

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

    // ============ modifyStoredInvestorCountry() — deprecated ============

    /// @notice Deprecated: the storage keeps no country, so even an agent hits `Deprecated()`.
    function test_modifyStoredInvestorCountry_RevertWhen_Deprecated_AsAgent() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        identityRegistryStorage.modifyStoredInvestorCountry(charlie, Countries.UNITED_STATES);
    }

    /// @notice Deprecation takes precedence — non-agents get `Deprecated()`, never the access-managed error.
    function test_modifyStoredInvestorCountry_RevertWhen_Deprecated_AsOther() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        identityRegistryStorage.modifyStoredInvestorCountry(charlie, Countries.UNITED_STATES);
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

    // ============ storedIdentity() fallback / storedInvestorCountry() deprecated ============

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

    /// @notice storedInvestorCountry returns 0 for every wallet, local or global-only
    function test_storedInvestorCountry_ReturnsZero_ForAnyWallet() public {
        _deployIdentity(another, "another");
        assertEq(identityRegistryStorage.storedInvestorCountry(bob), 0);
        assertEq(identityRegistryStorage.storedInvestorCountry(another), 0);
    }

    /// @notice With no registry bound there is no factory to fall back to: a global-only wallet
    ///         resolves to the zero identity
    function test_storedIdentity_ReturnsZero_WhenNoRegistryBound() public {
        address globalIdentity = address(_deployIdentity(another, "another"));
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(address(token.identityRegistry()));

        assertEq(address(identityRegistryStorage.storedIdentity(another)), address(0));
        assertNotEq(globalIdentity, address(0));
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
        new BeaconProxy(address(0), abi.encodeCall(IdentityRegistryStorage.init, (deployer, address(0))));
    }

    /// @notice Should revert when initialization fails (implementation without init())
    function test_constructor_RevertWhen_InitializationFails() public {
        MockContract mockImpl = new MockContract();
        address beacon = address(new UpgradeableBeacon(address(mockImpl), address(this)));

        // the delegatecall to mockImpl.init() finds no such function, so the proxy constructor reverts
        vm.expectRevert();
        new BeaconProxy(beacon, abi.encodeCall(IdentityRegistryStorage.init, (deployer, address(0))));
    }

}

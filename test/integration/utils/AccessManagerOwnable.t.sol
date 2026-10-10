// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";

import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice Covers the ERC-173 ownership compatibility shim that the suite contracts inherit on top
///         of AccessManager. `owner()` mirrors the AccessManager authority, only the current authority can
///         change it, and every change emits `OwnershipTransferred` exactly once, whichever path made it.
contract AccessManagerOwnableTest is TREXSuiteTest {

    /// @dev Every suite contract inheriting AccessManagerOwnable.
    /// @dev The registry answers `topicsRegistry()` and `issuersRegistry()` with its own address,
    ///      so it is listed once. Listing it three times would make the rotation tests rotate the same
    ///      contract repeatedly, and every call after the first would come from a stale authority.
    /// @dev The suite contracts answer to the suite manager and the platform contracts to the platform
    ///      manager, so each entry carries the authority a test must act as.
    function _shimmedContracts() internal view returns (IERC173[] memory contractsList, address[] memory authorities) {
        contractsList = new IERC173[](6);
        authorities = new address[](6);
        contractsList[0] = IERC173(address(token));
        contractsList[1] = IERC173(address(token.identityRegistry()));
        contractsList[2] = IERC173(address(token.compliance()));
        contractsList[3] = IERC173(address(token.identityRegistry().identityStorage()));
        contractsList[4] = IERC173(address(trexFactory));
        contractsList[5] = IERC173(address(trexImplementationAuthority));
        for (uint256 i = 0; i < 4; i++) {
            authorities[i] = address(suiteManager);
        }
        authorities[4] = address(platformManager);
        authorities[5] = address(platformManager);
    }

    // ============ owner() Tests ============

    /// @notice owner() mirrors the AccessManager set as the contract authority.
    function test_owner_ReturnsAccessManager() public view {
        (IERC173[] memory contractsList, address[] memory authorities) = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            assertEq(contractsList[i].owner(), authorities[i]);
        }
    }

    /// @notice owner() tracks the live authority after it is rotated through the AccessManager.
    function test_owner_TracksAuthorityChange() public {
        // Deploy a second manager that is administered by this test contract so it has code.
        AccessManager newAuthority = new AccessManager(address(this));

        // The current authority (the AccessManager) is the only address allowed to call setAuthority.
        vm.prank(address(suiteManager));
        IAccessManaged(address(token)).setAuthority(address(newAuthority));

        assertEq(IERC173(address(token)).owner(), address(newAuthority));
    }

    /// @notice The non-upgradeable shim exposes the same public setter as the upgradeable one: the
    ///         current authority can rotate `trexFactory` straight through `setAuthority`.
    function test_setAuthority_RotatesNonUpgradeableContract() public {
        AccessManager newAuthority = new AccessManager(address(this));

        vm.prank(address(platformManager));
        IAccessManaged(address(trexFactory)).setAuthority(address(newAuthority));

        assertEq(IERC173(address(trexFactory)).owner(), address(newAuthority));
    }

    // ============ transferOwnership() Tests ============

    /// @notice transferOwnership() forwards to AccessManaged.setAuthority, which only the current authority
    ///         (the AccessManager) may drive. A call from anyone else reverts with AccessManagedUnauthorized.
    function test_transferOwnership_RevertWhen_NotAuthority() public {
        AccessManager newAuthority = new AccessManager(address(this));
        (IERC173[] memory contractsList,) = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.prank(deployer);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
            contractsList[i].transferOwnership(address(newAuthority));
        }
    }

    /// @notice When the current authority drives transferOwnership, the authority is rotated and owner()
    ///         reflects the new AccessManager.
    function test_transferOwnership_Success_WhenCalledByAuthority() public {
        AccessManager newAuthority = new AccessManager(address(this));
        (IERC173[] memory contractsList, address[] memory authorities) = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.prank(authorities[i]);
            contractsList[i].transferOwnership(address(newAuthority));
            assertEq(contractsList[i].owner(), address(newAuthority));
        }
    }

    // ============ OwnershipTransferred Tests ============

    /// @notice The manager's own `updateAuthority` changes the owner without `transferOwnership`, and must still
    ///         announce it, exactly once.
    function test_updateAuthority_EmitsOwnershipTransferredOnce() public {
        AccessManager newAuthority = new AccessManager(address(this));
        (IERC173[] memory contractsList, address[] memory authorities) = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.expectEmit(address(contractsList[i]));
            emit IERC173.OwnershipTransferred(authorities[i], address(newAuthority));
            vm.recordLogs();
            AccessManager(authorities[i]).updateAuthority(address(contractsList[i]), address(newAuthority));
            assertEq(vm.getRecordedLogs().length, 2, "one AuthorityUpdated and one OwnershipTransferred");
        }
    }

    /// @notice `transferOwnership` announces the change exactly once, not twice.
    function test_transferOwnership_EmitsOwnershipTransferredOnce() public {
        AccessManager newAuthority = new AccessManager(address(this));
        (IERC173[] memory contractsList, address[] memory authorities) = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.expectEmit(address(contractsList[i]));
            emit IERC173.OwnershipTransferred(authorities[i], address(newAuthority));
            vm.recordLogs();
            vm.prank(authorities[i]);
            contractsList[i].transferOwnership(address(newAuthority));
            assertEq(vm.getRecordedLogs().length, 2, "one AuthorityUpdated and one OwnershipTransferred");
        }
    }

    /// @notice A contract built with a constructor announces its first owner, from the zero address.
    function test_constructor_EmitsOwnershipTransferredFromZero() public {
        address nextRegistry = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(nextRegistry);
        emit IERC173.OwnershipTransferred(address(0), address(platformManager));
        new TrustedGatewayRegistry(address(platformManager));
    }

    /// @notice A proxy built with an initializer announces its first owner, from the zero address.
    function test_initializer_EmitsOwnershipTransferredFromZero() public {
        address storageImplementation = address(new IdentityRegistryStorage());
        address nextStorage = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(nextStorage);
        emit IERC173.OwnershipTransferred(address(0), address(suiteManager));
        new ERC1967Proxy(
            storageImplementation, abi.encodeCall(IdentityRegistryStorage.init, (address(suiteManager), address(0)))
        );
    }

    /// @notice Ownership cannot be renounced: the owner is the AccessManager, and a zero authority is refused.
    function test_transferOwnership_RevertWhen_RenouncingToZero() public {
        vm.prank(address(suiteManager));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedInvalidAuthority.selector, address(0)));
        IERC173(address(token)).transferOwnership(address(0));
    }

}

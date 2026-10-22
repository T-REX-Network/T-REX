// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";

import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice Covers the ERC-173 ownership compatibility shim that the suite contracts inherit on top
///         of AccessManager. `owner()` mirrors the AccessManager authority, the authority changes only through
///         the manager's `updateAuthority` (`transferOwnership` always reverts), and every change emits
///         `OwnershipTransferred` exactly once.
contract AccessManagerOwnableTest is TREXSuiteTest {

    /// @dev Every suite contract inheriting AccessManagerOwnable.
    /// @dev The registry answers `topicsRegistry()` and `issuersRegistry()` with its own address,
    ///      so it is listed once. Listing it three times would make the rotation tests rotate the same
    ///      contract repeatedly, and every call after the first would come from a stale authority.
    function _shimmedContracts() internal view returns (IERC173[] memory contractsList) {
        contractsList = new IERC173[](6);
        contractsList[0] = IERC173(address(token));
        contractsList[1] = IERC173(address(token.identityRegistry()));
        contractsList[2] = IERC173(address(token.compliance()));
        contractsList[3] = IERC173(address(token.identityRegistry().identityStorage()));
        contractsList[4] = IERC173(address(trexFactory));
        contractsList[5] = IERC173(address(trexImplementationAuthority));
    }

    // ============ owner() Tests ============

    /// @notice owner() mirrors the AccessManager set as the contract authority.
    function test_owner_ReturnsAccessManager() public view {
        IERC173[] memory contractsList = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            assertEq(contractsList[i].owner(), address(accessManager));
        }
    }

    /// @notice owner() tracks the live authority after it is rotated through the AccessManager.
    function test_owner_TracksAuthorityChange() public {
        // Deploy a second manager that is administered by this test contract so it has code.
        AccessManager newAuthority = new AccessManager(address(this));

        // The current authority (the AccessManager) is the only address allowed to call setAuthority.
        vm.prank(address(accessManager));
        IAccessManaged(address(token)).setAuthority(address(newAuthority));

        assertEq(IERC173(address(token)).owner(), address(newAuthority));
    }

    /// @notice The non-upgradeable shim exposes the same public setter as the upgradeable one: the
    ///         current authority can rotate `trexFactory` straight through `setAuthority`.
    function test_setAuthority_RotatesNonUpgradeableContract() public {
        AccessManager newAuthority = new AccessManager(address(this));

        vm.prank(address(accessManager));
        IAccessManaged(address(trexFactory)).setAuthority(address(newAuthority));

        assertEq(IERC173(address(trexFactory)).owner(), address(newAuthority));
    }

    // ============ transferOwnership() Tests ============

    /// @notice transferOwnership() is refused for every caller, the current authority included, and the owner
    ///         stays the same.
    function test_transferOwnership_RevertWhen_CalledByAnyone() public {
        AccessManager newAuthority = new AccessManager(address(this));
        IERC173[] memory contractsList = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.prank(deployer);
            vm.expectRevert(ErrorsLib.UseUpdateAuthority.selector);
            contractsList[i].transferOwnership(address(newAuthority));

            vm.prank(address(accessManager));
            vm.expectRevert(ErrorsLib.UseUpdateAuthority.selector);
            contractsList[i].transferOwnership(address(newAuthority));

            assertEq(contractsList[i].owner(), address(accessManager));
        }
    }

    /// @notice With a target admin delay set, an admin with no execution delay cannot replace the token's
    ///         authority at once: `updateAuthority` must be scheduled, and the manager's `execute` of
    ///         `transferOwnership`, which is mapped to no role and so carries no delay, is refused.
    function test_transferOwnership_RevertWhen_ExecutedToSkipTargetAdminDelay() public {
        AccessManager newAuthority = new AccessManager(address(this));
        accessManager.setTargetAdminDelay(address(token), 1 days);
        // A new target admin delay only takes effect after the manager's minimum setback.
        vm.warp(block.timestamp + accessManager.minSetback() + 1);
        assertEq(accessManager.getTargetAdminDelay(address(token)), 1 days);

        bytes memory updateCall = abi.encodeCall(AccessManager.updateAuthority, (address(token), address(newAuthority)));
        bytes32 updateOperation = accessManager.hashOperation(address(this), address(accessManager), updateCall);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, updateOperation));
        accessManager.updateAuthority(address(token), address(newAuthority));

        vm.expectRevert(ErrorsLib.UseUpdateAuthority.selector);
        accessManager.execute(address(token), abi.encodeCall(IERC173.transferOwnership, (address(newAuthority))));

        assertEq(IERC173(address(token)).owner(), address(accessManager));
    }

    // ============ OwnershipTransferred Tests ============

    /// @notice The manager's own `updateAuthority` changes the owner without `transferOwnership`, and must still
    ///         announce it, exactly once.
    function test_updateAuthority_EmitsOwnershipTransferredOnce() public {
        AccessManager newAuthority = new AccessManager(address(this));
        IERC173[] memory contractsList = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.expectEmit(address(contractsList[i]));
            emit IERC173.OwnershipTransferred(address(accessManager), address(newAuthority));
            vm.recordLogs();
            accessManager.updateAuthority(address(contractsList[i]), address(newAuthority));
            assertEq(vm.getRecordedLogs().length, 2, "one AuthorityUpdated and one OwnershipTransferred");
        }
    }

    /// @notice A contract built with a constructor announces its first owner, from the zero address.
    function test_constructor_EmitsOwnershipTransferredFromZero() public {
        address nextRegistry = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(nextRegistry);
        emit IERC173.OwnershipTransferred(address(0), address(accessManager));
        new TrustedGatewayRegistry(address(accessManager));
    }

    /// @notice A proxy built with an initializer announces its first owner, from the zero address.
    function test_initializer_EmitsOwnershipTransferredFromZero() public {
        address storageImplementation = address(new IdentityRegistryStorage());
        address nextStorage = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(nextStorage);
        emit IERC173.OwnershipTransferred(address(0), address(accessManager));
        new ERC1967Proxy(
            storageImplementation, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0)))
        );
    }

    /// @notice Ownership cannot be renounced: the owner is the AccessManager, and a zero authority is refused.
    function test_updateAuthority_RevertWhen_RenouncingToZero() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedInvalidAuthority.selector, address(0)));
        accessManager.updateAuthority(address(token), address(0));
    }

}

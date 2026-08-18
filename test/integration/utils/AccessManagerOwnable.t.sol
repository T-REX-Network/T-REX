// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice Covers the ERC-173 ownership compatibility shim that the suite contracts inherit on top
///         of AccessManager. `owner()` is expected to mirror the AccessManager authority, while
///         `transferOwnership()` is unsupported because authority changes flow through the
///         AccessManager rather than ERC-173.
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

    /// @notice transferOwnership() forwards to AccessManaged.setAuthority, which only the current authority
    ///         (the AccessManager) may drive. A call from anyone else reverts with AccessManagedUnauthorized.
    function test_transferOwnership_RevertWhen_NotAuthority() public {
        AccessManager newAuthority = new AccessManager(address(this));
        IERC173[] memory contractsList = _shimmedContracts();
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
        IERC173[] memory contractsList = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.prank(address(accessManager));
            contractsList[i].transferOwnership(address(newAuthority));
            assertEq(contractsList[i].owner(), address(newAuthority));
        }
    }

}

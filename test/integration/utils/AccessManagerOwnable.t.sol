// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice Covers the ERC-173 ownership compatibility shim that the suite contracts inherit on top
///         of AccessManager. `owner()` is expected to mirror the AccessManager authority, while
///         `transferOwnership()` is unsupported because authority changes flow through the
///         AccessManager rather than ERC-173.
contract AccessManagerOwnableTest is TREXSuiteTest {

    /// @dev Every suite contract that previously implemented Ownable and now inherits AccessManagerOwnable.
    function _shimmedContracts() internal view returns (IERC173[] memory contractsList) {
        contractsList = new IERC173[](8);
        contractsList[0] = IERC173(address(token));
        contractsList[1] = IERC173(address(token.identityRegistry()));
        contractsList[2] = IERC173(address(token.compliance()));
        contractsList[3] = IERC173(address(token.identityRegistry().topicsRegistry()));
        contractsList[4] = IERC173(address(token.identityRegistry().issuersRegistry()));
        contractsList[5] = IERC173(address(token.identityRegistry().identityStorage()));
        contractsList[6] = IERC173(address(trexFactory));
        contractsList[7] = IERC173(address(trexImplementationAuthority));
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

    // ============ transferOwnership() Tests ============

    /// @notice transferOwnership() is unsupported: authority changes flow through the AccessManager,
    ///         so any call reverts with UnsupportedOperation regardless of the argument or caller.
    function test_transferOwnership_RevertWhen_Called() public {
        AccessManager newAuthority = new AccessManager(address(this));
        IERC173[] memory contractsList = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.prank(deployer);
            vm.expectRevert(ErrorsLib.UnsupportedOperation.selector);
            contractsList[i].transferOwnership(address(newAuthority));
        }
    }

    /// @notice transferOwnership() reverts even with the zero address, before touching any authority.
    function test_transferOwnership_RevertWhen_ZeroAddress() public {
        IERC173[] memory contractsList = _shimmedContracts();
        for (uint256 i = 0; i < contractsList.length; i++) {
            vm.prank(deployer);
            vm.expectRevert(ErrorsLib.UnsupportedOperation.selector);
            contractsList[i].transferOwnership(address(0));
        }
    }

}

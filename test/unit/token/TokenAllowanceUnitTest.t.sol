// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

contract TokenAllowanceUnitTest is TokenBaseUnitTest {

    address owner = makeAddr("Owner");
    address spender = makeAddr("Spender");
    address spender2 = makeAddr("Spender2");

    address identity1 = makeAddr("Identity1");
    address identity2 = makeAddr("Identity2");

    uint256 explicitAllowance = 500;

    function setUp() public override {
        super.setUp();

        vm.prank(agent);
        token.unpause();

        mockIdentityRegistryIdentity(owner, identity1);
        mockIdentityRegistryIdentity(spender, identity2);
    }

    /// @notice Test standard ERC20 allowance path - no default allowance, different identities, explicit approval
    function testAllowanceStandardERC20Path() public {
        // Set explicit allowance
        vm.prank(owner);
        token.approve(spender, explicitAllowance);

        // Should return explicit allowance amount
        assertEq(token.allowance(owner, spender), explicitAllowance);
    }

    /// @notice Test default allowance path - spender has default allowance, owner hasn't opted out
    function testAllowanceDefaultAllowanceEnabled() public {
        // Set default allowance for spender
        setDefaultAllowanceForSpender(true);

        // Should return max allowance
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    /// @notice Test default allowance but owner opted out - should check identity next
    function testAllowanceDefaultAllowanceButOwnerOptedOut() public {
        // Set default allowance for spender
        setDefaultAllowanceForSpender(true);

        // Owner opts out
        vm.prank(owner);
        token.setDefaultAllowance(false);

        // Should return 0 (no explicit approval set)
        assertEq(token.allowance(owner, spender), 0);
    }

    /// @notice Test default allowance but owner opted out, with explicit approval
    function testAllowanceDefaultAllowanceOptedOutWithExplicitApproval() public {
        // Set default allowance for spender
        setDefaultAllowanceForSpender(true);

        // Owner opts out
        vm.prank(owner);
        token.setDefaultAllowance(false);

        // Set explicit allowance
        vm.prank(owner);
        token.approve(spender, explicitAllowance);

        // Should return explicit allowance amount
        assertEq(token.allowance(owner, spender), explicitAllowance);
    }

    /// @notice Test same identity path - owner and spender have same identity
    function testAllowanceSameIdentity() public {
        // Mock same identity for owner and spender
        mockIdentityRegistryIdentity(owner, identity1);
        mockIdentityRegistryIdentity(spender, identity1);

        // Should return max allowance even without explicit approval
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    /// @notice Test default allowance AND same identity - should return max from first check
    function testAllowanceDefaultAllowanceAndSameIdentity() public {
        // Set default allowance for spender
        setDefaultAllowanceForSpender(true);

        // Mock same identity for owner and spender
        mockIdentityRegistryIdentity(owner, identity1);
        mockIdentityRegistryIdentity(spender, identity1);

        // Should return max allowance (from first check, never reaches identity check)
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    /// @notice Test no default allowance, different identities, no explicit approval
    function testAllowanceNoDefaultAllowanceDifferentIdentitiesNoApproval() public {
        // Should return 0 (no default allowance, no explicit approval)
        assertEq(token.allowance(owner, spender), 0);
    }

    /// @notice Test default allowance for one spender but not another
    function testAllowanceDefaultAllowanceForOneSpenderOnly() public {
        // Set default allowance for spender only
        setDefaultAllowanceForSpender(true);

        mockIdentityRegistryIdentity(spender2, identity2);

        // spender should have max allowance
        assertEq(token.allowance(owner, spender), type(uint256).max);

        // spender2 should have 0 allowance (not in default allowance list)
        assertEq(token.allowance(owner, spender2), 0);
    }

    /// @notice Test owner opts out affects all spenders with default allowance
    function testAllowanceOptOutAffectsAllDefaultAllowanceSpenders() public {
        // Set default allowance for multiple spenders
        address[] memory targets = new address[](2);
        targets[0] = spender;
        targets[1] = spender2;
        token.setAllowanceForAll(targets, true);

        mockIdentityRegistryIdentity(spender2, identity2);

        // Both should have max allowance
        assertEq(token.allowance(owner, spender), type(uint256).max);
        assertEq(token.allowance(owner, spender2), type(uint256).max);

        // Owner opts out
        vm.prank(owner);
        token.setDefaultAllowance(false);

        // Both should now have 0 allowance
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.allowance(owner, spender2), 0);
    }

    /// @notice Test same identity with explicit approval - identity check takes precedence
    function testAllowanceSameIdentityWithExplicitApproval() public {
        // Mock same identity for owner and spender
        mockIdentityRegistryIdentity(owner, identity1);
        mockIdentityRegistryIdentity(spender, identity1);

        // Set explicit allowance (should be ignored due to same identity)
        vm.prank(owner);
        token.approve(spender, explicitAllowance);

        // Should return max allowance (identity check overrides explicit approval)
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    /// @notice Test default allowance removed - should fall back to identity check
    function testAllowanceDefaultAllowanceRemoved() public {
        // Set default allowance for spender
        setDefaultAllowanceForSpender(true);

        // Mock same identity
        mockIdentityRegistryIdentity(owner, identity1);
        mockIdentityRegistryIdentity(spender, identity1);

        // Should return max (from default allowance)
        assertEq(token.allowance(owner, spender), type(uint256).max);

        // Remove default allowance
        setDefaultAllowanceForSpender(false);

        // Should still return max (from same identity check)
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    /// @notice Test owner opts back in after opting out
    function testAllowanceOptBackIn() public {
        // Set default allowance for spender
        setDefaultAllowanceForSpender(true);

        // Should have max allowance
        assertEq(token.allowance(owner, spender), type(uint256).max);

        // Owner opts out
        vm.prank(owner);
        token.setDefaultAllowance(false);

        // Should have 0 allowance
        assertEq(token.allowance(owner, spender), 0);

        // Owner opts back in
        vm.prank(owner);
        token.setDefaultAllowance(true);

        // Should have max allowance again
        assertEq(token.allowance(owner, spender), type(uint256).max);
    }

    /// @notice Test when identity returns address(0) for owner
    function testAllowanceOwnerIdentityZero() public {
        // Mock zero identity for owner, valid identity for spender
        mockIdentityRegistryIdentity(owner, address(0));

        // Set explicit allowance
        vm.prank(owner);
        token.approve(spender, explicitAllowance);

        // Should return explicit allowance (identity check compares address(0) != identity2)
        assertEq(token.allowance(owner, spender), explicitAllowance);
    }

    /// @notice Test when identity returns address(0) for both
    function testAllowanceBothIdentitiesZero() public {
        // Mock zero identity for both owner and spender
        mockIdentityRegistryIdentity(owner, address(0));
        mockIdentityRegistryIdentity(spender, address(0));

        // Should return 0 allowance
        assertEq(token.allowance(owner, spender), 0);
    }

    /// ----- Helper Functions -----

    function mockIdentityRegistryIdentity(address user, address identityAddress) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.identity.selector, user),
            abi.encode(identityAddress)
        );
    }

    function setDefaultAllowanceForSpender(bool enabled) internal {
        address[] memory targets = new address[](1);
        targets[0] = spender;
        token.setAllowanceForAll(targets, enabled);
    }

}

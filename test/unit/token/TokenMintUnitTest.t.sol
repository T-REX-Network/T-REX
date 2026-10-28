// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenMintUnitTest is TokenBaseUnitTest {

    uint256 mintAmount = 1000;

    function setUp() public override {
        super.setUp();

        vm.prank(agent);
        token.unpause();
    }

    function testTokenMintRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.mint(user1, mintAmount);
    }

    function testTokenMintRevertsWhenCallerOnlyBurner() public {
        address burner = makeAddr("Burner");
        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.AGENT_BURNER), burner, 0);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, burner));
        vm.prank(burner);
        token.mint(user1, mintAmount);
    }

    function testTokenMintRevertsWhenUserNotVerified() public {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.isVerified.selector, user1),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(agent);
        token.mint(user1, mintAmount);
    }

    function testTokenMintRevertsWhenComplianceNotFollowed() public {
        vm.mockCall(
            compliance,
            abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector, address(0), user1, mintAmount),
            abi.encode(false)
        );

        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        vm.prank(agent);
        token.mint(user1, mintAmount);
    }

    function testTokenMintNominal() public {
        vm.prank(agent);
        token.mint(user1, mintAmount);

        assertEq(token.balanceOf(user1), mintAmount);
        assertEq(token.totalSupply(), mintAmount);
    }

    function testTokenBatchMintRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        address[] memory tos = new address[](1);
        tos[0] = user1;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = mintAmount;

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.batchMint(tos, amounts);
    }

    function testTokenBatchMintNominal() public {
        uint256 amount1 = 500;
        uint256 amount2 = 300;

        address[] memory tos = new address[](2);
        tos[0] = user1;
        tos[1] = user2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        vm.prank(agent);
        token.batchMint(tos, amounts);

        assertEq(token.balanceOf(user1), amount1);
        assertEq(token.balanceOf(user2), amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    /// @notice Mapping a batch to `ADMIN_ROLE` does not restrict it: `ADMIN_ROLE` is role zero, which the manager
    ///         also answers for a selector with no row, so `batchMint` still follows `mint`'s role.
    function testTokenBatchMintStillFollowsMintWhenMappedToAdminRole() public {
        address minter = makeAddr("Minter");
        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.AGENT_MINTER), minter, 0);
        _mapBatchMint(accessManager.ADMIN_ROLE());

        vm.prank(minter);
        token.batchMint(_oneRecipient(), _oneAmount());

        assertEq(token.balanceOf(user1), mintAmount);
    }

    /// @notice A batch is restricted through a nonzero role: once `batchMint` has one, a holder of `mint`'s role
    ///         alone is refused, and a holder of the batch's role is let through.
    function testTokenBatchMintRestrictedWhenMappedToNonzeroRole() public {
        address minter = makeAddr("Minter");
        address batchMinter = makeAddr("BatchMinter");
        uint64 batchRole = RolesLib.forDomain(1, RolesLib.Role.OWNER);
        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.AGENT_MINTER), minter, 0);
        accessManager.grantRole(batchRole, batchMinter, 0);
        _mapBatchMint(batchRole);

        address[] memory recipients = _oneRecipient();
        uint256[] memory amounts = _oneAmount();
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, minter));
        vm.prank(minter);
        token.batchMint(recipients, amounts);

        vm.prank(batchMinter);
        token.batchMint(recipients, amounts);

        assertEq(token.balanceOf(user1), mintAmount);
    }

    function _mapBatchMint(uint64 roleId) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = token.batchMint.selector;
        accessManager.setTargetFunctionRole(address(token), selectors, roleId);
    }

    function _oneRecipient() internal view returns (address[] memory recipients) {
        recipients = new address[](1);
        recipients[0] = user1;
    }

    function _oneAmount() internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = mintAmount;
    }

}

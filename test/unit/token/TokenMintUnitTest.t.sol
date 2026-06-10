// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

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

        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        vm.prank(caller);
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

    function testTokenMintRevertsWhenDisableMintRestrictionIsSet() public {
        // Set restriction to disable mint
        TokenRoles memory restrictions = TokenRoles({
            disableMint: true,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: false,
            disableForceTransfer: false,
            disablePause: false
        });

        token.setAgentRestrictions(agent, restrictions);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "mint disabled"));
        vm.prank(agent);
        token.mint(user1, mintAmount);
    }

}


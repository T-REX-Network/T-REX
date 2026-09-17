// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";

import { Countries } from "test/integration/helpers/Countries.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TokenIdentityTransferTest is TREXSuiteTest {

    TREXRegistry public identityRegistry;

    /// @dev A second wallet of Alice's, so the same identity commands two wallets.
    address public aliceSecondWallet = makeAddr("aliceSecondWallet");

    function setUp() public override {
        super.setUp();

        identityRegistry = TREXRegistry(address(token.identityRegistry()));

        vm.startPrank(agent);
        identityRegistry.registerIdentity(aliceSecondWallet, aliceIdentity, Countries.FRANCE);
        token.mint(alice, 1000);
        token.unpause();
        vm.stopPrank();
    }

    /* ----- The identity commands its own wallets ----- */

    function test_identityTransfer_Success_BetweenOwnWallets() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.IdentityTransfer(address(aliceIdentity), alice, aliceSecondWallet, 400);
        vm.prank(address(aliceIdentity));
        bool success = token.identityTransfer(alice, aliceSecondWallet, 400);

        assertTrue(success);
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(aliceSecondWallet), 400);
    }

    function test_identityTransfer_Success_ToAnotherInvestor() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.IdentityTransfer(address(aliceIdentity), alice, bob, 250);
        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, bob, 250);

        assertEq(token.balanceOf(alice), 750);
        assertEq(token.balanceOf(bob), 250);
    }

    /* ----- Authorization ----- */

    function test_identityTransfer_RevertWhen_CallerIsAnotherIdentity() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, alice, address(bobIdentity)));
        vm.prank(address(bobIdentity));
        token.identityTransfer(alice, bob, 100);
    }

    /// @dev Alice's own wallet is not her identity. Only the identity contract is the authorized caller.
    function test_identityTransfer_RevertWhen_CallerIsTheWalletItself() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, alice, alice));
        vm.prank(alice);
        token.identityTransfer(alice, bob, 100);
    }

    function test_identityTransfer_RevertWhen_SourceIsNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, david, address(aliceIdentity)));
        vm.prank(address(aliceIdentity));
        token.identityTransfer(david, bob, 100);
    }

    /// @dev Dropping the local binding does not end the identity's command: {storedIdentity} falls back to the
    ///      ONCHAINID factory, which still resolves the wallet. The identity's authority comes from the wallet
    ///      link in ONCHAINID, not from the token's local registration, so only a revocation there severs it.
    function test_identityTransfer_Success_WhenOnlyTheLocalBindingWasRemoved() public {
        vm.prank(agent);
        identityRegistry.deleteIdentity(alice);

        assertFalse(identityRegistry.isLocallyRegistered(alice));
        assertEq(address(identityRegistry.identity(alice)), address(aliceIdentity));

        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    /// @dev Revoking in ONCHAINID does not stop this path, and is not meant to: the local registration keeps
    ///      resolving the wallet, and the same wallet can still {transfer} out on its own. Revoked wallets are a
    ///      token-wide policy question; pinned here so a future revocation gate is a deliberate change.
    function test_identityTransfer_Success_WhenSourceWalletIsRevokedInOnchainId() public {
        bytes memory account = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(address(aliceIdentity));
        idFactory.revokeAccount(account);

        assertEq(address(identityRegistry.identity(alice)), address(aliceIdentity));

        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, bob, 100);

        assertEq(token.balanceOf(bob), 100);
    }

    function test_identityTransfer_RevertWhen_DestinationIsNotRegistered() public {
        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, david, 100);
    }

    /* ----- ERC-20 stays untouched ----- */

    function test_identityTransfer_LeavesAllowanceAtZero() public {
        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, bob, 100);

        assertEq(token.allowance(alice, address(aliceIdentity)), 0);
    }

    function test_transferFrom_RevertWhen_IdentityHasNoApproval() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(aliceIdentity), 0, 100)
        );
        vm.prank(address(aliceIdentity));
        token.transferFrom(alice, bob, 100);
    }

    /// @dev An explicit approval still behaves exactly as ERC-20 says, untouched by the identity path.
    function test_approve_StillGovernsTransferFrom() public {
        vm.prank(alice);
        token.approve(address(aliceIdentity), 100);
        assertEq(token.allowance(alice, address(aliceIdentity)), 100);

        vm.prank(address(aliceIdentity));
        token.transferFrom(alice, bob, 100);

        assertEq(token.allowance(alice, address(aliceIdentity)), 0);
        assertEq(token.balanceOf(bob), 100);
    }

    /* ----- Full _update path ----- */

    function test_identityTransfer_RevertWhen_FrozenTokensWouldMove() public {
        vm.prank(agent);
        token.freezePartialTokens(alice, 800);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 200, 300));
        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, bob, 300);
    }

    function test_identityTransfer_RevertWhen_Paused() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(aliceIdentity));
        token.identityTransfer(alice, bob, 100);
    }

}

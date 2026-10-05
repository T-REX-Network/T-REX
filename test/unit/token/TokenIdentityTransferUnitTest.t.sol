// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenIdentityTransferUnitTest is TokenBaseUnitTest {

    address from = makeAddr("From");
    address to = makeAddr("To");
    address identity = makeAddr("Identity");
    address keyHolder = makeAddr("KeyHolder");

    uint256 mintAmount = 1000;
    uint256 transferAmount = 500;

    function setUp() public override {
        super.setUp();

        // `from` resolves to `identity`; every other wallet resolves to nothing unless a test says otherwise.
        _mockIdentityOf(from, identity);

        vm.startPrank(agent);
        token.unpause();
        token.mint(from, mintAmount);
        vm.stopPrank();
    }

    /// @dev The registry resolves one wallet to one identity. Mocked per wallet so a test can make a wallet
    ///      unresolvable by simply not mocking it.
    function _mockIdentityOf(address wallet, address resolved) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeCall(IERC3643IdentityRegistry.identity, (wallet)),
            abi.encode(IIdentity(resolved))
        );
    }

    function _mockVerified(address wallet, bool verified) internal {
        vm.mockCall(
            identityRegistry, abi.encodeCall(IERC3643IdentityRegistry.isVerified, (wallet)), abi.encode(verified)
        );
    }

    /* ----- Authorization ----- */

    function testTokenIdentityTransferNominal() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.IdentityTransfer(identity, from, to, transferAmount);
        vm.prank(identity);
        bool success = token.identityTransfer(from, to, transferAmount);

        assertTrue(success);
        assertEq(token.balanceOf(from), mintAmount - transferAmount);
        assertEq(token.balanceOf(to), transferAmount);
    }

    function testTokenIdentityTransferEmitsStandardTransfer() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(from, to, transferAmount);
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    function testTokenIdentityTransferRevertsWhenCallerIsNotTheResolvedIdentity(address caller) public {
        vm.assume(caller != identity);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, from, caller));
        vm.prank(caller);
        token.identityTransfer(from, to, transferAmount);
    }

    /// @dev A key holder is authenticated by the account, not by the token. Calling the token directly is just
    ///      another unauthorized caller.
    function testTokenIdentityTransferRevertsWhenKeyHolderCallsDirectly() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, from, keyHolder));
        vm.prank(keyHolder);
        token.identityTransfer(from, to, transferAmount);
    }

    function testTokenIdentityTransferRevertsWhenSourceResolvesToNoIdentity() public {
        address unlinked = makeAddr("Unlinked");
        _mockIdentityOf(unlinked, address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, unlinked, identity));
        vm.prank(identity);
        token.identityTransfer(unlinked, to, transferAmount);
    }

    /// @dev The zero identity must never authorize itself when a wallet resolves to nothing.
    function testTokenIdentityTransferRevertsWhenZeroIdentityCallsForUnlinkedWallet() public {
        address unlinked = makeAddr("Unlinked");
        _mockIdentityOf(unlinked, address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotLinkedIdentity.selector, unlinked, address(0)));
        vm.prank(address(0));
        token.identityTransfer(unlinked, to, transferAmount);
    }

    /// @dev The sender's own claims are not this function's gate: `_update` checks the destination, matching
    ///      {transfer}, which never checks the sender either.
    function testTokenIdentityTransferAllowsSourceWithoutValidClaims() public {
        _mockVerified(from, false);

        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);

        assertEq(token.balanceOf(to), transferAmount);
    }

    function testTokenIdentityTransferRevertsWhenDestinationIsNotVerified() public {
        _mockVerified(to, false);

        vm.expectRevert(ErrorsLib.UnverifiedIdentity.selector);
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    /* ----- ERC-20 stays untouched ----- */

    function testTokenIdentityTransferWritesNoAllowance() public {
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);

        assertEq(token.allowance(from, identity), 0);
    }

    function testTokenIdentityTransferDoesNotGrantTransferFrom() public {
        assertEq(token.allowance(from, identity), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, identity, 0, transferAmount)
        );
        vm.prank(identity);
        token.transferFrom(from, to, transferAmount);
    }

    function testTokenIdentityTransferEmitsNoApproval() public {
        vm.recordLogs();
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);

        bytes32 approvalTopic = IERC20.Approval.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != approvalTopic);
        }
    }

    /* ----- Full _update path ----- */

    function testTokenIdentityTransferRevertsWhenPaused() public {
        vm.prank(agent);
        token.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    function testTokenIdentityTransferRevertsWhenSourceWalletIsFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(from, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, from));
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    function testTokenIdentityTransferRevertsWhenDestinationWalletIsFrozen() public {
        vm.prank(agent);
        token.setAddressFrozen(to, true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FrozenWallet.selector, to));
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    /// @dev Frozen tokens stay immovable: a self-service move must not defeat an agent's freeze.
    function testTokenIdentityTransferCannotMoveFrozenTokens() public {
        uint256 frozenAmount = 800;
        vm.prank(agent);
        token.freezePartialTokens(from, frozenAmount);

        uint256 freeBalance = mintAmount - frozenAmount;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, freeBalance, transferAmount)
        );
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    function testTokenIdentityTransferMovesFreeBalanceOfAPartlyFrozenWallet() public {
        uint256 frozenAmount = 800;
        vm.prank(agent);
        token.freezePartialTokens(from, frozenAmount);

        uint256 freeBalance = mintAmount - frozenAmount;
        vm.prank(identity);
        token.identityTransfer(from, to, freeBalance);

        assertEq(token.balanceOf(to), freeBalance);
        assertEq(token.balanceOf(from), frozenAmount);
    }

    function testTokenIdentityTransferRevertsWhenComplianceRefuses() public {
        vm.mockCall(compliance, abi.encodeWithSelector(IERC3643Compliance.canTransfer.selector), abi.encode(false));

        vm.expectRevert(ErrorsLib.ComplianceNotFollowed.selector);
        vm.prank(identity);
        token.identityTransfer(from, to, transferAmount);
    }

    function testTokenIdentityTransferRevertsWhenAmountExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, mintAmount, mintAmount + 1)
        );
        vm.prank(identity);
        token.identityTransfer(from, to, mintAmount + 1);
    }

}

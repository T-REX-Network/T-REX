// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { SecondHalvesSuiteTest } from "test/integration/helpers/SecondHalvesSuiteTest.sol";

/// @dev A home wallet asks with `askToMove` like any wallet: its tokens burn at home onto hold and its move out leaves
///      in the ask, and every ask counts in its identity's limits.
contract HomeWalletAsksTest is SecondHalvesSuiteTest {

    uint256 internal constant MOVED = 100;

    /// @notice One ask per window for Alice's identity: her home wallet's move out uses it, so her next ask, from
    ///         home or away, is refused until the window turns.
    function test_askToMove_countsAHomeWalletsAskInItsIdentitysLimit() public {
        uint32 oneAskPerWindow = 1;
        vm.prank(deployer);
        boundCompliance.setAskLimitOf(address(aliceIdentity), oneAskPerWindow);

        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceOnB, MOVED, MOVED, "", _salt());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceHome, aliceOnB, MOVED, MOVED, "", _salt());
        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AskLimitReached.selector, address(aliceIdentity)));
        boundCompliance.askToMove(aliceOnA, bobOnA, MOVED, MOVED, "", _salt());

        vm.warp(block.timestamp + _askLimits().askWindow);
        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceOnB, MOVED, MOVED, "", _salt());
    }

    /// @notice A home wallet's ask sent to a receiver on another identity is a forward move: kept against Bob while
    ///         its move out is out, Bob owns it at Done.
    function test_askToMove_movesOutToAnotherIdentitysAwayWallet_andTheReceiptEndsIt() public {
        vm.prank(alice);
        bytes32 id = boundCompliance.askToMove(aliceHome, bobOnB, MOVED, MOVED, "", _salt());
        assertEq(ledger.pendingInOf(address(bobIdentity)), MOVED, "kept for Bob");

        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnB), MOVED);
        assertEq(ledger.positionOf(address(bobIdentity)), MOVED);
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0);
        _assertTotalOwned();
    }

    function test_askToMove_reverts_when_aStrangerAsksForAHomeWalletEvenToItsOwnAwayWallet() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, charlie, aliceHome));
        boundCompliance.askToMove(aliceHome, aliceOnB, MOVED, MOVED, "", _salt());

        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A, "nothing burned");
    }

}

/// @dev With an approval module bound, a home wallet's ask waits like any ask: nothing burns until the approver
///      answered and the ticket is sent. A ticket waiting for approval reserves the away wallet, so a bring home asked
///      meanwhile never counts on those tokens.
contract HomeWalletAsksWithApprovalTest is SecondHalvesSuiteTest {

    uint256 internal constant MOVED = 100;

    AsyncApprovalModule internal module;
    address internal approver = makeAddr("approver");

    function setUp() public override {
        super.setUp();
        module = AsyncApprovalModule(
            address(
                new ModuleProxy(
                    address(new AsyncApprovalModule()),
                    abi.encodeCall(AsyncApprovalModule.initialize, (address(suiteManager)))
                )
            )
        );
        address[] memory approvers = new address[](1);
        approvers[0] = approver;
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AsyncApprovalModule.setApprovers, (approvers));
        // An approval module is bound only while asks are paused.
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(true);
        boundCompliance.addAndSetModule(address(module), settings);
        boundCompliance.setAsksPaused(false);
        vm.stopPrank();
    }

    function test_askToMove_waitsForTheApprover_thenBurnsAndSendsTheMoveOut_whenTheSenderIsAHomeWallet() public {
        vm.prank(alice);
        bytes32 id = boundCompliance.askToMove(aliceHome, bobOnB, MOVED, MOVED, "", _salt());

        _assertStatus(id, ITickets.TicketStatus.WaitingForApproval);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A, "nothing burned while it waits");
        assertEq(optimismGateway.queueLength(), 0, "nothing sent");

        _approve(id, MOVED);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, address(0), MOVED);
        boundCompliance.sendTicket(id, bobOnB, "");

        _assertStatus(id, ITickets.TicketStatus.OnHold);
        assertEq(token.onHoldOf(id), MOVED);
        assertEq(_queuedMoveOut(optimismGateway, _lastIndex(optimismGateway)).amount, MOVED);
        _deliver(optimismGateway, _minted(id, 1, bobOnB, MOVED));
        _assertStatus(id, ITickets.TicketStatus.Done);
        _assertTotalOwned();
    }

    /// @notice A home wallet reserves nothing on the token while its ask waits: if the holder spent the tokens
    ///         meanwhile, the send after the answer finds them no longer free and reverts.
    function test_sendTicket_reverts_when_theHomeHolderSpentItsTokensWhileTheAskWaited() public {
        uint256 atHome = MINTED - ALICE_ON_A;
        uint256 spent = atHome - MOVED + 1;
        vm.prank(alice);
        bytes32 id = boundCompliance.askToMove(aliceHome, bobOnB, MOVED, MOVED, "", _salt());
        vm.prank(approver);
        module.approveTransfer(
            address(boundCompliance), keccak256("spend"), alice, charlie, spent, uint64(block.timestamp + 1 days)
        );
        vm.prank(alice);
        token.transfer(charlie, spent);
        _approve(id, MOVED);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceHome, atHome - spent, MOVED)
        );
        boundCompliance.sendTicket(id, bobOnB, "");

        _assertStatus(id, ITickets.TicketStatus.Open);
    }

    /// @notice Tokens frozen while the ask waited are not free: the send after the answer checks the free balance
    ///         again, as the ask did, and burns nothing.
    function test_sendTicket_reverts_when_theHomeTokensWereFrozenAfterTheAsk() public {
        uint256 atHome = MINTED - ALICE_ON_A;
        uint256 frozenAfterTheAsk = atHome - MOVED + 1;
        uint256 freeAtTheSend = atHome - frozenAfterTheAsk;
        vm.prank(alice);
        bytes32 id = boundCompliance.askToMove(aliceHome, bobOnB, MOVED, MOVED, "", _salt());
        vm.prank(agent);
        token.freezePartialTokens(alice, frozenAfterTheAsk);
        _approve(id, MOVED);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceHome, freeAtTheSend, MOVED));
        boundCompliance.sendTicket(id, bobOnB, "");

        _assertStatus(id, ITickets.TicketStatus.Open);
        assertEq(token.balanceOf(alice), atHome, "nothing burned");
        assertEq(token.getFrozenTokens(alice), frozenAfterTheAsk, "the frozen tokens stay at home");
    }

    /// @notice A ticket waiting for approval reserves its maximum on the away wallet. A bring home asked meanwhile
    ///         is bounded by what is free, so it is refused for even one token; once approved, the ticket executes
    ///         the whole amount and no bring home ever burns those tokens.
    function test_bringHome_reverts_when_aTicketWaitingForApprovalReservedTheTokens() public {
        bytes32 id = _requestValidation(address(aliceIdentity), aliceOnA, bobOnA, ALICE_ON_A, ALICE_ON_A);
        _assertStatus(id, ITickets.TicketStatus.WaitingForApproval);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, aliceOnA, 0, 1));
        boundCompliance.bringHome(aliceOnA, 1, alice, _salt());

        _approve(id, ALICE_ON_A);
        boundCompliance.sendTicket(id, bobOnA, "");
        _aSendsTheTicketsReceipt(id, bobOnA, ALICE_ON_A);

        _assertStatus(id, ITickets.TicketStatus.Done);
        assertEq(token.awayBalanceOf(bobOnA), ALICE_ON_A, "the ticket moved everything");
        assertEq(token.awayBalanceOf(aliceOnA), 0);
        assertEq(token.balanceOf(alice), MINTED - ALICE_ON_A, "no bring home burned any of it");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
    }

    function _approve(bytes32 id, uint256 amountMax) private {
        vm.prank(approver);
        module.approveValidation(address(boundCompliance), id, amountMax);
        module.finalize(address(boundCompliance), id);
    }

}

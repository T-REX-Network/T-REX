// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @dev Money on hold may grow only by `putOnHold`, when the take of an earlier hold hands its carried part to the
///      later one. A home wallet that moves out holds once per ticket: `burnOntoHold` still refuses a ticket that
///      already holds something.
contract TokenHoldFromHomeOnceUnitTest is TokenLedgerBaseUnitTest {

    bytes32 internal constant TICKET_ID = bytes32(uint256(11));
    uint256 internal constant MINTED = 100;
    uint256 internal constant MOVED_OUT = 30;

    bytes internal user1AtHome;

    function setUp() public override {
        super.setUp();
        user1AtHome = satelliteEnvelope(block.chainid, user1);
        vm.startPrank(agent);
        token.mint(user1, MINTED);
        ledger.ledgerMoveOut(user1, satellite1, MOVED_OUT);
        vm.stopPrank();
    }

    function test_burnOntoHold_RevertWhen_TheTicketAlreadyHoldsAHomeBurn() public {
        uint256 firstBurn = 10;
        uint256 secondBurn = 5;
        vm.startPrank(compliance);
        token.burnOntoHold(user1AtHome, firstBurn, TICKET_ID);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAlreadyHeld.selector, TICKET_ID));
        token.burnOntoHold(user1AtHome, secondBurn, TICKET_ID);
        vm.stopPrank();

        assertEq(token.onHoldOf(TICKET_ID), firstBurn, "held once");
        assertEq(token.balanceOf(user1), MINTED - MOVED_OUT - firstBurn, "burned once");
        _assertPartition();
    }

    function test_burnOntoHold_RevertWhen_TheTicketAlreadyHoldsAnAwayWalletsTokens() public {
        uint256 heldFromTheAwayWallet = 10;
        uint256 homeBurn = 5;
        vm.startPrank(compliance);
        token.putOnHold(satellite1, heldFromTheAwayWallet, TICKET_ID);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAlreadyHeld.selector, TICKET_ID));
        token.burnOntoHold(user1AtHome, homeBurn, TICKET_ID);
        vm.stopPrank();

        assertEq(token.onHoldOf(TICKET_ID), heldFromTheAwayWallet, "the hold did not grow");
        assertEq(token.balanceOf(user1), MINTED - MOVED_OUT, "nothing burned at home");
        _assertPartition();
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { RecordingModule, TrackerOnlyModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Two open away chains, polygon (A) and optimism (B), and the receipts their away tokens send home for the
///      halves of a move: the vocabulary the second-half and bring-home suites share. Alice holds 500 on A; Bob has a
///      wallet on A and on B. Receipts are built as the away token builds them and sent by the token's own peer.
abstract contract SecondHalvesSuiteTest is InteropSuiteTest {

    uint256 internal constant MINTED = 1000;
    uint256 internal constant ALICE_ON_A = 500;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    IComplianceLedger internal ledger;

    bytes internal aliceHome;
    bytes internal bobHome;
    bytes internal aliceOnA;
    bytes internal aliceOnB;
    bytes internal bobOnA;
    bytes internal bobOnB;

    function setUp() public virtual override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));
        ledger = IComplianceLedger(address(boundCompliance));

        aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        bobHome = InteroperableAddress.formatEvmV1(block.chainid, bob);
        aliceOnA = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_ON_A);
        aliceOnB = _linkSatelliteWallet(aliceIdentity, OPTIMISM, makeAccount("aliceOnOptimism"));
        bobOnA = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOnB = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        vm.startPrank(agent);
        token.mint(alice, MINTED - ALICE_ON_A);
        token.unpause();
        vm.stopPrank();
    }

    /* ----- Asks ----- */

    /// @dev Alice asks to move exactly `amount` from her wallet on A to Bob's wallet on B.
    function _askAToB(uint256 amount) internal returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceOnA, bobOnB, amount, amount);
    }

    /// @dev Alice asks for `amount` from A to Bob on B, and A's receipt lands: the money goes on hold and half 1
    ///  leaves for B.
    function _firstHalfLanded(uint256 amount) internal returns (bytes32 ticketId) {
        ticketId = _askAToB(amount);
        _aSendsTheTicketsReceipt(ticketId, bobOnB, amount);
    }

    /// @dev A's away token reports that it executed the ticket for `amount` toward `to`.
    function _aSendsTheTicketsReceipt(bytes32 ticketId, bytes memory to, uint256 amount) internal {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(ticketId, aliceOnA, to, amount)));
    }

    /* ----- Second-half receipts ----- */

    /// @dev A move out's receipt as the away token builds it: names the minted wallet only.
    function _moveOutReceipt(
        bytes32 ticketId,
        uint8 half,
        bytes memory toWallet,
        uint256 amount,
        MessageTypesLib.ReceiptAnswer answer
    ) internal pure returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: "",
            to: toWallet,
            amount: amount,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: half,
            answer: answer
        });
    }

    /// @dev The receipt of a move out that minted `amount` to `toWallet`.
    function _minted(bytes32 ticketId, uint8 half, bytes memory toWallet, uint256 amount)
        internal
        pure
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _moveOutReceipt(ticketId, half, toWallet, amount, MessageTypesLib.ReceiptAnswer.Executed);
    }

    /// @dev The zero answer of a move out that arrived at or after its valid until and was never executed.
    function _expired(bytes32 ticketId, uint8 half, bytes memory toWallet)
        internal
        pure
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _moveOutReceipt(ticketId, half, toWallet, 0, MessageTypesLib.ReceiptAnswer.Expired);
    }

    /// @dev A bring home's receipt as the away token builds it: names the burned wallet only.
    function _bringHomeReceipt(
        bytes32 ticketId,
        uint8 half,
        bytes memory burnedWallet,
        uint256 burned,
        MessageTypesLib.ReceiptAnswer answer
    ) internal pure returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: burnedWallet,
            to: "",
            amount: burned,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: half,
            answer: answer
        });
    }

    /// @dev Queues `receipt` on `gateway` from the token's own peer there and delivers it.
    function _deliver(ERC7786GatewayMock gateway, MessageTypesLib.ReceiptMessage memory receipt) internal {
        gateway.relay(_liteSettles(gateway, token, receipt));
    }

    /* ----- Reads ----- */

    function _status(bytes32 ticketId) internal view returns (ITickets.TicketStatus) {
        return boundCompliance.statusOf(ticketId);
    }

    function _assertStatus(bytes32 ticketId, ITickets.TicketStatus expected) internal view {
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(expected), "ticket status");
    }

    /// @dev The decoded `MOVE_OUT` queued at `index` of `gateway`.
    function _queuedMoveOut(ERC7786GatewayMock gateway, uint256 index)
        internal
        view
        returns (MessageTypesLib.MoveOutMessage memory)
    {
        (MessageTypesLib.Message messageType, bytes memory body) =
            MessageTypesLib.decode(gateway.queuedMessage(index).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.MOVE_OUT), "a move out");
        return MessageTypesLib.decodeMintInstruction(body);
    }

    /// @dev The decoded `BRING_HOME` queued at `index` of `gateway`.
    function _queuedBringHome(ERC7786GatewayMock gateway, uint256 index)
        internal
        view
        returns (MessageTypesLib.BringHomeMessage memory)
    {
        (MessageTypesLib.Message messageType, bytes memory body) =
            MessageTypesLib.decode(gateway.queuedMessage(index).payload);
        assertEq(uint8(messageType), uint8(MessageTypesLib.Message.BRING_HOME), "a bring home");
        return MessageTypesLib.decodeBringHome(body);
    }

    function _lastIndex(ERC7786GatewayMock gateway) internal view returns (uint256) {
        return gateway.queueLength() - 1;
    }

    /// @dev Every token is at home, away or on hold, and the supply never moves.
    function _assertTotalOwned() internal view {
        uint256 away = token.awayBalanceOf(aliceOnA) + token.awayBalanceOf(aliceOnB) + token.awayBalanceOf(bobOnA)
            + token.awayBalanceOf(bobOnB);
        uint256 atHome = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(charlie);
        assertEq(atHome + away + token.totalOnHold(), MINTED, "home + away + on hold is the supply");
        assertEq(token.totalSupply(), MINTED, "the supply never moves");
        assertEq(token.totalAwayBalance(), away + token.totalOnHold(), "the away total counts what is on hold");
    }

    /* ----- Modules, bound before any ticket is open ----- */

    function _bindTracker() internal returns (TrackerOnlyModule tracker) {
        tracker = TrackerOnlyModule(
            address(new ModuleProxy(address(new TrackerOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(tracker));
    }

    function _bindMaxBalance(uint256 cap) internal returns (MaxBalancePerIdentityModule rule) {
        rule = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(new MaxBalancePerIdentityModule()),
                    abi.encodeCall(MaxBalancePerIdentityModule.initialize, (address(suiteManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (cap));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(rule), settings);
    }

    function _ids(bytes32 ticketId) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = ticketId;
    }

}

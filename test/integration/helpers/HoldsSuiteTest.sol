// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { RecordingModule, RuleAndTrackerModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @dev Money on hold with no ticket and close by hand, run against two away tokens: the polygon one holds Alice,
///      Bob and Charlie's wallets, the optimism one a second wallet of Bob's. Alice's polygon wallet is funded by a
///      real move out from home, so the away token and home agree on it before a test starts.
///
///      A home reorg that drops an ask is replayed as in `ReorgRecovery.t.sol`: the copy the dropped block sent is
///      delivered to the away token, authored by the token, and nothing is recorded at home.
abstract contract HoldsSuiteTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 10;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    SatelliteLiteMock internal polygonLite;
    SatelliteLiteMock internal optimismLite;

    /// @dev A rule that allows everything until a test says otherwise, and a tracker that counts every move.
    RuleAndTrackerModule internal rules;

    Account internal aliceOnPolygon;
    Account internal bobOnPolygon;
    Account internal charlieOnPolygon;
    Account internal bobOnOptimism;

    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal charlieSat;
    bytes internal bobOptimismSat;
    bytes internal aliceHome;
    bytes internal bobHome;

    function setUp() public virtual override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);

        // The away tokens are the token's peers before the routes open: a peer set on an open route is a change.
        polygonLite = new SatelliteLiteMock(POLYGON, address(token), polygonGateway);
        optimismLite = new SatelliteLiteMock(OPTIMISM, address(token), optimismGateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(polygonLite)));
        token.setPeer(optimism, InteroperableAddress.formatEvmV1(OPTIMISM, address(optimismLite)));
        vm.stopPrank();
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceOnPolygon = makeAccount("aliceOnPolygon");
        bobOnPolygon = makeAccount("bobOnPolygon");
        charlieOnPolygon = makeAccount("charlieOnPolygon");
        bobOnOptimism = makeAccount("bobOnOptimism");
        aliceSat = _linkSatelliteWallet(aliceIdentity, POLYGON, aliceOnPolygon);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, bobOnPolygon);
        charlieSat = _linkSatelliteWallet(charlieIdentity, POLYGON, charlieOnPolygon);
        bobOptimismSat = _linkSatelliteWallet(bobIdentity, OPTIMISM, bobOnOptimism);
        aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        bobHome = InteroperableAddress.formatEvmV1(block.chainid, bob);

        // Modules change only while nothing is reserved, so the rule is bound first.
        rules = RuleAndTrackerModule(
            address(
                new ModuleProxy(address(new RuleAndTrackerModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(rules));

        vm.startPrank(agent);
        token.mint(alice, ALICE_AWAY_BALANCE);
        token.unpause();
        vm.stopPrank();

        vm.prank(alice);
        boundCompliance.askToMove(aliceHome, aliceSat, ALICE_AWAY_BALANCE, ALICE_AWAY_BALANCE, "", _salt());
        _relayAll(polygonGateway);
    }

    /* ----- A home reorg that drops an ask ----- */

    /// @dev The ask `from` to `to` for `amount` a home reorg dropped after the away token executed it: the copy the
    ///  dropped block sent is held by the polygon away token, `sender` executes it, and its receipt waits at the
    ///  bridge, undelivered. Nothing is recorded at home. The chain then moves on one block.
    /// @return ticketId the id the same ask mined again takes
    /// @return salt the salt of the dropped ask
    /// @return receiptIndex the receipt's place in the polygon bridge's queue
    function _droppedAsk(Account memory sender, bytes memory from, bytes memory to, uint256 amount)
        internal
        returns (bytes32 ticketId, bytes32 salt, uint256 receiptIndex)
    {
        salt = _salt();
        MessageTypesLib.TicketMessage memory droppedCopy = _droppedCopy(from, to, amount, salt);
        ticketId = droppedCopy.ticketId;
        _deliverToTheAwayToken(polygonGateway, polygonLite, droppedCopy);

        vm.prank(sender.addr);
        polygonLite.execute(ticketId, amount);
        receiptIndex = polygonGateway.queueLength() - 1;

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    /// @dev The salts of the last two related dropped asks, so a test can mine them again.
    bytes32 internal _lastAliceSalt;
    bytes32 internal _lastBobSalt;

    /// @dev Alice to Bob 2, then Bob to Charlie 2, both dropped by one reorg after the away token executed them, both
    ///  receipts booked: Bob spent tokens that are only his uncounted credit, so his hold carries Alice's.
    function _bookTwoRelatedDroppedAsks() internal returns (bytes32 aliceId, bytes32 bobId) {
        uint256 amount = 2;
        uint256 aliceReceipt;
        uint256 bobReceipt;
        (aliceId, _lastAliceSalt, aliceReceipt) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, amount);
        (bobId, _lastBobSalt, bobReceipt) = _droppedAsk(bobOnPolygon, bobSat, charlieSat, amount);
        polygonGateway.relay(aliceReceipt);
        polygonGateway.relay(bobReceipt);
    }

    /// @dev Alice to Bob 2 dropped and booked; Bob spends `spent` of it on Charlie in a dropped ask whose receipt is
    ///  lost on the way: only the away token sending it again can deliver it.
    /// @return aliceId the money on hold under Alice
    /// @return bobsReceiptIndex Bob's lost receipt in the polygon bridge's queue
    function _bookAliceAndLetBobSpend(uint256 spent) internal returns (bytes32 aliceId, uint256 bobsReceiptIndex) {
        uint256 amount = 2;
        uint256 aliceReceipt;
        (aliceId, _lastAliceSalt, aliceReceipt) = _droppedAsk(aliceOnPolygon, aliceSat, bobSat, amount);
        (, _lastBobSalt, bobsReceiptIndex) = _droppedAsk(bobOnPolygon, bobSat, charlieSat, spent);
        polygonGateway.relay(aliceReceipt);
        polygonGateway.drop(bobsReceiptIndex);
    }

    /// @dev The copy of the ask `from` to `to` a home block sent before a reorg dropped it: the asked range is not
    ///  narrowed, and it is valid for the receipt route's window from now.
    function _droppedCopy(bytes memory from, bytes memory to, uint256 amount, bytes32 salt)
        internal
        view
        returns (MessageTypesLib.TicketMessage memory)
    {
        uint64 validUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        return MessageTypesLib.TicketMessage({
            ticketId: _ticketId(from, to, "", amount, amount, salt),
            salt: salt,
            from: from,
            to: to,
            spender: "",
            amountMin: amount,
            amountMax: amount,
            requestedMax: amount,
            token: address(token),
            validUntil: validUntil,
            askBlockHash: TicketLib.askBlockHashOf(amount, validUntil)
        });
    }

    /// @dev Delivers `copy` to `awayToken` through `gateway`, authored by the token as the gateway attributes it.
    function _deliverToTheAwayToken(
        ERC7786GatewayMock gateway,
        SatelliteLiteMock awayToken,
        MessageTypesLib.TicketMessage memory copy
    ) internal {
        bytes memory recipient = InteroperableAddress.formatEvmV1(gateway.originChainId(), address(awayToken));
        vm.prank(address(token));
        gateway.sendMessage(recipient, MessageTypesLib.encodeValidation(copy), new bytes[](0));
        gateway.relay(gateway.queueLength() - 1);
    }

    /// @dev The same ask mined again, by Alice's identity, with the terms and salt of the dropped one.
    function _askAgain(bytes memory from, bytes memory to, uint256 amount, bytes32 salt) internal returns (bytes32) {
        vm.prank(address(aliceIdentity));
        return boundCompliance.askToMove(from, to, amount, amount, "", salt);
    }

    /// @dev The same ask mined again by `identity`, for a dropped ask of one of its wallets.
    function _askAgainAs(address identity, bytes memory from, bytes memory to, uint256 amount, bytes32 salt)
        internal
        returns (bytes32)
    {
        vm.prank(identity);
        return boundCompliance.askToMove(from, to, amount, amount, "", salt);
    }

    /* ----- The bridges ----- */

    /// @dev Delivers every queued entry of `gateway` not yet delivered or dropped, in order, including the ones a
    ///  delivery queues behind it.
    function _relayAll(ERC7786GatewayMock gateway) internal {
        for (uint256 i = 0; i < gateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) gateway.relay(i);
        }
    }

    /// @dev Delivers the first queued entry of `gateway` not yet delivered or dropped.
    /// @return index its place in the queue
    function _relayNext(ERC7786GatewayMock gateway) internal returns (uint256 index) {
        index = _nextUndelivered(gateway);
        gateway.relay(index);
    }

    /// @dev The first queued entry of `gateway` not yet delivered or dropped.
    function _nextUndelivered(ERC7786GatewayMock gateway) internal view returns (uint256) {
        for (uint256 i = 0; i < gateway.queueLength(); i++) {
            ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(i);
            if (message.deliveries == 0 && !message.dropped) return i;
        }
        revert("nothing left to relay");
    }

    /// @dev Queues `receipt` on `gateway`, authored by `awayToken`: what a hostile or broken away token sends.
    function _awayTokenSends(
        ERC7786GatewayMock gateway,
        SatelliteLiteMock awayToken,
        MessageTypesLib.ReceiptMessage memory receipt
    ) internal returns (uint256) {
        return _queue(gateway, address(awayToken), token, MessageTypesLib.encodeSettlement(receipt));
    }

    /// @dev The receipt a queued delivery carries, as `ReceiptWaiting` gives it back.
    function _receiptAt(ERC7786GatewayMock gateway, uint256 index)
        internal
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        (, bytes memory body) = MessageTypesLib.decode(gateway.queuedMessage(index).payload);
        return MessageTypesLib.decodeSettlement(body);
    }

    /// @dev A first-half receipt for an id home has no record of, as an away token that moved `amount` reports it.
    function _receiptWithNoTicket(bytes32 ticketId, bytes memory from, bytes memory to, uint256 amount)
        internal
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        uint64 validUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: from,
            to: to,
            amount: amount,
            askBlockHash: TicketLib.askBlockHashOf(amount, validUntil),
            seenMax: amount,
            seenValidUntil: validUntil,
            half: 0,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    /* ----- Roles and modules ----- */

    function _blockPolygon() internal {
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);
    }

    function _unblockPolygon() internal {
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
    }

    function _pauseTheToken() internal {
        vm.prank(agent);
        token.pause();
    }

    /// @dev Replaces the polygon peer as hostile: a hostile change runs on polygon from now.
    function _replacePolygonPeerAsHostile() internal {
        vm.prank(deployer);
        token.replaceHostilePeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, makeAddr("newPolygonAwayToken")));
    }

    /// @dev Binds an approval module answered by `approver`; an approval module is bound only while asks are paused.
    function _bindApprovalModule(address approver) internal returns (AsyncApprovalModule module) {
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
        vm.startPrank(deployer);
        boundCompliance.setAsksPaused(bytes32(0), true);
        boundCompliance.addAndSetModule(address(module), settings);
        boundCompliance.setAsksPaused(bytes32(0), false);
        vm.stopPrank();
    }

    /* ----- Reads ----- */

    function _statusOf(bytes32 ticketId) internal view returns (ITickets.TicketStatus) {
        return boundCompliance.statusOf(ticketId);
    }

    function _assertStatus(bytes32 ticketId, ITickets.TicketStatus expected, string memory message) internal view {
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(expected), message);
    }

    /// @dev Home's away balances and the away token's balances agree, wallet by wallet, once every message landed.
    function _assertHomeAgreesWithPolygon() internal view {
        assertEq(token.awayBalanceOf(aliceSat), polygonLite.balanceOf(aliceSat), "alice: home and polygon agree");
        assertEq(token.awayBalanceOf(bobSat), polygonLite.balanceOf(bobSat), "bob: home and polygon agree");
        assertEq(token.awayBalanceOf(charlieSat), polygonLite.balanceOf(charlieSat), "charlie: home and polygon agree");
    }

    /// @dev Total owned: the positions of the three identities are the whole supply.
    function _assertPositionsAreTheSupply() internal view {
        uint256 positions = boundCompliance.positionOf(address(aliceIdentity))
            + boundCompliance.positionOf(address(bobIdentity)) + boundCompliance.positionOf(address(charlieIdentity));
        assertEq(positions, token.totalSupply(), "total owned is the supply");
    }

}

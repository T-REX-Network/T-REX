// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { AwayChainVolumeModule } from "contracts/compliance/modular/modules/AwayChainVolumeModule.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev The limit on what may leave one away chain in a window. An ask, or home's decision for a second half, is
///      narrowed to the room left on the chain the money leaves; a move is counted once, when it is done, on that
///      chain; the next window opens it again. The chain comes from the context's `data`; a native transfer carries
///      none and is neither limited nor counted.
contract AwayChainVolumeModuleTest is InteropSuiteTest {

    uint256 internal constant ALICE_AWAY_BALANCE = 1000;
    uint256 internal constant LIMIT = 100;
    uint64 internal constant WINDOW = 1 hours;
    /// @dev A chain's clock long past one window: a chain never counted has a window from zero, over only then.
    uint256 internal constant A_REAL_CHAINS_CLOCK = 1_750_000_000;

    AwayChainVolumeModule internal volumeRule;
    ERC7786GatewayMock internal polygonBridge;
    ERC7786GatewayMock internal optimismBridge;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal bobOnOptimism;

    function setUp() public override {
        super.setUp();
        vm.warp(A_REAL_CHAINS_CLOCK);
        polygonBridge = _newReceiptBridge(POLYGON);
        optimismBridge = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonBridge));
        _openEvmChain(token, OPTIMISM, address(optimismBridge));
        aliceSat =
            _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), ALICE_AWAY_BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        bobOnOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        volumeRule = AwayChainVolumeModule(
            address(
                new ModuleProxy(
                    address(new AwayChainVolumeModule()),
                    abi.encodeCall(AwayChainVolumeModule.initialize, (address(suiteManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(AwayChainVolumeModule.setVolumeLimit, (polygon, LIMIT, WINDOW));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(volumeRule), settings);

        vm.prank(agent);
        token.unpause();
    }

    /* ----- The room on one chain ----- */

    /// @notice 70 left Polygon in the window: an ask from Polygon for [10, 50] is narrowed to the 30 left, and one
    ///         for [40, 50] has no room left in its range.
    function test_checkTransfer_narrowsTheTicket_whenTheAwayChainIsNearItsVolumeLimit() public {
        uint256 alreadyLeft = 70;
        uint256 roomLeft = LIMIT - alreadyLeft;
        _moveInsidePolygon(alreadyLeft);

        bytes32 narrowed = _askFromPolygon(bobSat, 10, 50);
        assertEq(boundCompliance.ticketOf(narrowed).amountMax, roomLeft);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 40, roomLeft));
        boundCompliance.askToMove(aliceSat, bobSat, 40, 50, "", _salt());
    }

    /// @notice A full window refuses every ask from the chain until its last second; at its end an ask is issued
    ///         whole, and its done move starts a new window at that time.
    function test_checkTransfer_opensAgain_inTheNextWindow() public {
        uint64 windowStart = uint64(block.timestamp);
        _moveInsidePolygon(LIMIT);

        vm.prank(address(aliceIdentity));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        boundCompliance.askToMove(aliceSat, bobSat, 10, LIMIT, "", _salt());

        vm.warp(windowStart + WINDOW - 1);
        assertEq(_roomOn(polygon), 0, "still full in its last second");

        uint64 nextWindowStart = windowStart + WINDOW;
        vm.warp(nextWindowStart);
        _moveInsidePolygon(LIMIT);

        vm.warp(nextWindowStart + WINDOW - 1);
        assertEq(_roomOn(polygon), 0, "the new window started at the done move");
        vm.warp(nextWindowStart + WINDOW);
        assertEq(_roomOn(polygon), LIMIT);
    }

    /// @notice A chain with no limit is neither limited nor counted: a limit set for it later starts from zero.
    function test_checkTransfer_limitsNothing_onAChainWithNoLimit() public {
        assertEq(_roomOn(optimism), type(uint256).max);
        bytes memory aliceOnOptimism =
            _fundSatelliteWallet(aliceIdentity, alice, OPTIMISM, makeAccount("aliceOnOptimism"), ALICE_AWAY_BALANCE);
        bytes memory charlieOnOptimism =
            _linkSatelliteWallet(charlieIdentity, OPTIMISM, makeAccount("charlieOnOptimism"));
        bytes32 ticketId = _requestValidation(address(aliceIdentity), aliceOnOptimism, charlieOnOptimism, 1, 500);
        assertEq(boundCompliance.ticketOf(ticketId).amountMax, 500, "not narrowed");
        optimismBridge.relay(
            _liteSettles(optimismBridge, token, _settlement(ticketId, aliceOnOptimism, charlieOnOptimism, 500))
        );

        _setLimit(optimism, LIMIT, WINDOW);

        assertEq(_roomOn(optimism), LIMIT, "nothing was counted before the limit");
    }

    /// @notice A native transfer carries no chain: it is never limited, and never counted.
    function test_checkTransfer_limitsNothing_onANativeTransfer() public {
        vm.prank(agent);
        token.mint(alice, 500);

        vm.prank(alice);
        token.transfer(bob, 500);

        assertEq(token.balanceOf(bob), 500);
        assertEq(_roomOn(polygon), LIMIT, "nothing counted on any chain");
        IModule.TransferContext memory native = _contextOn(polygon, 0);
        native.data = "";
        assertEq(volumeRule.checkTransfer(native), type(uint256).max);
    }

    /// @notice A limit of the largest number never narrows.
    function test_checkTransfer_neverNarrows_whenTheLimitIsTheLargestNumber() public {
        _setLimit(polygon, type(uint256).max, WINDOW);

        bytes32 ticketId = _askFromPolygon(bobSat, 10, 500);

        assertEq(boundCompliance.ticketOf(ticketId).amountMax, 500);
    }

    /// @notice A new window length moves the end of the window running now, both ways.
    function test_setVolumeLimit_movesTheEndOfTheRunningWindow_bothWays() public {
        uint64 windowStart = uint64(block.timestamp);
        _moveInsidePolygon(LIMIT);

        _setLimit(polygon, LIMIT, 2 * WINDOW);
        vm.warp(windowStart + WINDOW);
        assertEq(_roomOn(polygon), 0, "a longer window ends later");

        _setLimit(polygon, LIMIT, WINDOW / 2);
        assertEq(_roomOn(polygon), LIMIT, "a shorter window already ended");
    }

    /* ----- The second half and the receipt ----- */

    /// @notice Another move from Polygon finishes between an ask toward Optimism and its first-half receipt, and
    ///         fills Polygon: home's decision for the second half finds no room, and the money goes back to the
    ///         sender, never minted to the receiver.
    function test_checkTransfer_sendsTheMoneyBack_whenTheChainFilledBeforeTheSecondHalf() public {
        bytes32 toOptimism = _askFromPolygon(bobOnOptimism, 10, 50);
        _moveInsidePolygon(LIMIT);

        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(toOptimism, aliceSat, bobOnOptimism, 50)));

        ITickets.Ticket memory held = boundCompliance.ticketOf(toOptimism);
        assertEq(uint8(held.status), uint8(ITickets.TicketStatus.OnHold));
        assertEq(held.secondHalfToKey, held.fromKey, "back to the sender");
        assertEq(token.awayBalanceOf(bobOnOptimism), 0, "no mint to the receiver");
    }

    /// @notice A move inside Polygon whose receipt finds no room left is applied all the same, since the tokens
    ///         already moved there; it is announced, and counted.
    function test_afterTransfer_countsAMoveInsideTheChain_thatBreachedTheLimitAtItsReceipt() public {
        uint256 lateMove = 50;
        bytes32 ticketId = _askFromPolygon(bobSat, 10, lateMove);
        _moveInsidePolygon(LIMIT);
        uint256 index = _liteSettles(polygonBridge, token, _settlement(ticketId, aliceSat, bobSat, lateMove));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.MoveBreachedRule(ticketId, polygon, lateMove);
        polygonBridge.relay(index);

        assertEq(token.awayBalanceOf(bobSat), LIMIT + lateMove, "applied");
        _setLimit(polygon, 2 * LIMIT, WINDOW);
        assertEq(_roomOn(polygon), 2 * LIMIT - LIMIT - lateMove, "and counted");
    }

    /// @notice A relocation between one identity's own wallets is not asked: it is issued whatever the room, and
    ///         counted against the chain it left when it is done.
    function test_afterTransfer_countsARelocation_whichIsIssuedWhateverTheRoom() public {
        uint256 relocated = 200;
        bytes memory aliceOther = _linkSatelliteWallet(aliceIdentity, POLYGON, makeAccount("aliceOtherOnPolygon"));
        _moveInsidePolygon(LIMIT);

        bytes32 relocation = _askFromPolygon(aliceOther, relocated, relocated);
        assertEq(boundCompliance.ticketOf(relocation).amountMax, relocated, "issued whole");
        polygonBridge.relay(
            _liteSettles(polygonBridge, token, _settlement(relocation, aliceSat, aliceOther, relocated))
        );

        _setLimit(polygon, 1000, WINDOW);
        assertEq(_roomOn(polygon), 1000 - LIMIT - relocated, "counted when done");
    }

    /// @notice A home wallet's move out leaves home: its context carries home's own key, and with no limit on home
    ///         it is free.
    function test_checkTransfer_limitsNothing_onAHomeWalletsMoveOut_whenHomeHasNoLimit() public {
        bytes32 ticketId = _askFromAliceHome(200);

        assertEq(boundCompliance.ticketOf(ticketId).amountMax, 200);
    }

    /// @notice A limit on home's own key narrows a home wallet's move out.
    function test_checkTransfer_narrowsAHomeWalletsMoveOut_byTheLimitOnHome() public {
        _setLimit(_evmChainKey(block.chainid), LIMIT, WINDOW);

        bytes32 ticketId = _askFromAliceHome(200);

        assertEq(boundCompliance.ticketOf(ticketId).amountMax, LIMIT);
    }

    /// @notice A bring home leaves Polygon too: what it burned is counted against Polygon when minted at home.
    function test_afterTransfer_countsABringHome_againstTheChainItLeft() public {
        uint256 broughtHome = 40;
        vm.prank(agent);
        bytes32 bringHomeId = boundCompliance.bringHome(aliceSat, broughtHome, alice, _salt());
        MessageTypesLib.ReceiptMessage memory burned = MessageTypesLib.ReceiptMessage({
            ticketId: bringHomeId,
            from: aliceSat,
            to: "",
            amount: broughtHome,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: 1,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });

        polygonBridge.relay(_liteSettles(polygonBridge, token, burned));

        assertEq(token.balanceOf(alice), broughtHome, "minted at home");
        assertEq(_roomOn(polygon), LIMIT - broughtHome);
    }

    /* ----- Settings and binding ----- */

    /// @notice Setting a limit emits and is read back; a window of zero is refused; an unbound caller is refused.
    function test_setVolumeLimit_setsTheLimit_andRefusesAZeroWindowAndAnUnboundCaller() public {
        vm.expectEmit(true, true, false, true, address(volumeRule));
        emit AwayChainVolumeModule.VolumeLimitSet(address(boundCompliance), optimism, LIMIT, WINDOW);
        _setLimit(optimism, LIMIT, WINDOW);
        AwayChainVolumeModule.VolumeLimit memory limit = volumeRule.volumeLimitOf(address(boundCompliance), optimism);
        assertEq(limit.limitPerWindow, LIMIT);
        assertEq(limit.window, WINDOW);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroDuration.selector);
        boundCompliance.callModuleFunction(
            abi.encodeCall(AwayChainVolumeModule.setVolumeLimit, (optimism, LIMIT, 0)), address(volumeRule)
        );

        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        volumeRule.setVolumeLimit(optimism, LIMIT, WINDOW);
    }

    /// @notice A limit is set only while nothing is reserved: the rules a ticket was asked under stay until it ends.
    function test_setVolumeLimit_reverts_when_aTicketIsOpen() public {
        _askFromPolygon(bobSat, 10, 50);

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.TicketsStillReserved.selector);
        boundCompliance.callModuleFunction(
            abi.encodeCall(AwayChainVolumeModule.setVolumeLimit, (polygon, LIMIT, WINDOW)), address(volumeRule)
        );
    }

    /// @notice An unbind discards the limits and the counts: a rebind starts with none.
    function test_volumeLimitOf_isEmpty_afterAnUnbindAndARebind() public {
        _moveInsidePolygon(LIMIT);

        vm.startPrank(deployer);
        boundCompliance.removeModule(address(volumeRule));
        boundCompliance.addModule(address(volumeRule));
        vm.stopPrank();

        assertEq(volumeRule.volumeLimitOf(address(boundCompliance), polygon).window, 0, "no limit any more");
        _setLimit(polygon, LIMIT, WINDOW);
        assertEq(_roomOn(polygon), LIMIT, "no count any more");
    }

    /// @notice A compliance counts under itself, whatever compliance its context names, and a move of any kind with
    ///         a chain is counted without a revert.
    function test_afterTransfer_countsUnderTheCallingCompliance_forAnyKind() public {
        address otherCompliance = makeAddr("otherCompliance");
        uint256 counted = 40;
        IModule.TransferContext memory move = _contextOn(polygon, counted);
        move.compliance = otherCompliance;
        move.kind = 99;

        vm.prank(address(boundCompliance));
        volumeRule.afterTransfer(move);

        assertEq(_roomOn(polygon), LIMIT - counted, "counted under the calling compliance");
        move.amountMax = 0;
        assertEq(volumeRule.checkTransfer(move), type(uint256).max, "the other compliance has no limit");
    }

    function test_moduleTypes_namesARuleAndATracker() public view {
        IModule.ModuleType[] memory types = volumeRule.moduleTypes();
        assertEq(types.length, 2);
        assertEq(uint8(types[0]), uint8(IModule.ModuleType.TRANSFER_CHECK));
        assertEq(uint8(types[1]), uint8(IModule.ModuleType.AFTER));
    }

    /* ----- Helpers ----- */

    /// @dev Alice's home wallet holds 500 and asks to move out up to `amountMax` to Bob on Polygon.
    function _askFromAliceHome(uint256 amountMax) private returns (bytes32) {
        vm.prank(agent);
        token.mint(alice, 500);
        bytes memory aliceHome = InteroperableAddress.formatEvmV1(block.chainid, alice);
        vm.prank(alice);
        return boundCompliance.askToMove(aliceHome, bobSat, 10, amountMax, "", _salt());
    }

    function _askFromPolygon(bytes memory to, uint256 amountMin, uint256 amountMax) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), aliceSat, to, amountMin, amountMax);
    }

    /// @dev Alice moves `amount` to Bob inside Polygon, and the away token's receipt lands: done, and counted.
    function _moveInsidePolygon(uint256 amount) private {
        bytes32 ticketId = _askFromPolygon(bobSat, amount, amount);
        polygonBridge.relay(_liteSettles(polygonBridge, token, _settlement(ticketId, aliceSat, bobSat, amount)));
        assertEq(uint8(boundCompliance.statusOf(ticketId)), uint8(ITickets.TicketStatus.Done));
    }

    function _setLimit(bytes32 chainKey, uint256 limitPerWindow, uint64 window) private {
        vm.prank(deployer);
        boundCompliance.callModuleFunction(
            abi.encodeCall(AwayChainVolumeModule.setVolumeLimit, (chainKey, limitPerWindow, window)),
            address(volumeRule)
        );
    }

    /// @dev What the rule allows to leave `chainKey` now, for the suite's compliance.
    function _roomOn(bytes32 chainKey) private view returns (uint256) {
        return volumeRule.checkTransfer(_contextOn(chainKey, 0));
    }

    /// @dev A move of `amount` leaving `chainKey`, as the compliance builds one.
    function _contextOn(bytes32 chainKey, uint256 amount) private view returns (IModule.TransferContext memory) {
        return IModule.TransferContext({
            compliance: address(boundCompliance),
            fromIdentity: address(aliceIdentity),
            toIdentity: address(bobIdentity),
            fromWallet: bytes32(0),
            toWallet: bytes32(0),
            amountMin: amount,
            amountMax: amount,
            kind: MovementKindLib.CROSS_CHAIN,
            isIssuance: false,
            spender: "",
            data: abi.encode(chainKey)
        });
    }

}

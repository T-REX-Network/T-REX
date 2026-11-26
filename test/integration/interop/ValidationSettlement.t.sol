// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

pragma solidity 0.8.30;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { ReentrantModule } from "test/integration/mocks/ReentrantModule.sol";

/// @dev Receipts through the real messaging layer: a same-chain move, a native recipient, the deadline that never
///      refuses a receipt, every bad receipt that is refused, every broken term that is applied and blocks its chain,
///      and an id home does not know, which blocks nobody. The token itself is never stopped by a receipt.
contract ValidationSettlementTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;
    uint256 internal constant NATIVE_BALANCE = 500;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    CappedRecipientModule internal cappedRule;
    bytes internal aliceSat;
    bytes internal bobSat;
    bytes internal nativeBob;
    uint256 internal issuedAt;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newReceiptBridge(POLYGON);
        optimismGateway = _newReceiptBridge(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.startPrank(deployer);
        boundCompliance.addModule(address(cappedRule));
        vm.stopPrank();

        vm.startPrank(agent);
        token.mint(alice, NATIVE_BALANCE);
        token.unpause();
        vm.stopPrank();
        issuedAt = block.timestamp;
    }

    // ==== happy path Tests ====

    /// @notice A same-chain leg with both wallets settles: ledger, module, status, events.
    function test_handleSettlement_Success_WhenSameChainLegSettles() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(aliceSat), keccak256(bobSat), id, aliceSat, bobSat, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, polygon, 95);
        polygonGateway.relay(index);

        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 95);
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertEq(token.totalAwayBalance(), BALANCE);
        assertEq(token.totalSupply(), BALANCE + NATIVE_BALANCE);
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "released once settled");
        assertEq(ledger.positionOf(address(bobIdentity)), 95, "and became a position");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        ITickets.Ticket memory state = boundCompliance.ticketOf(id);
        assertEq(state.moved, 95);
        assertFalse(token.paused());
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
    }

    /// @notice A satellite sender toward a native wallet settles with one leg from the sender's chain, crediting
    ///         the recipient under the validation it consumed.
    function test_handleSettlement_Success_WhenTheRecipientIsNative() public {
        bytes32 id = _issue(aliceSat, nativeBob, 10, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, nativeBob, 40));

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(aliceSat), bob, id, aliceSat, 40);
        polygonGateway.relay(index);

        assertEq(token.balanceOf(bob), 40);
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 40);
        assertEq(token.totalAwayBalance(), BALANCE - 40);
        assertEq(token.totalSupply(), BALANCE + NATIVE_BALANCE);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice A native recipient relinked between issuance and settlement is credited to the identity the registry
    ///         names when the leg lands, not to the one recorded at issuance.
    function test_handleSettlement_Success_CreditsTheCurrentOwner_WhenTheNativeRecipientWasRelinked() public {
        bytes32 id = _issue(aliceSat, nativeBob, 10, 100);
        // Registry writes never relink a wallet, so the relink is simulated as the owner swapping the storage.
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        address storageAddress = address(token.identityRegistry().identityStorage());
        vm.mockCall(
            storageAddress,
            abi.encodeCall(token.identityRegistry().identityStorage().storedIdentity, (bob)),
            abi.encode(address(charlieIdentity))
        );
        uint256 charlieBefore = ledger.positionOf(address(charlieIdentity));
        uint256 bobBefore = ledger.positionOf(address(bobIdentity));

        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, nativeBob, 40)));

        assertEq(ledger.ownerOf(bob), address(charlieIdentity), "the ledger follows the registry");
        assertEq(ledger.positionOf(address(charlieIdentity)), charlieBefore + 40, "credited to the current owner");
        assertEq(ledger.positionOf(address(bobIdentity)), bobBefore, "not to the identity stored at issuance");
    }

    /// @notice Past the release deadline but before any discard, a leg settles normally: the slot is still held.
    function test_handleSettlement_Success_WhenTheLegArrivesAfterTheDeadlineBeforeAnyDiscard() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95));

        vm.warp(issuedAt + VALIDITY_WINDOW + POLYGON_WINDOW + 1 days);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));

        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
    }

    // ==== mismatch Tests: the leg is consumed, nothing moves, and the chain that executed it is paused ====

    /// @notice A receipt outside the bounds of home's own copy breaks its terms: it is applied as it happened,
    ///         because the away token's balances already moved, and the chain that executed it is blocked.
    function test_handleSettlement_AppliesAndBlocks_WhenTheAmountIsOutsideTheBounds() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 below = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 80));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, polygon, 80);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonGateway.relay(below);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon), "the chain that broke the terms is blocked");
        assertFalse(token.paused(), "the token keeps running");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 80);
        assertEq(token.awayBalanceOf(bobSat), 80);
    }

    /// @notice A receipt naming a wallet other than the ticket's, or leaving one empty, is a bad receipt: refused,
    ///         nothing applied, the ticket stays `Open` and the chain is blocked.
    function test_handleSettlement_Success_WhenAWalletIsNotTheIssuedOneTheLegIsRejected() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        bytes memory carolSat = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("carolOnPolygon"));

        uint256 wrongTo = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, carolSat, 95));
        uint256 wrongFrom = _liteSettles(polygonGateway, token, _settlement(id, carolSat, bobSat, 95));
        uint256 emptyTo = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, "", 95));

        _relayRejected(polygonGateway, polygon, wrongTo, id, 95);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        _relayRejected(polygonGateway, polygon, wrongFrom, id, 95);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        _relayRejected(polygonGateway, polygon, emptyTo, id, 95);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE);
        assertEq(token.awayBalanceOf(bobSat), 0);
        assertEq(token.awayBalanceOf(carolSat), 0);
    }

    /// @notice A receipt from a chain the ticket was not sent to is a bad receipt: that chain is blocked, the
    ///         sender's chain is untouched and the ticket stays `Open`.
    function test_handleSettlement_Success_WhenTheLegComesFromAnotherChainItIsRejected() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        uint256 index = _liteSettles(optimismGateway, token, _settlement(id, aliceSat, bobSat, 95));

        _relayRejected(optimismGateway, optimism, index, id, 95);

        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(bobSat), 0);
    }

    /// @notice A receipt under another ask block hash answers a copy from a home block a reorg dropped. One that
    ///         moved more than the copy it echoes allowed breaks its terms: it is applied as it happened, the ticket's
    ///         reservation is released, and the chain that executed it is blocked.
    function test_handleSettlement_AppliesAndBlocks_WhenAnOutOfBoundsLegUnderAnotherHashBreaksItsTerms() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 100, "reserved at the maximum while pending");
        assertEq(token.reservedOf(aliceSat), 100, "and held on the sender's wallet");
        bytes32 olderHash = keccak256("older copy");
        uint256 index = _liteSettles(polygonGateway, token, _settlementUnder(id, aliceSat, bobSat, 101, olderHash));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, 100);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonGateway.relay(index);

        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)));
        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(token.paused());
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "the recipient's reservation is released");
        assertEq(token.reservedOf(aliceSat), 0, "and so is the sender's hold");
        assertEq(boundCompliance.ticketOf(id).moved, 101);
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 101);
        assertEq(token.awayBalanceOf(bobSat), 101);
    }

    /// @notice A receipt inside the terms of an older copy, under the away chain's per-ticket cap, is applied and
    ///         says so; the honest away chain stays open.
    function test_handleSettlement_Success_WhenAnInRangeLegUnderAnotherHashSettlesAndReportsTheDivergence() public {
        vm.prank(deployer);
        boundCompliance.setTicketLimits(polygon, 100, 100);
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        bytes32 otherHash = keccak256("other body");
        uint256 index = _liteSettles(polygonGateway, token, _settlementUnder(id, aliceSat, bobSat, 95, otherHash));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptOnOlderTerms(id, polygon, 100);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, polygon, 95);
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(boundCompliance.ticketOf(id).moved, 95);
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 95);
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertFalse(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(token.paused());
    }

    // ==== emergency Tests ====

    /// @notice Another receipt for a half that already has one applies nothing and blocks the chain it came from;
    ///         the token itself keeps running. It is consumed, not left deliverable.
    function test_handleSettlement_Success_WhenAReplayedSettlementPausesTheChain() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        polygonGateway.relay(_liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 95)));
        uint256 replay = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 96));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, polygon, 96, boundCompliance.ticketOf(id).askBlockHash);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(polygon);
        polygonGateway.relay(replay);

        assertTrue(boundCompliance.isAwayChainBlocked(polygon));
        assertFalse(token.paused());
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(replay)));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
    }

    /// @notice A good receipt from a blocked away chain is consumed and waits, tagged with the bridge that brought
    ///         it; the ticket stays open. Once the pauser lifts the block, anyone applies it.
    function test_receiveReceipt_waits_whenTheAwayChainIsBlocked() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(id, aliceSat, bobSat, 95);
        uint256 index = _liteSettles(polygonGateway, token, receipt);
        vm.prank(agent);
        boundCompliance.blockAwayChain(polygon);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(id, polygon, address(polygonGateway), receipt);
        polygonGateway.relay(index);
        assertTrue(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(index)), "consumed");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(bobSat), 0, "nothing applied");
        ITickets.WaitingReceipt memory waiting = boundCompliance.waitingReceiptOf(id);
        assertEq(waiting.bodyHash, keccak256(abi.encode(polygon, receipt)));
        assertEq(waiting.deliveredBy, address(polygonGateway));

        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainUnblocked(polygon);
        vm.prank(agent);
        boundCompliance.unblockAwayChain(polygon);
        vm.prank(makeAddr("anyone"));
        boundCompliance.applyWaitingReceipt(id, receipt);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
        assertEq(boundCompliance.waitingReceiptOf(id).bodyHash, bytes32(0), "taken off the shelf");
    }

    /// @notice A receipt for an id home has no record of applies nothing and blocks nobody: it reverts and stays
    ///         deliverable at the bridge, and the token keeps running.
    function test_handleSettlement_RevertWhen_TheIdWasNeverIssued_AndBlocksNobody() public {
        bytes32 unknown = bytes32(uint256(999));
        uint256 index =
            _liteSettles(polygonGateway, token, _settlementUnder(unknown, aliceSat, bobSat, 95, keccak256("body")));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnknownTicket.selector, unknown));
        polygonGateway.relay(index);

        _assertNothingApplied(polygonGateway, index);
        assertFalse(token.paused());
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "no chain is blocked over an unknown id");
        assertEq(token.awayBalanceOf(aliceSat), BALANCE);
        assertEq(token.awayBalanceOf(bobSat), 0);
        assertEq(boundCompliance.waitingReceiptOf(unknown).bodyHash, bytes32(0), "nothing waits");
    }

    /// @notice While the token is stopped a good receipt is consumed and waits; once the token runs again, anyone
    ///         applies it.
    function test_receiveReceipt_waits_whenTheTokenIsStopped() public {
        bytes32 id = _issue(aliceSat, bobSat, 90, 100);
        MessageTypesLib.ReceiptMessage memory receipt = _settlement(id, aliceSat, bobSat, 95);
        uint256 index = _liteSettles(polygonGateway, token, receipt);
        vm.prank(agent);
        token.pause();

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptWaiting(id, polygon, address(polygonGateway), receipt);
        polygonGateway.relay(index);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(bobSat), 0, "nothing applied");

        vm.expectRevert(ErrorsLib.TokenPaused.selector);
        boundCompliance.applyWaitingReceipt(id, receipt);

        vm.prank(agent);
        token.unpause();
        boundCompliance.applyWaitingReceipt(id, receipt);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 95);
    }

    /// @notice Only the pauser lifts a halt.
    function test_unpause_RevertWhen_CallerIsNotThePauser() public {
        vm.prank(agent);
        token.pause();
        assertTrue(token.paused());

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, deployer));
        token.unpause();

        vm.prank(agent);
        token.unpause();
        assertFalse(token.paused());
    }

    // ==== reentrancy Tests ====

    function test_handleSettlement_RevertWhen_ATrackerRelaysAnotherSettlementFromItsHook() public {
        ReentrantModule attacker = _bindReentrantModule();
        bytes32 first = _issue(aliceSat, bobSat, 10, 100);
        bytes32 second = _issue(aliceSat, bobSat, 10, 100);
        uint256 outer = _liteSettles(polygonGateway, token, _settlement(first, aliceSat, bobSat, 40));
        uint256 nested = _liteSettles(polygonGateway, token, _settlement(second, aliceSat, bobSat, 50));
        attacker.armRelay(address(polygonGateway), nested);

        polygonGateway.relay(outer);

        _assertNestedRelayRejected(attacker, nested);
        assertEq(uint8(boundCompliance.statusOf(first)), uint8(ITickets.TicketStatus.Done));
        assertEq(uint8(boundCompliance.statusOf(second)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(bobSat), 40);

        polygonGateway.relay(nested);

        assertEq(uint8(boundCompliance.statusOf(second)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobSat), 90);
    }

    function test_handleSettlement_RevertWhen_ATrackerRelaysASettlementFromATransferHook() public {
        ReentrantModule attacker = _bindReentrantModule();
        bytes32 id = _issue(aliceSat, bobSat, 10, 100);
        uint256 nested = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobSat, 40));
        attacker.armRelay(address(polygonGateway), nested);

        vm.prank(alice);
        token.transfer(bob, 10);

        _assertNestedRelayRejected(attacker, nested);
        assertEq(token.balanceOf(bob), 10);
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(bobSat), 0);
    }

    function _bindReentrantModule() private returns (ReentrantModule attacker) {
        attacker = ReentrantModule(
            address(new ERC1967Proxy(address(new ReentrantModule()), abi.encodeCall(ReentrantModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(attacker));
    }

    function _assertNestedRelayRejected(ReentrantModule attacker, uint256 nested) private view {
        assertFalse(attacker.lastCallSucceeded());
        assertEq(
            attacker.lastCallReturnData(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        _assertNothingApplied(polygonGateway, nested);
    }

    function _issue(bytes memory from, bytes memory to, uint256 min, uint256 max) private returns (bytes32) {
        return _requestValidation(address(aliceIdentity), from, to, min, max);
    }

    function _assertNothingApplied(ERC7786GatewayMock gateway, uint256 index) private view {
        assertFalse(token.messageReceived(address(gateway), gateway.receiveIdFor(index)));
    }

    /// @dev Relays a leg carrying the issued ask block hash that fails the substantive gate: it is rejected,
    ///  consumed, and pauses the inbound of `chainKey`.
    function _relayRejected(ERC7786GatewayMock gateway, bytes32 chainKey, uint256 index, bytes32 id, uint256 amount)
        private
    {
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, chainKey, amount, boundCompliance.ticketOf(id).askBlockHash);
        vm.expectEmit(true, false, false, true, address(boundCompliance));
        emit EventsLib.AwayChainBlockStarted(chainKey);
        gateway.relay(index);

        assertTrue(token.messageReceived(address(gateway), gateway.receiveIdFor(index)), "the leg is consumed");
        assertTrue(boundCompliance.isAwayChainBlocked(chainKey), "the chain that executed it is paused");
        assertFalse(token.paused(), "the token keeps running");
    }

}

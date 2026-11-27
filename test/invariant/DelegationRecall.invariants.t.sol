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

import { StdInvariant } from "@forge-std/StdInvariant.sol";
import { console } from "@forge-std/console.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SatelliteLiteMock } from "test/integration/mocks/SatelliteLiteMock.sol";

/// @title DelegationRecallInvariants
/// @notice Stateful check of a home wallet's move out and of the bring home, through the public entry points, with a
///  mock away token that follows `docs/satellite-lite.md` in the loop.
///
/// Three identities, each with a home wallet and one linked wallet on one away chain. The fuzzer mints, transfers at
/// home, moves out of a home wallet, brings home, sends a second half again, has the away token send a stored
/// receipt again, and relays or drops queued messages in any order, so halves, receipts and duplicates interleave.
///
///   DR-1  positionOf(identity) == home balance + away balance of its wallet + its money on hold
///   DR-2  sum of positions == totalSupply()
///   DR-3  totalAwayBalance == away token balances + move outs not minted yet + burns done on the away token whose
///         receipt home has not applied yet (the away token no longer holds them, home still counts them)
///   DR-4  the away token minted exactly the move outs it answered, once each
///   DR-5  what is away is what moved out less what every finished bring home burned
///   DR-6  an honest away token never blocks its chain or stops the token
contract DelegationRecallInvariants is StdInvariant, InteropSuiteTest {

    uint256 internal constant ACTORS = 3;
    uint256 internal constant MAX_AMOUNT = 400;

    address[] internal actors;
    IIdentity[] internal identities;
    bytes[] internal satellites;

    ERC7786GatewayMock internal gateway;
    SatelliteLiteMock internal lite;
    IComplianceLedger internal ledger;

    /// @dev Every move out asked, with its actor and amount, and every bring home written, with its actor. Entry 0 of
    ///  each is a placeholder written in `setUp`, so a state snapshot taken there holds every array slot and a revert
    ///  to it restores them all; the entries start at 1.
    bytes32[] internal moveOutIds;
    uint256[] internal moveOutActor;
    uint256[] internal moveOutAmount;
    bytes32[] internal bringHomeIds;
    uint256[] internal bringHomeActor;

    uint256 public callsMoveOut;
    uint256 public callsBringHome;
    uint256 public callsSendAgain;
    uint256 public callsRelay;

    function setUp() public virtual override {
        super.setUp();
        ledger = IComplianceLedger(address(boundCompliance));
        gateway = _newReceiptBridge(POLYGON);
        lite = new SatelliteLiteMock(POLYGON, address(token), gateway);
        vm.startPrank(deployer);
        token.setPeer(polygon, InteroperableAddress.formatEvmV1(POLYGON, address(lite)));
        vm.stopPrank();
        _openEvmChain(token, POLYGON, address(gateway));

        actors = [alice, bob, charlie];
        identities = [aliceIdentity, bobIdentity, charlieIdentity];
        for (uint256 i = 0; i < ACTORS; i++) {
            satellites.push(
                _linkSatelliteWallet(identities[i], POLYGON, makeAccount(string.concat("sat", vm.toString(i))))
            );
        }

        // The salt counter is written here too, for the same reason: a reorg replays the asks with the salts they had.
        _salt();
        moveOutIds.push(bytes32(0));
        moveOutActor.push(0);
        moveOutAmount.push(0);
        bringHomeIds.push(bytes32(0));
        bringHomeActor.push(0);

        vm.startPrank(agent);
        for (uint256 i = 0; i < ACTORS; i++) {
            token.mint(actors[i], 1000);
        }
        token.unpause();
        vm.stopPrank();

        targetContract(address(this));
        targetSelector(FuzzSelector({ addr: address(this), selectors: _targetSelectors() }));
    }

    /// @dev The transitions the fuzzer calls. A suite built on this one appends its own.
    function _targetSelectors() internal view virtual returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = this.mint.selector;
        selectors[1] = this.transfer.selector;
        selectors[2] = this.moveOut.selector;
        selectors[3] = this.bringHome.selector;
        selectors[4] = this.sendSecondHalfAgain.selector;
        selectors[5] = this.liteResendsReceipt.selector;
        selectors[6] = this.relay.selector;
        selectors[7] = this.drop.selector;
    }

    /* ----- Transitions ----- */

    function mint(uint256 actorSeed, uint256 amount) public virtual {
        vm.prank(agent);
        token.mint(actors[actorSeed % ACTORS], bound(amount, 1, MAX_AMOUNT));
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public virtual {
        address from = actors[fromSeed % ACTORS];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(actors[toSeed % ACTORS], amount) { } catch { }
    }

    /// @notice A home wallet moves out to its identity's away wallet: burned onto hold at once, its move out sent.
    function moveOut(uint256 actorSeed, uint256 amount) public virtual {
        callsMoveOut++;
        uint256 actor = actorSeed % ACTORS;
        amount = bound(amount, 1, MAX_AMOUNT);
        bytes memory homeWallet = InteroperableAddress.formatEvmV1(block.chainid, actors[actor]);
        vm.prank(actors[actor]);
        try boundCompliance.askToMove(homeWallet, satellites[actor], amount, amount, "", _salt()) returns (
            bytes32 ticketId
        ) {
            moveOutIds.push(ticketId);
            moveOutActor.push(actor);
            moveOutAmount.push(amount);
        } catch { }
    }

    /// @notice An agent brings an away wallet's tokens home to its identity's home wallet.
    function bringHome(uint256 actorSeed, uint256 amount) public virtual {
        callsBringHome++;
        uint256 actor = actorSeed % ACTORS;
        amount = bound(amount, 1, MAX_AMOUNT);
        vm.prank(agent);
        try boundCompliance.bringHome(satellites[actor], amount, actors[actor], _salt()) returns (bytes32 ticketId) {
            bringHomeIds.push(ticketId);
            bringHomeActor.push(actor);
        } catch { }
    }

    /// @notice Anyone sends a second half again, or a new one when the last was answered expired.
    function sendSecondHalfAgain(uint256 idSeed, bool aBringHome) public virtual {
        callsSendAgain++;
        uint256 actor;
        bytes32 ticketId;
        if (aBringHome) {
            if (bringHomeIds.length == 1) return;
            uint256 index = 1 + idSeed % (bringHomeIds.length - 1);
            ticketId = bringHomeIds[index];
            actor = bringHomeActor[index];
        } else {
            if (moveOutIds.length == 1) return;
            uint256 index = 1 + idSeed % (moveOutIds.length - 1);
            ticketId = moveOutIds[index];
            actor = moveOutActor[index];
        }
        try boundCompliance.sendSecondHalf(ticketId, satellites[actor]) { } catch { }
    }

    /// @notice The away token sends a stored receipt again, byte for byte.
    function liteResendsReceipt(uint256 idSeed, uint8 halfSeed) external virtual {
        (bool found, bytes32 ticketId) = _anyTicket(idSeed);
        if (!found) return;
        _resendReceipt(ticketId, halfSeed);
    }

    function relay(uint256 indexSeed) external virtual {
        callsRelay++;
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        uint256 index = indexSeed % length;
        ERC7786GatewayMock.QueuedMessage memory message = gateway.queuedMessage(index);
        if (message.deliveries != 0 || message.dropped) return;
        try gateway.relay(index) { } catch { }
    }

    function drop(uint256 indexSeed) public virtual {
        uint256 length = gateway.queueLength();
        if (length == 0) return;
        uint256 index = indexSeed % length;
        if (gateway.queuedMessage(index).deliveries == 0) gateway.drop(index);
    }

    /* ----- Invariants ----- */

    function invariant_DR1_positionsFollowTheWallets() public view {
        for (uint256 i = 0; i < ACTORS; i++) {
            assertEq(
                ledger.positionOf(address(identities[i])),
                token.balanceOf(actors[i]) + token.awayBalanceOf(satellites[i]) + _onHoldFor(i),
                "DR-1"
            );
        }
    }

    function invariant_DR2_positionsSumToTheSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < ACTORS; i++) {
            sum += ledger.positionOf(address(identities[i]));
        }
        assertEq(sum, token.totalSupply(), "DR-2");
    }

    function invariant_DR3_awayMatchesTheAwayTokenPlusWhatIsInFlight() public view {
        uint256 liteBalances;
        uint256 inFlight;
        for (uint256 i = 0; i < ACTORS; i++) {
            liteBalances += lite.balanceOf(satellites[i]);
            inFlight += _inFlightFor(i);
        }
        assertEq(token.totalAwayBalance(), liteBalances + inFlight, "DR-3");
    }

    function invariant_DR4_theAwayTokenMintedEachMoveOutOnce() public view {
        uint256 minted;
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            if (_mintedOnTheAwayToken(moveOutIds[i])) minted += moveOutAmount[i];
        }
        assertEq(lite.mints(), minted, "DR-4");
    }

    function invariant_DR5_awayIsWhatMovedOutLessWhatCameHome() public view {
        uint256 movedOut;
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            movedOut += moveOutAmount[i];
        }
        uint256 cameHome;
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            ITickets.Ticket memory ticket = boundCompliance.ticketOf(bringHomeIds[i]);
            if (ticket.status == ITickets.TicketStatus.Done) cameHome += ticket.moved;
        }
        assertEq(token.totalAwayBalance(), movedOut - cameHome, "DR-5");
    }

    function invariant_DR6_anHonestAwayTokenNeverBlocksItsChainOrStopsTheToken() public view {
        assertFalse(token.paused(), "DR-6");
        assertFalse(boundCompliance.isAwayChainBlocked(polygon), "DR-6");
    }

    function invariant_callSummary() public view {
        console.log("move out calls / landed:", callsMoveOut, moveOutIds.length - 1);
        console.log("bring home calls / landed:", callsBringHome, bringHomeIds.length - 1);
        console.log("sends again, relays:", callsSendAgain, callsRelay);
    }

    /* ----- Internal ----- */

    /// @dev Sends the stored receipt of one half of `ticketId` again; a half never answered sends nothing.
    function _resendReceipt(bytes32 ticketId, uint8 halfSeed) internal virtual {
        uint8 latestHalf = boundCompliance.ticketOf(ticketId).half;
        if (latestHalf == 0) return;
        uint8 half = 1 + halfSeed % latestHalf;
        try lite.resendReceipt(ticketId, half) { } catch { }
    }

    /// @dev A move out or a bring home picked by `idSeed`.
    function _anyTicket(uint256 idSeed) internal view returns (bool found, bytes32 ticketId) {
        uint256 moveOuts = moveOutIds.length - 1;
        uint256 count = moveOuts + bringHomeIds.length - 1;
        if (count == 0) return (false, bytes32(0));
        uint256 index = idSeed % count;
        if (index < moveOuts) return (true, moveOutIds[1 + index]);
        return (true, bringHomeIds[1 + index - moveOuts]);
    }

    /// @dev Whether the away token minted one of the halves of the move out `ticketId`.
    function _mintedOnTheAwayToken(bytes32 ticketId) internal view returns (bool) {
        uint8 latestHalf = boundCompliance.ticketOf(ticketId).half;
        for (uint8 half = 1; half <= latestHalf; half++) {
            MessageTypesLib.ReceiptMessage memory receipt = lite.storedReceipt(ticketId, half);
            bool minted = receipt.answer == MessageTypesLib.ReceiptAnswer.Executed && receipt.amount != 0;
            if (minted) return true;
        }
        return false;
    }

    /// @dev What the away token burned for the bring home `ticketId`, while home has not applied its receipt yet.
    function _burnedNotApplied(bytes32 ticketId) internal view returns (uint256 burned) {
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        if (ticket.status == ITickets.TicketStatus.Done) return 0;
        for (uint8 half = 1; half <= ticket.half; half++) {
            MessageTypesLib.ReceiptMessage memory receipt = lite.storedReceipt(ticketId, half);
            if (receipt.answer == MessageTypesLib.ReceiptAnswer.Executed) burned += receipt.amount;
        }
    }

    /// @dev What actor `actor` has in flight: move outs not minted on the away token yet, and burns done on the away
    ///  token whose receipt home has not applied.
    function _inFlightFor(uint256 actor) internal view returns (uint256 held) {
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            bool notMinted = !_mintedOnTheAwayToken(moveOutIds[i]);
            if (moveOutActor[i] == actor && notMinted) held += moveOutAmount[i];
        }
        for (uint256 i = 1; i < bringHomeIds.length; i++) {
            if (bringHomeActor[i] == actor) held += _burnedNotApplied(bringHomeIds[i]);
        }
    }

    /// @dev The money home holds between two halves for actor `actor`'s move outs.
    function _onHoldFor(uint256 actor) internal view returns (uint256 held) {
        for (uint256 i = 1; i < moveOutIds.length; i++) {
            if (moveOutActor[i] == actor) held += token.onHoldOf(moveOutIds[i]);
        }
    }

}

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

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { IToken } from "contracts/token/IToken.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { CappedRecipientModule, RecordingModule } from "test/integration/mocks/CapabilityModules.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A cross-chain validation through the real messaging layer: the burn leg from one chain, the mint leg
///      from another, in either order; the first one pins, the second one settles; and everything a stuck or
///      misbehaving Lite can send in between.
contract CrossChainSettlementTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    CappedRecipientModule internal cappedRule;
    bytes internal aliceSat;
    bytes internal bobOptimism;
    uint256 internal issuedAt;
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        cappedRule = CappedRecipientModule(
            address(
                new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
            )
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(cappedRule));
        vm.prank(agent);
        token.unpause();

        issuedAt = block.timestamp;
        id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        assertTrue(boundCompliance.ticketOf(id).twoLegs);
    }

    // ==== happy path Tests ====

    /// @notice The burn leg pins and takes the amount out of the sender's position into transit; the mint leg
    ///         settles the pair by crediting the recipient from the hold.
    function test_handleSettlement_Success_WhenBurnThenMint() public {
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95));

        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HeldInTransit(keccak256(aliceSat), id, aliceSat, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationLegConfirmed(id, polygon, 95);
        polygonGateway.relay(burn);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.AwaitingMint));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 95, "the burned amount left the sender's position");
        assertEq(token.onHoldOf(id), 95, "and waits in transit");
        assertEq(token.totalOnHold(), 95);
        assertEq(token.awayBalanceOf(bobOptimism), 0);
        assertEq(token.totalAwayBalance(), BALANCE, "still bridged");
        assertEq(token.totalSupply(), BALANCE, "still issued");
        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)),
            100,
            "still reserved at the maximum"
        );

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(aliceSat), keccak256(bobOptimism), id, aliceSat, bobOptimism, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, optimism, 95);
        optimismGateway.relay(mint);

        _assertSettledAt(95);
    }

    /// @notice Reordered delivery: the mint leg pins and holds nothing, the burn leg settles the pair atomically,
    ///         same ledger result.
    function test_handleSettlement_Success_WhenMintThenBurn() public {
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95));

        vm.expectCall(address(token), abi.encodeWithSelector(IToken.putOnHold.selector), 0);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationLegConfirmed(id, optimism, 95);
        optimismGateway.relay(mint);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.AwaitingBurn));
        ITickets.Ticket memory state = boundCompliance.ticketOf(id);
        assertEq(state.legWallet, bobOptimism);
        assertEq(token.awayBalanceOf(aliceSat), BALANCE, "a first mint leg moves nothing");
        assertEq(token.onHoldOf(id), 0);
        assertEq(token.awayBalanceOf(bobOptimism), 0);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptApplied(id, polygon, 95);
        polygonGateway.relay(burn);

        _assertSettledAt(95);
    }

    // ==== stuck mint Tests ====

    /// @notice A burn leg with no mint in sight: the validation is pinned, never `Expired`, never discardable.
    function test_discardExpiredValidations_RevertWhen_TheMintIsStuckAfterTheBurn() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        vm.warp(issuedAt + VALIDITY_WINDOW + OPTIMISM_WINDOW + 365 days);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.AwaitingMint));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.TicketNotCancellable.selector, id, uint8(ITickets.TicketStatus.AwaitingMint)
            )
        );
        boundCompliance.cancelTickets(ids);

        assertEq(
            IComplianceLedger(address(boundCompliance)).pendingInOf(address(bobIdentity)), 100, "the reservation stays"
        );
        assertEq(token.onHoldOf(id), 95, "the burned amount waits in transit");

        // The mint leg, however late, completes the pair.
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95)));
        _assertSettledAt(95);
    }

    /// @notice While the mint is in flight, the burned amount is out of the sender's reach: neither a new
    ///         validation nor a recall can be computed against tokens the satellite already burned.
    function test_holdInTransit_Success_WhenTheHeldAmountIsOutOfTheSendersReach() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));

        bytes32 next = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 1, BALANCE);
        assertEq(boundCompliance.ticketOf(next).amountMax, BALANCE - 95, "capped at what the wallet holds");

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, aliceSat, BALANCE - 95, BALANCE)
        );
        TokenLedgerHarness(address(token)).ledgerRecall(aliceSat, alice, BALANCE);
    }

    // ==== refusal Tests ====

    /// @notice Another burn leg under a consumed id, delivered as a fresh message, moves nothing and pauses the inbound of the chain
    ///         that sent it: the other chain's leg still lands and settles the pair, and the token is not paused.
    function test_handleSettlement_Success_WhenAConsumedLegIsReplayed() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        uint256 replay = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 96));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(id, polygon);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(polygon);
        polygonGateway.relay(replay);

        assertTrue(token.isInboundPaused(polygon));
        assertFalse(token.isInboundPaused(optimism));
        assertFalse(token.paused());
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.AwaitingMint));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - 95, "debited once");
        assertEq(token.onHoldOf(id), 95, "held once");

        uint256 blocked = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        polygonGateway.relay(blocked);
        assertFalse(token.messageReceived(address(polygonGateway), polygonGateway.receiveIdFor(blocked)));

        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95)));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        assertEq(token.awayBalanceOf(bobOptimism), 95);
    }

    /// @notice The two legs must carry one amount.
    function test_handleSettlement_RevertWhen_TheLegsDisagreeOnTheAmount() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 96));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementAmountMismatch.selector, id, 95, 96));
        optimismGateway.relay(mint);

        assertFalse(token.messageReceived(address(optimismGateway), optimismGateway.receiveIdFor(mint)));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.AwaitingMint));
        assertEq(token.awayBalanceOf(bobOptimism), 0);
    }

    /// @notice A burn leg can only come from the sender's chain, a mint leg only from the recipient's: each
    ///         misplaced leg is rejected, consumed, and pauses the inbound of the chain that executed it.
    function test_handleSettlement_Success_WhenALegComesFromTheWrongChainItIsRejected() public {
        uint256 burnFromOptimism = _liteSettles(optimismGateway, token, _burnLeg(id, token, aliceSat, 95));
        uint256 mintFromPolygon = _liteSettles(polygonGateway, token, _mintLeg(id, token, bobOptimism, 95));

        _relayRejected(optimismGateway, optimism, burnFromOptimism, 95);
        _relayRejected(polygonGateway, polygon, mintFromPolygon, 95);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE);
        assertEq(token.awayBalanceOf(bobOptimism), 0);
        assertEq(token.onHoldOf(id), 0);
    }

    /// @notice A notification carrying both wallets is no leg of a two-leg validation: it is rejected and the
    ///         chain that sent it is paused.
    function test_handleSettlement_Success_WhenBothWalletsAreFilledOnATwoLegValidationTheLegIsRejected() public {
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, aliceSat, bobOptimism, 95));

        _relayRejected(polygonGateway, polygon, index, 95);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE);
        assertEq(token.awayBalanceOf(bobOptimism), 0);
    }

    /// @notice The first leg is bounds-checked like any other: out of bounds it is rejected, holds nothing in
    ///         transit, and pauses the chain that executed it.
    function test_handleSettlement_Success_WhenTheFirstLegIsOutOfBoundsItIsRejected() public {
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 101));

        _relayRejected(polygonGateway, polygon, burn, 101);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(token.awayBalanceOf(aliceSat), BALANCE);
        assertEq(token.onHoldOf(id), 0);
    }

    /// @dev Relays a leg carrying the issued ask block hash that fails the substantive gate: it is rejected,
    ///  consumed, and pauses the inbound of `chainKey` while the token keeps running.
    function _relayRejected(ERC7786GatewayMock gateway, bytes32 chainKey, uint256 index, uint256 amount) private {
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReceiptRefused(id, chainKey, amount, boundCompliance.ticketOf(id).askBlockHash);
        vm.expectEmit(true, false, false, true, address(token));
        emit EventsLib.InboundPaused(chainKey);
        gateway.relay(index);

        assertTrue(token.messageReceived(address(gateway), gateway.receiveIdFor(index)), "the leg is consumed");
        assertTrue(token.isInboundPaused(chainKey), "the chain that executed it is paused");
        assertFalse(token.paused(), "the token keeps running");
    }

    function _assertSettledAt(uint256 amount) private view {
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITickets.TicketStatus.Done));
        ITickets.Ticket memory state = boundCompliance.ticketOf(id);
        assertEq(state.moved, amount);
        assertEq(token.awayBalanceOf(aliceSat), BALANCE - amount);
        assertEq(token.awayBalanceOf(bobOptimism), amount);
        assertEq(token.onHoldOf(id), 0, "nothing left in transit");
        assertEq(token.totalOnHold(), 0);
        assertEq(token.totalAwayBalance(), BALANCE);
        assertEq(token.totalSupply(), BALANCE);
        IComplianceLedger ledger = IComplianceLedger(address(boundCompliance));
        assertEq(ledger.pendingInOf(address(bobIdentity)), 0, "the reservation is released once settled");
        assertEq(ledger.positionOf(address(bobIdentity)), amount, "and became a position");
        assertFalse(token.paused());
    }

}

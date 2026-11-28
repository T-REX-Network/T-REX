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

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularComplianceBaseUnitTest } from "./helpers/ModularComplianceBaseUnitTest.t.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { MovementKindLib } from "contracts/compliance/modular/MovementKindLib.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { Token } from "contracts/token/Token.sol";
import {
    CappedRecipientModule,
    RecordingModule,
    RuleOnlyModule,
    WritingRuleModule
} from "test/integration/mocks/CapabilityModules.sol";
import { TokenReservationStub } from "test/unit/compliance/helpers/TokenReservationStub.sol";

/// @dev The issuance engine on a mocked token and registry: who may ask, what is refused before any write, how
///      the range is capped, what is recorded and what leaves toward which chain.
contract TicketsIssuanceUnitTest is ModularComplianceBaseUnitTest {

    uint256 internal constant POLYGON = 137;
    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant ARBITRUM = 42_161;
    uint64 internal constant TICKET_ROUTE_WINDOW = 15 minutes;
    /// @dev The window of a ticket on the receipt route: every ticket here, the mocked token has no ticket bridge.
    uint64 internal constant VALIDITY_WINDOW = 25 minutes;
    uint64 internal constant POLYGON_WINDOW = 95 minutes;
    uint64 internal constant OPTIMISM_WINDOW = 100 minutes;
    uint256 internal constant BRIDGED_BALANCE = 100;

    bytes32 internal polygon = _evmChainKey(POLYGON);
    bytes32 internal optimism = _evmChainKey(OPTIMISM);
    bytes32 internal arbitrum = _evmChainKey(ARBITRUM);
    bytes32 internal referenceChain;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal satelliteAlice = makeAddr("aliceOnPolygon");
    address internal satelliteBob = makeAddr("bobOnSatellites");
    address internal aliceIdentity = makeAddr("AliceIdentity");
    address internal bobIdentity = makeAddr("BobIdentity");

    bytes internal fromSat;
    bytes internal toSat;
    bytes internal toOptimism;
    bytes internal bobOnPolygonToo;
    bytes internal toArbitrum;
    bytes internal nativeAlice;
    bytes internal nativeBob;

    function setUp() public override {
        super.setUp();
        referenceChain = _evmChainKey(block.chainid);
        fromSat = InteroperableAddress.formatEvmV1(POLYGON, satelliteAlice);
        toSat = InteroperableAddress.formatEvmV1(POLYGON, satelliteBob);
        toOptimism = InteroperableAddress.formatEvmV1(OPTIMISM, satelliteBob);
        bobOnPolygonToo = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("bobOnPolygonToo"));
        toArbitrum = InteroperableAddress.formatEvmV1(ARBITRUM, satelliteBob);
        nativeAlice = InteroperableAddress.formatEvmV1(block.chainid, alice);
        nativeBob = InteroperableAddress.formatEvmV1(block.chainid, bob);

        mc.setWaitingTime(polygon, POLYGON_WINDOW);
        mc.setWaitingTime(optimism, OPTIMISM_WINDOW);

        vm.mockCall(token, abi.encodeWithSignature("identityRegistry()"), abi.encode(registry));
        // The wallet's room lives on the token now, and these tests are about it accumulating, so the mocked
        // token address gets a stub with real arithmetic. `vm.mockCall` still wins over etched code for the
        // selectors mocked below, so only the reservation calls actually reach the stub.
        vm.etch(token, address(new TokenReservationStub()).code);
        TokenReservationStub(token).setBridgedBalance(fromSat, BRIDGED_BALANCE);
        // The ask checks that its chains have an open receipt route with a peer.
        TokenReservationStub(token).setChainOpen(polygon, true);
        TokenReservationStub(token).setChainOpen(optimism, true);

        _bind(fromSat, aliceIdentity);
        _bind(toSat, bobIdentity);
        _bind(toOptimism, bobIdentity);
        _bind(bobOnPolygonToo, bobIdentity);
        _bind(toArbitrum, bobIdentity);
        _bind(nativeBob, bobIdentity);
    }

    modifier configured() {
        mc.setValidityWindows(TICKET_ROUTE_WINDOW, VALIDITY_WINDOW);
        mc.setAskLimits(
            ITickets.AskLimits({
                openTicketsPerIdentity: 100, asksPerIdentityPerWindow: 1000, askWindow: 1 days, smallestAmount: 1
            })
        );
        _;
    }

    // ==== authorization Tests ====

    function test_requestTransferValidation_Success_WhenCalledByTheIdentity() public configured {
        bytes32 salt = _salt();
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", salt);

        assertEq(id, _ticketId(fromSat, toSat, "", 10, 90, salt));
        assertEq(mc.ticketOf(id).fromIdentity, aliceIdentity);
    }

    function test_requestTransferValidation_Success_WhenCalledByAnAgent() public configured {
        vm.prank(agentAccount);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        assertEq(mc.ticketOf(id).fromIdentity, aliceIdentity);
    }

    function test_requestTransferValidation_RevertWhen_CallerIsAStranger() public configured {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, stranger, fromSat));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    /// @notice A satellite wallet's own address proves nothing on this chain.
    function test_requestTransferValidation_RevertWhen_SatelliteWalletCallsForItself() public configured {
        vm.prank(satelliteAlice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotAuthorizedForWallet.selector, satelliteAlice, fromSat));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    // ==== preconditions Tests ====

    function test_requestTransferValidation_RevertWhen_RangeIsInverted() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 20, 10));
        mc.askToMove(fromSat, toSat, 20, 10, "", _salt());
    }

    /// @notice A home wallet moves out by itself: the tokens are burned at home in the ask, so nobody else can
    ///         be named to execute it.
    function test_askToMove_reverts_when_aHomeSenderNamesASpender() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SpenderNotAllowed.selector, address(0), alice, address(0), 40));
        mc.askToMove(nativeAlice, toSat, 10, 40, spender, _salt());

        _assertNothingRecorded(nativeAlice, toSat, spender, 10, 40);
    }

    function test_askToMove_reverts_when_bothWalletsAreHomeWallets() public configured {
        vm.prank(alice);
        vm.expectRevert(ErrorsLib.NotACrossChainMove.selector);
        mc.askToMove(nativeAlice, nativeBob, 10, 40, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_SpenderIsNotCanonical() public configured {
        bytes memory padded = abi.encodePacked(toSat, hex"00");
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        mc.askToMove(fromSat, toSat, 10, 90, padded, _salt());

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, hex"deadbeef"));
        mc.askToMove(fromSat, toSat, 10, 90, hex"deadbeef", _salt());
    }

    function test_requestTransferValidation_RevertWhen_EnvelopeIsNotCanonical() public configured {
        bytes memory padded = abi.encodePacked(toSat, hex"00");
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        mc.askToMove(fromSat, padded, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_ValidityWindowIsNotSet() public {
        mc.setAskLimits(
            ITickets.AskLimits({
                openTicketsPerIdentity: 100, asksPerIdentityPerWindow: 1000, askWindow: 1 days, smallestAmount: 1
            })
        );
        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ValidityWindowNotSet.selector);
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    /// @notice The waiting time that counts is the sender's away chain's, which owes the receipt.
    function test_requestTransferValidation_RevertWhen_ReconciliationWindowIsNotSet() public configured {
        bytes memory fromArbitrum = InteroperableAddress.formatEvmV1(ARBITRUM, satelliteAlice);
        _bind(fromArbitrum, aliceIdentity);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WaitingTimeNotSet.selector, arbitrum));
        mc.askToMove(fromArbitrum, toArbitrum, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_FromChainIsPaused() public configured {
        mc.blockAwayChain(polygon);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AwayChainBlocked.selector, polygon));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    /// @notice A move between two away chains is done in two halves: the ticket goes to the sender's chain only,
    ///         and home sends the second half once the first is done.
    function test_askToMove_sendsTheTicketToTheSendersChainOnly_whenTheReceiverIsOnAnotherAwayChain()
        public
        configured
    {
        TokenReservationStub(token).setChainOpen(optimism, true);
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toOptimism, 10, 90, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.fromChainKey, polygon, "the ticket is the sender's chain's");
        assertEq(record.toChainKey, optimism, "the receiver's chain waits for the second half");
        assertEq(TokenReservationStub(token).lastReceiptRouteChainKey(), polygon, "sent to the sender's chain");
        assertEq(TokenReservationStub(token).receiptRouteSends(), 1, "one message only");
    }

    function test_requestTransferValidation_Success_AfterTheChainIsUnpaused() public configured {
        mc.blockAwayChain(polygon);
        mc.unblockAwayChain(polygon);

        bytes32 salt = _salt();
        vm.prank(aliceIdentity);
        assertEq(mc.askToMove(fromSat, toSat, 10, 90, "", salt), _ticketId(fromSat, toSat, "", 10, 90, salt));
    }

    // ==== eligibility Tests ====

    function test_requestTransferValidation_RevertWhen_FromIsUnbound() public configured {
        _bind(fromSat, address(0));

        vm.prank(agentAccount);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, fromSat));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_ToIsNotVerified() public configured {
        vm.mockCall(registry, abi.encodeWithSignature("isWalletVerified(bytes)", toSat), abi.encode(false));

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnverifiedWallet.selector, toSat));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    // ==== bounds Tests ====

    /// @notice The asked maximum must fit in the free balance, since the id is built from it: no narrowing to it.
    function test_askToMove_reverts_when_theRequestIsAboveTheFreeBalance() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, fromSat, BRIDGED_BALANCE, 110));
        mc.askToMove(fromSat, toSat, 90, 110, "", _salt());

        _assertNothingRecorded(fromSat, toSat, "", 90, 110);
    }

    function test_requestTransferValidation_Success_WhenTheRequestIsInsideTheBalance() public configured {
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 9, 11, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.amountMin, 9);
        assertEq(record.amountMax, 11);
    }

    function test_askToMove_reverts_when_theWholeRequestIsAboveTheBalance() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, fromSat, BRIDGED_BALANCE, 200));
        mc.askToMove(fromSat, toSat, 150, 200, "", _salt());

        _assertNothingRecorded(fromSat, toSat, "", 150, 200);
    }

    /// @notice A validation authorizing nothing is never issued: a zero maximum is below the smallest amount, and a
    ///         wallet holding nothing has nothing free to ask for.
    function test_requestTransferValidation_RevertWhen_TheMaximumIsZero() public configured {
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BelowMinimumAmount.selector, 0, 1));
        mc.askToMove(fromSat, toSat, 0, 0, "", _salt());

        TokenReservationStub(token).setBridgedBalance(fromSat, 0);
        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, fromSat, 0, 90));
        mc.askToMove(fromSat, toSat, 0, 90, "", _salt());

        _assertNothingRecorded(fromSat, toSat, "", 0, 90);
    }

    /// @notice Two wallets of one identity: issued, recorded, but no module consulted.
    function test_requestTransferValidation_Success_WhenBothWalletsBelongToOneIdentity() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(5);
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.amountMin, 10);
        assertEq(record.amountMax, 90);
        assertEq(record.fromIdentity, aliceIdentity);
        assertEq(record.toIdentity, aliceIdentity);
    }

    function test_requestTransferValidation_Success_WhenAModuleNarrowsTheMaximum() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(60);

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.amountMin, 10);
        assertEq(record.amountMax, 60);
        assertEq(record.fromIdentity, aliceIdentity);
        assertEq(record.toIdentity, bobIdentity);
    }

    function test_requestTransferValidation_Success_WhenTheSmallestAnswerWins() public configured {
        RecordingModule(_bindAllowedAmountModule()).setAllowedAmount(60);
        RecordingModule(_bindAllowedAmountModule()).setAllowedAmount(30);
        RecordingModule(_bindAllowedAmountModule()).setAllowedAmount(80);

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        assertEq(mc.ticketOf(id).amountMax, 30);
    }

    function test_requestTransferValidation_Success_WhenAModuleAnswersNoLimit() public configured {
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        assertEq(mc.ticketOf(id).amountMax, 90);
    }

    function test_requestTransferValidation_RevertWhen_AModuleEmptiesTheRange() public configured {
        address module = _bindAllowedAmountModule();
        RecordingModule(module).setAllowedAmount(5);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 5));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_AModuleRefuses() public configured {
        RecordingModule(_bindAllowedAmountModule()).setAllow(false);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 10, 0));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        vm.prank(aliceIdentity);
        vm.expectRevert(ErrorsLib.ZeroValue.selector);
        mc.askToMove(fromSat, toSat, 0, 90, "", _salt());
    }

    function test_requestTransferValidation_RevertWhen_AModuleWritesInAllowedAmount() public configured {
        address module = address(new WritingRuleModule());
        mc.addModule(module);

        vm.prank(aliceIdentity);
        vm.expectRevert();
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        assertEq(WritingRuleModule(module).writes(), 0);
        _assertNothingRecorded(fromSat, toSat, "", 10, 90);
    }

    /// @notice A named spender is carried on the wire for the satellite to enforce, not resolved here: a
    ///         spender policy is about who moves the tokens, and the satellite is where that call happens.
    ///         The envelope must still parse, which is what keeps an unusable one out of the record.
    function test_requestTransferValidation_Success_WhenTheSpenderIsUnknownHere() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, address(0));
        _bindAllowedAmountModule();

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, spender, _salt());

        assertEq(mc.ticketOf(id).amountMax, 90);
    }

    function test_requestTransferValidation_Success_WhenTheSpenderResolves() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, makeAddr("SpenderIdentity"));
        _bindAllowedAmountModule();

        bytes32 salt = _salt();
        vm.prank(aliceIdentity);
        assertEq(mc.askToMove(fromSat, toSat, 10, 90, spender, salt), _ticketId(fromSat, toSat, spender, 10, 90, salt));
    }

    /// @notice A rule capping the range sees who will execute it, as the spender modules do.
    function test_requestTransferValidation_Success_RulesAreAskedWithTheNamedSpender() public configured {
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, makeAddr("SpenderIdentity"));
        address module = _bindAllowedAmountModule();

        IModule.TransferContext memory expected;
        expected.compliance = address(mc);
        expected.fromIdentity = aliceIdentity;
        expected.toIdentity = bobIdentity;
        expected.fromWallet = keccak256(fromSat);
        expected.toWallet = keccak256(toSat);
        expected.amountMin = 10;
        expected.amountMax = 90;
        expected.kind = MovementKindLib.CROSS_CHAIN;
        expected.isIssuance = true;
        expected.spender = spender;
        expected.data = abi.encode(polygon);
        vm.expectCall(module, abi.encodeCall(IModule.checkTransfer, (expected)));

        vm.prank(aliceIdentity);
        mc.askToMove(fromSat, toSat, 10, 90, spender, _salt());
    }

    /* ----- The reservation ----- */

    function test_requestTransferValidation_Success_WhenReservingThePendingAmounts() public configured {
        _track();

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        assertFalse(mc.ticketOf(id).relocation, "reserved against the identities");
        assertEq(mc.pendingOutOf(aliceIdentity), 90);
        assertEq(mc.pendingInOf(bobIdentity), 90);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
        assertEq(mc.positionOf(aliceIdentity), BRIDGED_BALANCE);
        assertEq(mc.positionOf(bobIdentity), 0);
    }

    function test_requestTransferValidation_Success_WhenReservationsAccumulate() public configured {
        _track();

        vm.startPrank(aliceIdentity);
        mc.askToMove(fromSat, toSat, 10, 30, "", _salt());
        mc.askToMove(fromSat, bobOnPolygonToo, 10, 40, "", _salt());
        vm.stopPrank();

        assertEq(mc.pendingOutOf(aliceIdentity), 70);
        assertEq(mc.pendingInOf(bobIdentity), 70);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 70);
    }

    function test_requestTransferValidation_Success_WhenPendingOutOfTheWalletCapsTheNext() public configured {
        _track();

        vm.startPrank(aliceIdentity);
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());
        bytes32 second = mc.askToMove(fromSat, toSat, 5, BRIDGED_BALANCE - 90, "", _salt());
        vm.stopPrank();

        assertEq(mc.ticketOf(second).amountMax, BRIDGED_BALANCE - 90, "only what the first left free");
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 100);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.RequestAboveBalance.selector, fromSat, 0, 90));
        mc.askToMove(fromSat, toSat, 0, 90, "", _salt());
    }

    function test_requestTransferValidation_Success_WhenOneIdentityReservesNothing() public configured {
        _track();
        _bind(toSat, aliceIdentity);

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        // Nothing is reserved against the identity: relocating your own tokens changes no position, so it
        // must not eat your own room. The wallet's share is still written, because the wallet can only ever
        // send what it holds, whoever owns the far side.
        assertTrue(mc.ticketOf(id).relocation, "a relocation reserves nothing against the identity");
        assertEq(mc.pendingOutOf(aliceIdentity), 0);
        assertEq(mc.pendingInOf(aliceIdentity), 0);
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
    }

    /// @notice The wallet's share of a reservation is written on every issuance, whatever the identities do:
    ///         it is what stops a second validation drawing more than the wallet can cover.
    function test_requestTransferValidation_Success_WhenTheWalletShareIsAlwaysReserved() public configured {
        _track();

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        assertEq(uint8(mc.statusOf(id)), uint8(ITickets.TicketStatus.Open));
        assertEq(TokenReservationStub(token).reservedOf(fromSat), 90);
    }

    function test_requestTransferValidation_Success_WhenTwoValidationsRaceForOneCap() public configured {
        _track();
        address capped = _bindCappedModule(50);

        vm.startPrank(aliceIdentity);
        bytes32 first = mc.askToMove(fromSat, toSat, 10, 30, "", _salt());
        bytes32 second = mc.askToMove(fromSat, bobOnPolygonToo, 10, 70, "", _salt());
        vm.stopPrank();

        assertEq(mc.ticketOf(first).amountMax, 30);
        assertEq(mc.ticketOf(second).amountMax, 20, "the second sees the first as executed at its maximum");
        assertEq(CappedRecipientModule(capped).capOf(address(mc)), 50);

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.EmptyValidationRange.selector, 1, 0));
        mc.askToMove(fromSat, toSat, 1, 50, "", _salt());
    }

    /// @notice A rule that decides from positions binds anywhere, with nothing to set up first: the
    ///         compliance keeps every position from the token's first mint, so the numbers it reads always
    ///         exist. Under the previous design such a module had to be refused until tracking was enabled.
    function test_addModule_Success_WhenAReaderOfPositionsBinds() public configured {
        address module = _deployCappedModule();

        mc.addModule(module);

        assertTrue(mc.isModuleBound(module));
    }

    // ==== record, event and dispatch Tests ====

    /// @notice The id is a function of the request alone: the same request lands under the same id whatever
    ///         was issued before it.
    function test_requestTransferValidation_Success_WhenTheIdDependsOnTheRequestAlone() public configured {
        bytes32 salt = _salt();
        bytes32 expected = _ticketId(fromSat, toSat, "", 10, 30, salt);

        vm.startPrank(aliceIdentity);
        mc.askToMove(fromSat, toSat, 1, 5, "", _salt());
        mc.askToMove(fromSat, toSat, 1, 5, "", _salt());
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 30, "", salt);
        vm.stopPrank();

        assertEq(id, expected, "independent of the number of earlier issuances");
    }

    /// @notice The same request with the same salt is the same id: asked again, it is refused and the first
    ///         request stands.
    function test_askToMove_RevertWhen_TheSaltIsReused() public configured {
        bytes32 salt = _salt();
        vm.startPrank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 30, "", salt);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TicketAlreadyWritten.selector, id));
        mc.askToMove(fromSat, toSat, 10, 30, "", salt);
        vm.stopPrank();

        assertEq(mc.ticketOf(id).amountMax, 30, "the first request stands");
    }

    /// @notice The id covers the whole request: the same wallet and salt with another amount or another receiver
    ///         is another request, under another id, and is recorded beside the first.
    function test_askToMove_givesAnotherId_whenTheAmountOrTheReceiverDiffers() public configured {
        bytes32 salt = _salt();
        vm.startPrank(aliceIdentity);
        bytes32 first = mc.askToMove(fromSat, toSat, 10, 20, "", salt);
        bytes32 otherMaximum = mc.askToMove(fromSat, toSat, 10, 21, "", salt);
        bytes32 otherMinimum = mc.askToMove(fromSat, toSat, 11, 20, "", salt);
        bytes32 otherReceiver = mc.askToMove(fromSat, bobOnPolygonToo, 10, 20, "", salt);
        vm.stopPrank();

        assertTrue(first != otherMaximum, "another maximum, another id");
        assertTrue(first != otherMinimum, "another minimum, another id");
        assertTrue(first != otherReceiver, "another receiver, another id");
        assertEq(otherMaximum, _ticketId(fromSat, toSat, "", 10, 21, salt), "the id of the second request");
        assertEq(mc.ticketOf(first).amountMax, 20, "the first request stands");
        assertEq(mc.ticketOf(otherMaximum).amountMax, 21, "the second request is recorded");
    }

    /// @notice A reorg drops the block of an ask and the same request is mined again one block later: the id is
    ///         the same, and the ask block hash, which names the copy, is not.
    function test_askToMove_givesTheSameId_whenTheSameRequestIsMinedInAnotherBlock() public configured {
        bytes32 salt = _salt();
        uint256 snapshot = vm.snapshotState();
        vm.prank(aliceIdentity);
        bytes32 idInTheFirstBlock = mc.askToMove(fromSat, toSat, 10, 90, "", salt);
        bytes32 firstCopy = mc.ticketOf(idInTheFirstBlock).askBlockHash;

        vm.revertToState(snapshot);
        vm.roll(block.number + 1);
        vm.prank(aliceIdentity);
        bytes32 idInTheNextBlock = mc.askToMove(fromSat, toSat, 10, 90, "", salt);

        assertEq(idInTheNextBlock, idInTheFirstBlock, "same request, same id");
        assertTrue(mc.ticketOf(idInTheNextBlock).askBlockHash != firstCopy, "another block, another copy");
    }

    /// @notice The ask block hash is built from the ask's block and the terms home sent: the block number, the
    ///         hash of the block before, the narrowed maximum and the valid until.
    function test_askToMove_recordsAnAskBlockHashThatChangesWithTheTerms() public configured {
        vm.warp(1_700_000_000);
        uint64 validUntil = 1_700_000_000 + VALIDITY_WINDOW;
        uint256 narrowedMax = BRIDGED_BALANCE;
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, BRIDGED_BALANCE, "", _salt());

        bytes32 expected = keccak256(abi.encode(block.number, blockhash(block.number - 1), narrowedMax, validUntil));
        assertEq(mc.ticketOf(id).askBlockHash, expected, "the ask block hash of the copy sent");
        assertEq(mc.ticketOf(id).amountMax, narrowedMax, "the maximum home sent");
        assertEq(mc.ticketOf(id).requestedMax, BRIDGED_BALANCE, "the asked maximum is kept");

        bytes32 otherMaximum = keccak256(abi.encode(block.number, blockhash(block.number - 1), 99, validUntil));
        bytes32 otherValidUntil =
            keccak256(abi.encode(block.number, blockhash(block.number - 1), narrowedMax, validUntil + 1));
        assertTrue(expected != otherMaximum, "another maximum, another ask block hash");
        assertTrue(expected != otherValidUntil, "another valid until, another ask block hash");
    }

    /// @notice A holder's move and an agent's bring home asked with the same wallet and salt never share an id.
    function test_ticketId_differsBetweenAMoveAndABringHome_withTheSameWalletAndSalt() public {
        bytes32 salt = _salt();
        bytes32 fromKey = WalletKeyLib.canonicalKey(fromSat);
        bytes32 toKey = WalletKeyLib.canonicalKey(nativeAlice);
        bytes32 noSpender = bytes32(0);

        bytes32 moveId = TicketLib.ticketIdOf(ITickets.TicketKind.MOVE, fromKey, toKey, noSpender, 0, 50, salt);
        bytes32 bringHomeId =
            TicketLib.ticketIdOf(ITickets.TicketKind.BRING_HOME, fromKey, toKey, noSpender, 0, 50, salt);

        assertTrue(moveId != bringHomeId, "the kind is in the id");
    }

    /// @notice With no spender the spender key in the id is zero, so the away token computes the id from the ticket
    ///         without hashing an empty envelope.
    function test_askToMove_buildsTheIdWithAZeroSpenderKey_whenThereIsNoSpender() public configured {
        bytes32 salt = _salt();
        uint256 requestedMin = 10;
        uint256 requestedMax = 40;
        bytes32 noSpender = bytes32(0);
        bytes32 expected = keccak256(
            abi.encode(
                ITickets.TicketKind.MOVE,
                WalletKeyLib.canonicalKey(fromSat),
                WalletKeyLib.canonicalKey(toSat),
                noSpender,
                requestedMin,
                requestedMax,
                salt
            )
        );

        vm.prank(aliceIdentity);
        bytes32 ticketId = mc.askToMove(fromSat, toSat, requestedMin, requestedMax, "", salt);

        assertEq(ticketId, expected, "the id names no spender with a zero key");
    }

    function test_requestTransferValidation_Success_WhenIdsFollowTheSaltAndNeverRepeat() public configured {
        bytes32 saltA = _salt();
        bytes32 saltB = _salt();
        vm.startPrank(aliceIdentity);
        bytes32 first = mc.askToMove(fromSat, toSat, 10, 40, "", saltA);
        bytes32 second = mc.askToMove(fromSat, toSat, 10, 40, "", saltB);
        vm.stopPrank();

        assertEq(first, _ticketId(fromSat, toSat, "", 10, 40, saltA));
        assertEq(second, _ticketId(fromSat, toSat, "", 10, 40, saltB));
        assertTrue(first != second);
    }

    function test_requestTransferValidation_Success_WhenSnapshottingTheDeadlines() public configured {
        vm.warp(1_700_000_000);

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.validUntil, 1_700_000_000 + VALIDITY_WINDOW);
        assertEq(record.stopWaitingAt, 1_700_000_000 + VALIDITY_WINDOW + 4 * POLYGON_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, polygon);

        // A later change of the waiting time never moves the time home stops waiting, fixed at the ask.
        mc.setWaitingTime(polygon, 2 hours);
        assertEq(mc.ticketOf(id).stopWaitingAt, 1_700_000_000 + VALIDITY_WINDOW + 4 * POLYGON_WINDOW);
    }

    /// @notice A ticket's waiting time is the sender's away chain's: that chain owes its receipt.
    function test_requestTransferValidation_Success_WhenCrossChainTakesTheLargerWindow() public configured {
        vm.warp(1_700_000_000);

        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, nativeBob, 10, 40, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.stopWaitingAt, record.validUntil + 4 * POLYGON_WINDOW);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, referenceChain);
    }

    function test_requestTransferValidation_Success_WhenTheNativeRecipientKeepsTheReferenceKey() public configured {
        vm.prank(aliceIdentity);
        bytes32 id = mc.askToMove(fromSat, nativeBob, 10, 40, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(id);
        assertEq(record.fromChainKey, polygon);
        assertEq(record.toChainKey, referenceChain);
        assertEq(record.fromKey, WalletKeyLib.canonicalKey(fromSat));
        assertEq(record.toKey, WalletKeyLib.canonicalKey(nativeBob));
    }

    function test_requestTransferValidation_Success_WhenRecordingTheWalletKeysAndTheLegCount() public configured {
        vm.prank(aliceIdentity);
        bytes32 sameChain = mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        ITickets.Ticket memory record = mc.ticketOf(sameChain);
        assertEq(record.fromKey, WalletKeyLib.canonicalKey(fromSat));
        assertEq(record.toKey, WalletKeyLib.canonicalKey(toSat));
    }

    function test_requestTransferValidation_Success_WhenTheEventAndRecordMatchTheObject() public configured {
        vm.warp(1_700_000_000);
        bytes memory spender = InteroperableAddress.formatEvmV1(POLYGON, makeAddr("spender"));
        _bind(spender, makeAddr("SpenderIdentity"));
        bytes32 salt = _salt();
        bytes32 id = _ticketId(fromSat, toSat, spender, 10, 90, salt);
        MessageTypesLib.TicketMessage memory expected = _expected(id, salt, fromSat, toSat, spender, 10, 90);

        vm.expectEmit(true, false, false, true, address(mc));
        emit EventsLib.TicketWritten(
            id, fromSat, toSat, spender, 10, 90, 90, expected.validUntil, expected.askBlockHash, salt
        );
        vm.prank(aliceIdentity);
        mc.askToMove(fromSat, toSat, 10, 90, spender, salt);

        assertEq(mc.ticketOf(id).askBlockHash, expected.askBlockHash);
        assertEq(mc.ticketOf(id).requestedMax, 90);
    }

    function test_requestTransferValidation_Success_WhenDispatchingOneLegForASameChainMovement() public configured {
        vm.warp(1_700_000_000);
        bytes32 salt = _salt();
        bytes32 id = _ticketId(fromSat, toSat, "", 10, 90, salt);
        MessageTypesLib.TicketMessage memory expected = _expected(id, salt, fromSat, toSat, "", 10, 90);

        vm.expectCall(
            token,
            abi.encodeCall(
                Token.sendOnReceiptRoute, (polygon, id, MessageTypesLib.Message.TICKET, abi.encode(expected))
            ),
            1
        );
        vm.expectCall(token, abi.encodeWithSelector(Token.sendOnReceiptRoute.selector), 1);
        vm.prank(aliceIdentity);
        mc.askToMove(fromSat, toSat, 10, 90, "", salt);
    }

    function test_requestTransferValidation_Success_WhenDispatchingToTheSatelliteSideOnly() public configured {
        bytes32 salt = _salt();
        bytes32 id = _ticketId(fromSat, nativeBob, "", 10, 40, salt);
        vm.expectCall(token, abi.encodeWithSelector(Token.sendOnReceiptRoute.selector, polygon, id), 1);
        vm.expectCall(token, abi.encodeWithSelector(Token.sendOnReceiptRoute.selector), 1);
        vm.prank(aliceIdentity);
        mc.askToMove(fromSat, nativeBob, 10, 40, "", salt);
    }

    /// @notice A dispatch the token refuses reverts the whole request, nothing recorded.
    function test_requestTransferValidation_RevertWhen_TheTokenRefusesTheDispatch() public configured {
        vm.mockCallRevert(
            token,
            abi.encodeWithSelector(Token.sendOnReceiptRoute.selector),
            abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon)
        );

        vm.prank(aliceIdentity);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ChainNotOpen.selector, polygon));
        mc.askToMove(fromSat, toSat, 10, 90, "", _salt());

        _assertNothingRecorded(fromSat, toSat, "", 10, 90);
    }

    function _expected(
        bytes32 id,
        bytes32 salt,
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 min,
        uint256 max
    ) private view returns (MessageTypesLib.TicketMessage memory) {
        uint64 validUntil = uint64(block.timestamp) + VALIDITY_WINDOW;
        return MessageTypesLib.TicketMessage({
            ticketId: id,
            kind: uint8(ITickets.TicketKind.MOVE),
            salt: salt,
            from: from,
            to: to,
            spender: spender,
            amountMin: min,
            amountMax: max,
            requestedMax: max,
            token: token,
            validUntil: validUntil,
            askBlockHash: TicketLib.askBlockHashOf(max, validUntil)
        });
    }

    function _bind(bytes memory wallet, address identity) private {
        vm.mockCall(registry, abi.encodeWithSignature("resolveIdentity(bytes)", wallet), abi.encode(identity));
        vm.mockCall(
            registry, abi.encodeWithSignature("isWalletVerified(bytes)", wallet), abi.encode(identity != address(0))
        );
    }

    function _bindAllowedAmountModule() private returns (address module) {
        module = address(new ModuleProxy(address(new RuleOnlyModule()), abi.encodeCall(RecordingModule.initialize, ())));
        mc.addModule(module);
    }

    function _deployCappedModule() private returns (address module) {
        module = address(
            new ModuleProxy(address(new CappedRecipientModule()), abi.encodeCall(RecordingModule.initialize, ()))
        );
    }

    function _bindCappedModule(uint256 cap) private returns (address module) {
        module = _deployCappedModule();
        mc.addModule(module);
        mc.callModuleFunction(abi.encodeCall(CappedRecipientModule.setCap, (cap)), module);
    }

    /// @dev Gives alice's identity the position her satellite wallet holds, the way a real deployment does:
    ///  through the token's mint hook. The compliance keeps positions from the token's first mint, so there
    ///  is nothing to turn on.
    function _track() private {
        address aliceNative = makeAddr("aliceNative");
        vm.mockCall(registry, abi.encodeWithSignature("identity(address)", aliceNative), abi.encode(aliceIdentity));
        vm.prank(token);
        mc.created(aliceNative, BRIDGED_BALANCE);
    }

    function _evmChainKey(uint256 chainId) private pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference,) =
            InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

}

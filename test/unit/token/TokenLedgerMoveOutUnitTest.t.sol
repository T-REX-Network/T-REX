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

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @notice The ledger of a home wallet's move out, driven through `TokenLedgerHarness.ledgerMoveOut`: the burn onto
///         hold and the landing on the away wallet, the buckets and the envelope only. The ask, the rules and the away
///         chain's receipt belong to the compliance and are covered by the interop suites.
contract TokenLedgerMoveOutUnitTest is TokenLedgerBaseUnitTest {

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        token.freezePartialTokens(user1, 20);
        vm.stopPrank();
    }

    function test_ledgerMoveOut_MovesFreeBalanceToTheSatellite() public {
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 50);

        assertEq(token.balanceOf(user1), 50);
        assertEq(token.freeBalanceOf(user1), 30);
        assertEq(token.getFrozenTokens(user1), 20);
        assertEq(token.awayBalanceOf(satellite1), 50);
        assertEq(token.totalAwayBalance(), 50);
        assertEq(token.totalSupply(), 100, "the supply never moves on a move out");
        _assertPartition();
    }

    function test_ledgerMoveOut_EmitsHeldInTransitThenTransferToZeroThenBridgedTransfer() public {
        bytes memory homeWallet = satelliteEnvelope(block.chainid, user1);
        bytes32 holdId = keccak256(abi.encode("ledger move out", user1, satellite1));
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.HeldInTransit(keccak256(homeWallet), holdId, homeWallet, 50);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(user1, address(0), 50);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(homeWallet), keccak256(satellite1), holdId, homeWallet, satellite1, 50);

        vm.prank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 50);
    }

    function test_ledgerMoveOut_TheWholeFreeBalance() public {
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 80);

        assertEq(token.freeBalanceOf(user1), 0);
        assertEq(token.getFrozenTokens(user1), 20);
        assertEq(token.balanceOf(user1), 20);
        assertEq(token.awayBalanceOf(satellite1), 80);
        _assertPartition();
    }

    function test_ledgerMoveOut_ZeroAmountSucceeds() public {
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 0);

        assertEq(token.balanceOf(user1), 100);
        assertEq(token.awayBalanceOf(satellite1), 0);
    }

    function test_ledgerMoveOut_AccumulatesOnTheSameSatellite() public {
        vm.startPrank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 30);
        ledger.ledgerMoveOut(user1, satellite1, 20);
        vm.stopPrank();

        assertEq(token.awayBalanceOf(satellite1), 50);
        assertEq(token.totalAwayBalance(), 50);
        _assertPartition();
    }

    function test_ledgerMoveOut_SpreadsOverSeveralChains() public {
        vm.startPrank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 30);
        ledger.ledgerMoveOut(user1, satellite3, 20);
        vm.stopPrank();

        assertEq(token.awayBalanceOf(satellite1), 30);
        assertEq(token.awayBalanceOf(satellite3), 20);
        assertEq(token.totalAwayBalance(), 50);
        assertEq(token.balanceOf(user1), 50);
        _assertPartition();
    }

    /// @dev The ledger owns the state, the flow owns the checks: no compliance hook fires on a transition.
    function test_ledgerMoveOut_DoesNotNotifyTheCompliance() public {
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.destroyed.selector), 0);
        vm.expectCall(compliance, abi.encodeWithSelector(IERC3643Compliance.transferred.selector), 0);
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 50);
    }

    function test_ledgerMoveOut_IsNotGatedByPause() public {
        vm.startPrank(agent);
        token.pause();
        ledger.ledgerMoveOut(user1, satellite1, 50);
        vm.stopPrank();

        assertEq(token.awayBalanceOf(satellite1), 50);
    }

    function test_ledgerMoveOut_IsNotGatedByAddressFreeze() public {
        vm.startPrank(agent);
        token.setAddressFrozen(user1, true);
        ledger.ledgerMoveOut(user1, satellite1, 50);
        vm.stopPrank();

        assertEq(token.awayBalanceOf(satellite1), 50);
    }

    function test_ledgerMoveOut_RevertWhen_FrozenTokensWouldMove() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 80, 90));
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, satellite1, 90);
    }

    function test_ledgerMoveOut_RevertWhen_HolderHasNothing() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user2, 0, 1));
        vm.prank(agent);
        ledger.ledgerMoveOut(user2, satellite2, 1);
    }

    function test_ledgerMoveOut_RevertWhen_WalletIsOnTheReferenceChain() public {
        bytes memory native = satelliteEnvelope(block.chainid, user1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, native));
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, native, 10);
    }

    function test_ledgerMoveOut_RevertWhen_EnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite1, hex"00");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        vm.prank(agent);
        ledger.ledgerMoveOut(user1, padded, 10);
    }

    function test_ledgerMoveOut_RevertWhen_HolderIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(agent);
        ledger.ledgerMoveOut(address(0), satellite1, 0);
    }

}

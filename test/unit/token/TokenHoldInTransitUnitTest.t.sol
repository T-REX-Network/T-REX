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

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @dev The in-transit hold: who may take it, what it moves, and how a settlement under the same id releases it.
contract TokenHoldInTransitUnitTest is TokenLedgerBaseUnitTest {

    bytes32 internal constant VALIDATION_ID = bytes32(uint256(7));

    function setUp() public override {
        super.setUp();
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.ledgerDelegateOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    // ==== caller Tests ====

    function test_holdInTransit_RevertWhen_CallerIsNotTheBoundCompliance() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);

        vm.prank(user1);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);
    }

    // ==== hold Tests ====

    function test_holdInTransit_Success_WhenTheBurnLegLands() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit EventsLib.HeldInTransit(keccak256(satellite1), VALIDATION_ID, satellite1, 30);
        vm.prank(compliance);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);

        assertEq(token.awayBalanceOf(satellite1), 30, "the wallet no longer holds it");
        assertEq(token.onHoldOf(VALIDATION_ID), 30, "the validation does");
        assertEq(token.totalOnHold(), 30);
        assertEq(token.totalAwayBalance(), 60, "still bridged");
        assertEq(token.totalSupply(), 100, "still issued");
        assertEq(token.balanceOf(user1), 40);
        _assertPartition();
    }

    function test_holdInTransit_Success_WhenTheWholePositionIsBurned() public {
        vm.prank(compliance);
        token.putOnHold(satellite1, 60, VALIDATION_ID, 0);

        assertEq(token.awayBalanceOf(satellite1), 0);
        assertEq(token.onHoldOf(VALIDATION_ID), 60);
        _assertPartition();
    }

    function test_holdInTransit_RevertWhen_TheSatelliteSenderHasNotEnoughBridged() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        token.putOnHold(satellite1, 61, VALIDATION_ID, 0);
    }

    function test_holdInTransit_RevertWhen_TheValidationAlreadyHolds() public {
        vm.startPrank(compliance);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAlreadyHeld.selector, VALIDATION_ID));
        token.putOnHold(satellite1, 10, VALIDATION_ID, 0);
        vm.stopPrank();

        assertEq(token.onHoldOf(VALIDATION_ID), 30, "held once");
    }

    function test_holdInTransit_RevertWhen_TheSenderIsNative() public {
        bytes memory nativeUser1 = satelliteEnvelope(block.chainid, user1);

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NotASatelliteWallet.selector, nativeUser1));
        token.putOnHold(nativeUser1, 10, VALIDATION_ID, 0);
    }

    // ==== release Tests ====

    function test_settleValidation_Success_WhenTheMintLegReleasesTheHold() public {
        vm.startPrank(compliance);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);

        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(
            keccak256(satellite1), keccak256(satellite3), VALIDATION_ID, satellite1, satellite3, 30
        );
        token.finishMove(satellite1, satellite3, 30, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.awayBalanceOf(satellite1), 30, "not debited twice");
        assertEq(token.awayBalanceOf(satellite3), 30, "credited from the hold");
        assertEq(token.onHoldOf(VALIDATION_ID), 0);
        assertEq(token.totalOnHold(), 0);
        assertEq(token.totalAwayBalance(), 60);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    function test_settleValidation_RevertWhen_TheSettledAmountIsNotTheHeldOne() public {
        vm.startPrank(compliance);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAmountMismatch.selector, VALIDATION_ID, 30, 31));
        token.finishMove(satellite1, satellite3, 31, VALIDATION_ID);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TransitAmountMismatch.selector, VALIDATION_ID, 30, 29));
        token.finishMove(satellite1, satellite3, 29, VALIDATION_ID);
        vm.stopPrank();

        assertEq(token.onHoldOf(VALIDATION_ID), 30, "still held");
    }

    function test_settleValidation_Success_WhenAnotherValidationSettlesBesideTheHold() public {
        vm.startPrank(compliance);
        token.putOnHold(satellite1, 30, VALIDATION_ID, 0);
        token.finishMove(satellite1, satellite2, 20, bytes32(uint256(VALIDATION_ID) + 1));
        vm.stopPrank();

        assertEq(token.awayBalanceOf(satellite1), 10, "the other one debits the wallet as usual");
        assertEq(token.awayBalanceOf(satellite2), 20);
        assertEq(token.onHoldOf(VALIDATION_ID), 30, "the hold is untouched");
        _assertPartition();
    }

}

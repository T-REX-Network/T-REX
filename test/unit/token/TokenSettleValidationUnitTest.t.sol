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

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import { TokenLedgerBaseUnitTest } from "./TokenLedgerBaseUnitTest.t.sol";

/// @dev The compliance-only ledger entry: who may call it, and which transition each wallet shape resolves to.
contract TokenSettleValidationUnitTest is TokenLedgerBaseUnitTest {

    bytes32 internal constant VALIDATION_ID = bytes32(uint256(7));

    bytes internal nativeUser1;
    bytes internal nativeUser2;

    function setUp() public override {
        super.setUp();
        nativeUser1 = satelliteEnvelope(block.chainid, user1);
        nativeUser2 = satelliteEnvelope(block.chainid, user2);
        vm.startPrank(agent);
        token.mint(user1, 100);
        ledger.ledgerMoveOut(user1, satellite1, 60);
        vm.stopPrank();
    }

    // ==== caller Tests ====

    function test_settleValidation_RevertWhen_CallerIsNotTheBoundCompliance() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.finishMove(satellite1, satellite2, 30, VALIDATION_ID);

        vm.prank(user1);
        vm.expectRevert(ErrorsLib.OnlyBoundCompliance.selector);
        token.finishMove(satellite1, satellite2, 30, VALIDATION_ID);
    }

    // ==== shape Tests ====

    function test_settleValidation_Success_WhenBothWalletsAreSatellites() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(
            keccak256(satellite1), keccak256(satellite2), VALIDATION_ID, satellite1, satellite2, 30
        );
        vm.prank(compliance);
        token.finishMove(satellite1, satellite2, 30, VALIDATION_ID);

        assertEq(token.awayBalanceOf(satellite1), 30);
        assertEq(token.awayBalanceOf(satellite2), 30);
        assertEq(token.balanceOf(user1), 40);
        assertEq(token.totalAwayBalance(), 60);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    function test_settleValidation_Success_WhenToIsNative() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), user2, 20);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.SettledToNative(keccak256(satellite1), user2, VALIDATION_ID, satellite1, 20);
        vm.prank(compliance);
        token.finishMove(satellite1, nativeUser2, 20, VALIDATION_ID);

        assertEq(token.balanceOf(user2), 20);
        assertEq(token.awayBalanceOf(satellite1), 40);
        assertEq(token.totalAwayBalance(), 40);
        assertEq(token.totalSupply(), 100);
        _assertPartition();
    }

    // ==== refusal Tests ====

    /// @notice The compliance never issues a validation out of a native wallet, and the ledger refuses one on
    ///         its own account: a settlement only ever debits a position a satellite held.
    /// @notice A home wallet holds no away balance: outside a hold of its own move out, nothing is taken from it.
    function test_settleValidation_RevertWhen_FromIsNative() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, nativeUser1, 0, 25));
        token.finishMove(nativeUser1, satellite2, 25, VALIDATION_ID);
    }

    function test_settleValidation_RevertWhen_TheSatelliteSenderHasNotEnoughBridged() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, satellite1, 60, 61));
        token.finishMove(satellite1, satellite2, 61, VALIDATION_ID);
    }

    function test_settleValidation_RevertWhen_AnEnvelopeIsNotCanonical() public {
        bytes memory padded = abi.encodePacked(satellite2, hex"00");

        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.NonCanonicalInteroperableAddress.selector, padded));
        token.finishMove(satellite1, padded, 10, VALIDATION_ID);
    }

    function test_settleValidation_RevertWhen_BothWalletsAreNative() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InsufficientBridgedBalance.selector, nativeUser1, 0, 10));
        token.finishMove(nativeUser1, nativeUser2, 10, VALIDATION_ID);
    }

}

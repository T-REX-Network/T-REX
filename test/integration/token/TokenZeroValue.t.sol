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

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

/// @notice A zero amount passes every transfer check, so it must also pass the compliance hooks and move nothing.
contract TokenZeroValueTest is TREXSuiteTest {

    IComplianceLedger public ledger;

    function setUp() public override {
        super.setUp();
        ledger = IComplianceLedger(address(token.compliance()));

        vm.startPrank(agent);
        token.mint(alice, 100);
        token.unpause();
        vm.stopPrank();
    }

    function test_transfer_Succeeds_WhenAmountIsZero() public {
        vm.prank(alice);
        token.transfer(bob, 0);

        _assertNothingMoved();
    }

    function test_transferFrom_Succeeds_WhenAmountIsZero() public {
        vm.prank(alice);
        token.approve(charlie, 10);

        vm.prank(charlie);
        token.transferFrom(alice, bob, 0);

        _assertNothingMoved();
        assertEq(token.allowance(alice, charlie), 10);
    }

    function test_mint_Succeeds_WhenAmountIsZero() public {
        vm.prank(agent);
        token.mint(bob, 0);

        _assertNothingMoved();
    }

    function test_burn_Succeeds_WhenAmountIsZero() public {
        vm.prank(agent);
        token.burn(alice, 0);

        _assertNothingMoved();
    }

    /// @notice A forced transfer reports to the compliance through `agentTransferred`, which takes a zero amount
    ///         like the other notifications, so a zero row cannot revert a whole `batchForcedTransfer`.
    function test_forcedTransfer_Succeeds_WhenAmountIsZero() public {
        vm.prank(agent);
        token.forcedTransfer(alice, bob, 0);

        _assertNothingMoved();
    }

    function _assertNothingMoved() internal view {
        assertEq(token.totalSupply(), 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(ledger.positionOf(address(aliceIdentity)), 100);
        assertEq(ledger.positionOf(address(bobIdentity)), 0);
    }

}

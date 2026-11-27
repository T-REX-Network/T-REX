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

import { Test } from "@forge-std/Test.sol";

import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { LinkerLib } from "scripts/deploy/lib/LinkerLib.sol";

/// @notice Library linking of the build's creation code.
contract LinkerLibTest is Test {

    function test_placeholdersAreTheOnesSolcWrote() public view {
        (string[9] memory names, string[9] memory fqn) = BytecodeStore.libraries();
        string memory token = BytecodeStore.unlinkedInitCodeHex("Token");
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(vm.contains(token, LinkerLib.placeholder(fqn[i])), names[i]);
        }
        string memory mc = BytecodeStore.unlinkedInitCodeHex("ModularCompliance");
        for (uint256 i = 4; i < 9; i++) {
            assertTrue(vm.contains(mc, LinkerLib.placeholder(fqn[i])), names[i]);
        }
    }

    function test_linksEveryPlaceholder() public view {
        address[9] memory libs;
        for (uint256 i = 0; i < 9; i++) {
            libs[i] = address(uint160(0xAAAA0000 + i));
        }
        bytes memory token = BytecodeStore.initCode("Token", libs);
        bytes memory tickets = BytecodeStore.initCode("TicketLib", libs);
        assertGt(token.length, 20_000);
        assertGt(tickets.length, 1000);
        // Each linked address appears in the code (PUSH20 <address> before each DELEGATECALL).
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(vm.contains(vm.toString(token), _hex(libs[i])), "library address missing from Token");
        }
        // TicketLib links the money on hold and the second halves.
        assertTrue(vm.contains(vm.toString(tickets), _hex(libs[4])), "SecondHalfLib missing from TicketLib");
        assertTrue(vm.contains(vm.toString(tickets), _hex(libs[5])), "HoldLib missing from TicketLib");
    }

    function test_refusesUnlinkedLeftovers() public {
        LinkerLib.Link[] memory none = new LinkerLib.Link[](0);
        string memory token = BytecodeStore.unlinkedInitCodeHex("Token");
        vm.expectRevert(bytes("LinkerLib: unlinked library placeholder left"));
        this.link(token, none);
    }

    function link(string calldata code, LinkerLib.Link[] calldata links) external pure returns (bytes memory) {
        return LinkerLib.link(code, links);
    }

    function _hex(address a) internal pure returns (string memory) {
        return vm.replace(vm.toLowercase(vm.toString(a)), "0x", "");
    }

}

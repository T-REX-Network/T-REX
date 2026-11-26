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
        (string[8] memory names, string[8] memory fqn) = BytecodeStore.libraries();
        string memory token = BytecodeStore.unlinkedInitCodeHex("Token");
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(vm.contains(token, LinkerLib.placeholder(fqn[i])), names[i]);
        }
        string memory mc = BytecodeStore.unlinkedInitCodeHex("ModularCompliance");
        assertTrue(vm.contains(mc, LinkerLib.placeholder(fqn[5])));
        assertTrue(vm.contains(mc, LinkerLib.placeholder(fqn[6])));
    }

    function test_linksEveryPlaceholder() public view {
        address[8] memory libs;
        for (uint256 i = 0; i < 8; i++) {
            libs[i] = address(uint160(0xAAAA0000 + i));
        }
        bytes memory token = BytecodeStore.initCode("Token", libs);
        bytes memory delegation = BytecodeStore.initCode("TokenDelegationLib", libs);
        assertGt(token.length, 20_000);
        assertGt(delegation.length, 1000);
        // Each linked address appears in the code (PUSH20 <address> before each DELEGATECALL).
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(vm.contains(vm.toString(token), _hex(libs[i])), "library address missing from Token");
        }
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

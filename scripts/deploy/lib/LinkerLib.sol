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

import { Vm } from "@forge-std/Vm.sol";

/// @title LinkerLib
/// @notice Links external libraries into creation code at script time.
/// @dev solc leaves a 40-character placeholder `__$<34 hex>$__` where a library address goes, the 34 hex digits
///      being the start of `keccak256("<source path>:<LibraryName>")`. Linking replaces each placeholder with the
///      library's address (40 hex digits, no 0x). Doing it here, rather than with `libraries = [...]` in
///      foundry.toml, keeps the test build unlinked and lets the committed bytecode stay salt-independent: the
///      library addresses come from the Genesis Deployer and the CREATE2 salt in the deployment config.
library LinkerLib {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Link {
        // Fully qualified name as solc hashes it, e.g. "contracts/token/TokenLedgerLib.sol:TokenLedgerLib".
        string fullyQualifiedName;
        address target;
    }

    /// @notice The placeholder solc writes for `fullyQualifiedName`.
    function placeholder(string memory fullyQualifiedName) internal pure returns (string memory) {
        bytes memory hexHash = bytes(VM.toString(keccak256(bytes(fullyQualifiedName))));
        bytes memory out = new bytes(40);
        out[0] = "_";
        out[1] = "_";
        out[2] = "$";
        for (uint256 i = 0; i < 34; i++) {
            out[3 + i] = hexHash[2 + i]; // skip "0x"
        }
        out[37] = "$";
        out[38] = "_";
        out[39] = "_";
        return string(out);
    }

    /// @notice Links `links` into `unlinkedHex` (with or without 0x) and returns the bytes.
    /// @dev Reverts if a placeholder is still present afterwards, so a missing library cannot slip through.
    function link(string memory unlinkedHex, Link[] memory links) internal pure returns (bytes memory) {
        string memory linked = unlinkedHex;
        for (uint256 i = 0; i < links.length; i++) {
            linked = VM.replace(linked, placeholder(links[i].fullyQualifiedName), _addressHex(links[i].target));
        }
        require(!VM.contains(linked, "__$"), "LinkerLib: unlinked library placeholder left");
        return VM.parseBytes(linked);
    }

    /// @dev Lowercase, no 0x, 40 digits.
    function _addressHex(address target) private pure returns (string memory) {
        bytes memory full = bytes(VM.toString(target));
        bytes memory out = new bytes(40);
        for (uint256 i = 0; i < 40; i++) {
            bytes1 c = full[2 + i];
            if (c >= "A" && c <= "F") c = bytes1(uint8(c) + 32);
            out[i] = c;
        }
        return string(out);
    }

}

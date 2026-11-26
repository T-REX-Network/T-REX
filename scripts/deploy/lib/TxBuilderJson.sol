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

import { Step } from "./PlanTypes.sol";

/// @title TxBuilderJson
/// @notice Writes a batch of calls as a Safe{Wallet} Transaction Builder file, for the Safe's owners to load,
///         review, sign and execute (Transaction Builder app, "drag and drop a JSON file").
/// @dev Shape: {version, chainId, createdAt, meta: {name, description, txBuilderVersion, createdFromSafeAddress,
///      createdFromOwnerAddress}, transactions: [{to, value, data, contractMethod, contractInputsValues}]}.
///      Raw calldata is given in `data` with `contractMethod` null, the form the Transaction Builder uses for custom
///      data. `meta.checksum` is left out; the Transaction Builder only warns when it is missing (unverified
///      against the current app version: check once in the UI before relying on it).
library TxBuilderJson {

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function render(uint256 chainId, address safe, string memory name, string memory description, Step[] memory steps)
        internal
        view
        returns (string memory json)
    {
        json = string.concat(
            "{\n  \"version\": \"1.0\",\n  \"chainId\": \"",
            VM.toString(chainId),
            "\",\n  \"createdAt\": ",
            VM.toString(block.timestamp * 1000),
            ",\n  \"meta\": {\n    \"name\": ",
            _quote(name),
            ",\n    \"description\": ",
            _quote(description),
            ",\n    \"txBuilderVersion\": \"1.16.5\",\n    \"createdFromSafeAddress\": \"",
            VM.toString(safe),
            "\",\n    \"createdFromOwnerAddress\": \"\"\n  },\n  \"transactions\": ["
        );
        for (uint256 i = 0; i < steps.length; i++) {
            json = string.concat(
                json,
                i == 0 ? "\n    {" : ",\n    {",
                "\n      \"to\": \"",
                VM.toString(steps[i].to),
                "\",\n      \"value\": \"",
                VM.toString(steps[i].value),
                "\",\n      \"data\": \"",
                VM.toString(steps[i].data),
                "\",\n      \"contractMethod\": null,\n      \"contractInputsValues\": null\n    }"
            );
        }
        json = string.concat(json, "\n  ]\n}\n");
    }

    function write(
        string memory path,
        uint256 chainId,
        address safe,
        string memory name,
        string memory description,
        Step[] memory steps
    ) internal {
        VM.writeFile(path, render(chainId, safe, name, description, steps));
    }

    /// @dev Names and descriptions come from step ids and fixed text: no quotes or backslashes to escape.
    function _quote(string memory s) private pure returns (string memory) {
        return string.concat("\"", s, "\"");
    }

}

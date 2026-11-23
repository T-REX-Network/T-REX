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

import { console } from "@forge-std/Script.sol";

import { DeployScriptBase } from "./DeployScriptBase.sol";
import { DeployConfig } from "./lib/DeployConfig.sol";

/// @title ConfigureAndHandover
/// @notice Configures the deployed protocol and hands it to the Safes, in OpenZeppelin's corrected order
///         (review pp. 23-24). Every step is sent by the Bootstrap Operator, ADMIN of both managers until the end.
/// @dev `configure` = steps 1 to 5:
///        1. role tables: ONCHAINID policies, module bundles, identity beacon, trusted verifier; function-to-role
///           mappings; labels; guardians;
///        2. operational roles while ADMIN is still their admin: contract-held ones (ASSET_DEPLOYER to the
///           TREXFactory, ROLE_MANAGER to the RoleRevoker) and the Operations Safe's, with their execution delays;
///        3. role admins (ROLE_MANAGER), so the Bootstrap Operator never needs ROLE_MANAGER;
///        4. the governance roles with their execution delays, effective at once since no grant delay is set yet;
///        5. grant delays and target admin delays, in force after the manager's 5-day minimum setback.
///      `finalize` = steps 6 and 7: refuses to run until every delay is in force and verification passes, then the
///      Bootstrap Operator renounces IdentityUtilities' roles, then ADMIN on both managers, last.
///        forge script scripts/deploy/ConfigureAndHandover.s.sol --sig "configure(string)" mainnet --rpc-url <rpc> --broadcast --sender <bootstrap>
///        forge script scripts/deploy/ConfigureAndHandover.s.sol --sig "finalize(string)" mainnet --rpc-url <rpc> --broadcast --sender <bootstrap>
contract ConfigureAndHandover is DeployScriptBase {

    function configure(string memory env) external {
        DeployConfig memory c = _loadPinned(env, true);
        require(_pendingCount(_protocolSteps(c)) == 0, "protocol not fully deployed: run DeployProtocol first");
        executorMode = Mode.Broadcast;
        _run(c, _configureSteps(c), "configure");
        _summary();
        console.log("Delays come into force in %s seconds; run finalize after that.", c.codeDelay);
    }

    /// @param fromBlock The block the deployment started at: every governance log since then is scanned (holders,
    ///        function mappings, IdentityUtilities grants) before anything is renounced. @param logSpan Blocks per
    ///        `eth_getLogs` request.
    function finalize(string memory env, uint256 fromBlock, uint256 logSpan) external {
        DeployConfig memory c = _loadPinned(env, true);
        string[] memory failures = _verify(c, true, false);
        if (failures.length > 0) {
            _printFailures(failures);
            revert("verification failed: not handing over (are the delays in force yet?)");
        }
        // Before renouncing, the Bootstrap Operator's own holdings are expected (and nothing else); after, the same
        // logs are checked again with no exemption, against the state the renounce steps leave.
        LogEntry[] memory logs = _provenGovernanceLogs(c, fromBlock, logSpan);
        _requireGovernanceAsPlanned(c, logs, true);
        executorMode = Mode.Broadcast;
        _run(c, _finalizeSteps(c), "finalize");
        _requireGovernanceAsPlanned(c, logs, false);
        failures = _verify(c, true, true);
        if (failures.length > 0) {
            _printFailures(failures);
            revert("handover incomplete");
        }
        _summary();
        console.log("Handover complete: the Bootstrap Operator holds no role.");
    }

    function status(string memory env) external view {
        DeployConfig memory c = _load(env);
        _printStatus(_configureSteps(c));
        _printStatus(_finalizeSteps(c));
    }

}

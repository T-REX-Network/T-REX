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

import { DeployScriptBase } from "./DeployScriptBase.sol";
import { DeployConfig } from "./lib/DeployConfig.sol";

/// @title DeployProtocol
/// @notice One idempotent plan for ONCHAINID, T-REX, the shared compliance modules and the UtilityChecker.
/// @dev Every library and implementation is CREATE2-deployed through the Genesis Deployer (broadcast from any key).
///      Every proxy, manager and factory is CREATE3-deployed with a salt bound to the Deployment Safe, so those
///      steps are written as Safe Transaction Builder batches under deployments/<env>/batches/; execute them in the
///      Safe and run the same command again to continue.
///        forge script scripts/deploy/DeployProtocol.s.sol --sig "status(string)" mainnet --rpc-url <rpc>
///        forge script scripts/deploy/DeployProtocol.s.sol --sig "run(string)" mainnet --rpc-url <rpc> --broadcast
///      `runLocal` sends the Safe steps itself (approveHash from each owner), for anvil with the owners' keys.
///      Expected code already present counts as done; anything else at an expected address stops the run.
contract DeployProtocol is DeployScriptBase {

    function run(string memory env) external {
        DeployConfig memory c = _loadPinned(env, true);
        _requireAnchor();
        executorMode = Mode.SafeBatches;
        _run(c, _protocolSteps(c), "protocol");
        _summary();
    }

    /// @notice Local rehearsal only: executes the Safe steps itself with the owners' keys, so it refuses any chain
    ///         but anvil's.
    function runLocal(string memory env) external {
        require(block.chainid == 31337, "runLocal runs on a local chain (31337) only");
        DeployConfig memory c = _load(env);
        _requireAnchor();
        executorMode = Mode.Broadcast;
        _run(c, _protocolSteps(c), "protocol");
        _summary();
    }

    function status(string memory env) external view {
        _printStatus(_protocolSteps(_load(env)));
    }

}

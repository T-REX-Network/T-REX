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

/// @title VerifyDeployment
/// @notice Read-only verification of a deployment against its config: addresses and code, initialized proxies,
///         role tables, delays, beacon owners, and no Bootstrap Operator role left. Writes
///         deployments/<env>/verification.json and reverts when anything fails.
/// @dev   forge script scripts/deploy/VerifyDeployment.s.sol --sig "run(string)" mainnet --rpc-url <rpc>
///      `beforeHandover` accepts scheduled (not yet in force) delays and a Bootstrap Operator still in place.
///      `scanGovernance(env, fromBlock, logSpan)` reads every grant and function mapping since `fromBlock`:
///      AccessManager cannot list members, so this catches any holder or mapping the role tables do not plan.
contract VerifyDeployment is DeployScriptBase {

    function run(string memory env) external {
        _report(env, true, true);
    }

    /// @notice As {run}, after proxy or identity beacon upgrades: the listed implementations are accepted on top of
    ///         the deployed release; any other implementation fails.
    function run(string memory env, address[] memory upgradedImplementations) external {
        acceptedImplementations = upgradedImplementations;
        _report(env, true, true);
    }

    function beforeHandover(string memory env) external {
        _report(env, false, false);
    }

    function _report(string memory env, bool delaysInForce, bool afterHandover) internal {
        DeployConfig memory c = _loadPinned(env, true);
        string[] memory failures = _verify(c, delaysInForce, afterHandover);
        string memory dir = string.concat("deployments/", env);
        vm.createDir(dir, true);
        string memory key = "verification";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "block", block.number);
        vm.serializeBool(key, "delaysInForce", delaysInForce);
        vm.serializeBool(key, "afterHandover", afterHandover);
        string memory json = vm.serializeString(key, "failures", failures);
        vm.writeJson(json, string.concat(dir, "/verification.json"));
        _printFailures(failures);
        require(failures.length == 0, "deployment does not match its config");
    }

    /// @notice Scans every `RoleGranted` on both managers since `fromBlock` and fails on any grant still held that
    ///         the role tables do not plan, the Bootstrap Operator's included (step 6: every role holder).
    /// @notice Step 6, every role holder and mapping: scans the governance logs since `fromBlock` (in requests of
    ///         `logSpan` blocks) and fails on any holder, pending grant, function mapping or IdentityUtilities grant the
    ///         role tables do not plan.
    function scanGovernance(string memory env, uint256 fromBlock, uint256 logSpan) external {
        DeployConfig memory c = _loadPinned(env, true);
        _requireGovernanceAsPlanned(c, _provenGovernanceLogs(c, fromBlock, logSpan), false);
    }

}

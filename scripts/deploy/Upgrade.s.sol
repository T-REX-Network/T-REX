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
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { DeployScriptBase } from "./DeployScriptBase.sol";
import { DeployConfig } from "./lib/DeployConfig.sol";
import { Step } from "./lib/PlanTypes.sol";
import { Version } from "contracts/libraries/VersionLib.sol";

/// @title Upgrade
/// @notice Publishes a release and moves every suite to it through the Upgrade Council Safe; rolls back; lets the
///         guardian cancel; upgrades the UUPS proxies (compliance modules, UtilityChecker, IdentityUtilities).
/// @dev A release is the current checkout's build, published under its own CREATE2 salt. Versions are
///      major.minor.patch and must always increase. Every entry first checks that the build still gives the
///      governance rows of deploy/addresses/<env>.json (managers, authority, Safes): an upgrade must talk to the
///      deployed contracts.
///        publish  (anyone, broadcast):   --sig "publish(string,bytes32)" mainnet <salt>
///        schedule (Council, Safe batch): --sig "schedule(string,bytes32,uint8,uint8,uint8)" mainnet <salt> 5 1 0
///        execute  (Council, after the code delay, within a week): same arguments, "execute(...)"
///        cancel   (guardian, Safe batch): same arguments, "cancel(...)"
///      A rollback never rebuilds an older release: it reads the implementations the authority recorded under the
///      previous version and republishes them under a higher one. `scheduleWithRollback` writes the upgrade and its
///      rollback in one batch; `cancelWithRollback` cancels both; `executeRollback` runs a scheduled rollback.
///      `dryRun` runs publish, schedule, the wait and execute on a fork with pranked Safe owners and warped time.
contract Upgrade is DeployScriptBase {

    function _published(DeployConfig memory c, bytes32 salt) internal view {
        require(_pendingCount(_publishSteps(c, salt)) == 0, "release not published under this salt: run publish first");
    }

    function publish(string memory env, bytes32 salt) external {
        DeployConfig memory c = _loadPinned(env, false);
        executorMode = Mode.Broadcast;
        _run(c, _publishSteps(c, salt), "publish");
        _summary();
    }

    function schedule(string memory env, bytes32 salt, uint8 major, uint8 minor, uint8 patch) external {
        DeployConfig memory c = _loadPinned(env, false);
        _published(c, salt);
        executorMode = Mode.SafeBatches;
        _run(c, _one(_scheduleSuiteUpgrade(c, salt, _version(major, minor, patch))), "upgrade-schedule");
        _summary();
    }

    /// @param version The upgrade's version. @param previousVersion The version to roll back to, as the authority
    ///        recorded it. @param rollbackVersion The higher version the rollback republishes it under.
    function scheduleWithRollback(
        string memory env,
        bytes32 salt,
        uint8[3] memory version,
        uint8[3] memory previousVersion,
        uint8[3] memory rollbackVersion
    ) external {
        DeployConfig memory c = _loadPinned(env, false);
        _published(c, salt);
        executorMode = Mode.SafeBatches;
        Step[] memory steps = _two(
            _scheduleSuiteUpgrade(c, salt, _v(version)), _scheduleRollback(c, _v(previousVersion), _v(rollbackVersion))
        );
        _run(c, steps, "upgrade-schedule-with-rollback");
        _summary();
    }

    function execute(string memory env, bytes32 salt, uint8 major, uint8 minor, uint8 patch) external {
        DeployConfig memory c = _loadPinned(env, false);
        _published(c, salt);
        executorMode = Mode.SafeBatches;
        _run(c, _one(_executeSuiteUpgrade(c, salt, _version(major, minor, patch))), "upgrade-execute");
        _summary();
    }

    function executeRollback(string memory env, uint8[3] memory previousVersion, uint8[3] memory rollbackVersion)
        external
    {
        DeployConfig memory c = _loadPinned(env, false);
        executorMode = Mode.SafeBatches;
        _run(c, _one(_executeRollback(c, _v(previousVersion), _v(rollbackVersion))), "rollback-execute");
        _summary();
    }

    /// @notice Guardian veto (Protocol Admin Safe): cancels a scheduled suite upgrade. Written as a Safe batch.
    function cancel(string memory env, bytes32 salt, uint8 major, uint8 minor, uint8 patch) external {
        DeployConfig memory c = _loadPinned(env, false);
        Step[] memory steps = _one(_cancelSuiteUpgrade(c, salt, _version(major, minor, patch)));
        _requireAllScheduled(steps);
        executorMode = Mode.SafeBatches;
        _run(c, steps, "upgrade-cancel");
        _summary();
    }

    /// @notice Guardian veto by operation id, on either manager: caller, target and call data come from the
    ///         manager's `OperationScheduled` log, so it works whatever build the guardian has checked out. The ids
    ///         are in the Council's batch output or the logs (`OperationScheduled.operationId`).
    function cancelScheduled(string memory env, bytes32[] memory operationIds, uint256 fromBlock, uint256 logSpan)
        external
    {
        DeployConfig memory c = _loadPinned(env, false);
        Addrs memory a = _addresses(c);
        LogEntry[] memory platform =
            _fetchLogs(a.platformAM, IAccessManager.OperationScheduled.selector, fromBlock, logSpan);
        LogEntry[] memory upgrade =
            _fetchLogs(a.upgradeAM, IAccessManager.OperationScheduled.selector, fromBlock, logSpan);
        Step[] memory steps = new Step[](operationIds.length);
        for (uint256 i = 0; i < operationIds.length; i++) {
            steps[i] = _cancelFromScheduledLog(_scheduledLog(operationIds[i], platform, upgrade));
        }
        _requireAllScheduled(steps);
        executorMode = Mode.SafeBatches;
        _run(c, steps, "cancel-scheduled");
        _summary();
    }

    /// @dev The most recent OperationScheduled log for `id` (an id is reused when an operation is rescheduled).
    function _scheduledLog(bytes32 id, LogEntry[] memory platform, LogEntry[] memory upgrade)
        internal
        pure
        returns (LogEntry memory found)
    {
        bool seen;
        for (uint256 i = 0; i < platform.length; i++) {
            if (platform[i].topics[1] == id) (found, seen) = (platform[i], true);
        }
        for (uint256 i = 0; i < upgrade.length; i++) {
            if (upgrade[i].topics[1] == id) (found, seen) = (upgrade[i], true);
        }
        require(seen, string.concat("no OperationScheduled log for ", vm.toString(id)));
    }

    /// @notice Guardian veto of an upgrade scheduled with its rollback: cancels both in one Safe batch, so a vetoed
    ///         upgrade never leaves its rollback pending (the linked-cancellation risk in OpenZeppelin's review).
    ///         Same arguments as {scheduleWithRollback}.
    function cancelWithRollback(
        string memory env,
        bytes32 salt,
        uint8[3] memory version,
        uint8[3] memory previousVersion,
        uint8[3] memory rollbackVersion
    ) external {
        DeployConfig memory c = _loadPinned(env, false);
        executorMode = Mode.SafeBatches;
        Step[] memory steps = _two(
            _cancelSuiteUpgrade(c, salt, _v(version)), _cancelRollback(c, _v(previousVersion), _v(rollbackVersion))
        );
        // Both or nothing: cancelling only the rollback would leave the upgrade pending.
        _requireAllScheduled(steps);
        _run(c, steps, "upgrade-cancel-with-rollback");
        _summary();
    }

    function scheduleProxyUpgrade(string memory env, address proxy, address newImplementation) external {
        DeployConfig memory c = _loadPinned(env, false);
        require(newImplementation.code.length > 0, "new implementation has no code: publish it first");
        executorMode = Mode.SafeBatches;
        _run(c, _one(_proxyUpgradeStep(c, proxy, newImplementation, false)), "proxy-upgrade-schedule");
        _summary();
    }

    function executeProxyUpgrade(string memory env, address proxy, address newImplementation) external {
        DeployConfig memory c = _loadPinned(env, false);
        require(newImplementation.code.length > 0, "new implementation has no code: publish it first");
        executorMode = Mode.SafeBatches;
        _run(c, _one(_proxyUpgradeStep(c, proxy, newImplementation, true)), "proxy-upgrade-execute");
        _summary();
    }

    /// @notice The whole suite upgrade on a fork, nothing broadcast: publish, schedule, wait, execute, verify.
    function dryRun(string memory env, bytes32 salt, uint8 major, uint8 minor, uint8 patch) external {
        DeployConfig memory c = _loadPinned(env, false);
        executorMode = Mode.InTest;
        Version v = _version(major, minor, patch);
        _run(c, _publishSteps(c, salt), "publish");
        _run(c, _one(_scheduleSuiteUpgrade(c, salt, v)), "schedule");
        vm.warp(block.timestamp + c.codeDelay + 1);
        _run(c, _one(_executeSuiteUpgrade(c, salt, v)), "execute");
        string[] memory failures = _verify(c, true, true);
        _printFailures(failures);
        require(failures.length == 0, "dry run: verification failed after the upgrade");
        console.log("Dry run passed: largest step %s gas (%s)", maxStepGas, maxStepGasId);
    }

    function _v(uint8[3] memory v) internal pure returns (Version) {
        return _version(v[0], v[1], v[2]);
    }

}

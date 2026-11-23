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

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { Version, VersionLib } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";

import { DeploymentVerifier } from "./DeploymentVerifier.sol";
import { IUUPS } from "./PlanBuilder.sol";
import { DeployConfig } from "./lib/DeployConfig.sol";
import { Actor, Probes, Step } from "./lib/PlanTypes.sol";

/// @title UpgradePlanner
/// @notice Steps for publishing a release, scheduling and executing a suite upgrade, rolling it back, cancelling,
///         and upgrading the UUPS proxies, all through the Upgrade Council Safe and the Upgrade AccessManager.
/// @dev How an upgrade runs:
///      1. publish: the current build's libraries and implementations are CREATE2-deployed through the Genesis
///         Deployer under a new salt (anyone may send; the addresses commit to the code).
///      2. schedule: the Upgrade Council Safe calls `upgradeAM.schedule(authority, publishAndUpgrade(v, impls), 0)`.
///         Its VERSION_MANAGER grant carries the code delay, so the operation can only run after it. The Protocol
///         Admin Safe, as guardian, can cancel it meanwhile.
///      3. execute: once the delay has passed (and within the manager's one-week expiry), the Council calls
///         `upgradeAM.execute(authority, publishAndUpgrade(v, impls))`.
///      A new release always comes from the current checkout's build. A rollback never rebuilds an older release:
///      it reads the previous implementations from the chain (`implementationsFor(previousVersion)`) and republishes
///      them under a new, higher version, through the same delay. It can be scheduled together with the upgrade,
///      the standing-authorization trade-off OpenZeppelin's review describes.
abstract contract UpgradePlanner is DeploymentVerifier {

    /// @notice The addresses the current build gets under CREATE2 salt `salt`; CREATE3 addresses are unchanged.
    function _releaseAddresses(DeployConfig memory c, bytes32 salt) internal view returns (Addrs memory) {
        // Through the planner: the config crosses as calldata and comes back as a fresh copy, so `c` itself is left
        // untouched (`DeployConfig memory r = c` would only copy the reference).
        return _engine().planReleaseAddresses(c, salt);
    }

    /// @notice CREATE2 steps that deploy the current build's libraries and implementations under `salt`.
    function _publishSteps(DeployConfig memory c, bytes32 salt) internal view returns (Step[] memory) {
        return _engine().planPublishSteps(c, salt);
    }

    function _upgradeCall(Addrs memory target, Version version) internal pure returns (bytes memory) {
        return _upgradeCallFor(_suiteImplementations(target), version);
    }

    function _upgradeCallFor(ITREXImplementationAuthority.SuiteImplementations memory impls, Version version)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(ITREXImplementationAuthority.publishAndUpgrade, (version, impls));
    }

    /// @notice The upgrade to the build published under `salt`, as `version`.
    function _suiteUpgradeCall(DeployConfig memory c, bytes32 salt, Version version)
        internal
        view
        returns (bytes memory)
    {
        return _upgradeCall(_releaseAddresses(c, salt), version);
    }

    /// @notice The rollback to the implementations the authority recorded under `previousVersion`, republished as
    ///         `rollbackVersion`. Read from the chain, so an older release never has to be rebuilt.
    function _rollbackCall(DeployConfig memory c, Version previousVersion, Version rollbackVersion)
        internal
        view
        returns (bytes memory)
    {
        ITREXImplementationAuthority ia = ITREXImplementationAuthority(_addresses(c).implementationAuthority);
        ITREXImplementationAuthority.SuiteImplementations memory previous = ia.implementationsFor(previousVersion);
        require(previous.tokenImplementation != address(0), "UpgradePlanner: previous version not recorded");
        return _upgradeCallFor(previous, rollbackVersion);
    }

    /// @notice The Upgrade Council's schedule step for an authority call (an upgrade or a rollback).
    function _scheduleStep(DeployConfig memory c, bytes memory call, string memory id)
        internal
        view
        returns (Step memory)
    {
        Addrs memory a = _addresses(c);
        return Step(
            string.concat("schedule.", id),
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            0,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, call, 0)),
            Probes.nonZero(
                a.upgradeAM,
                abi.encodeCall(
                    IAccessManager.getSchedule,
                    (IAccessManager(a.upgradeAM).hashOperation(a.upgradeCouncilSafe, a.implementationAuthority, call))
                )
            )
        );
    }

    /// @notice The Upgrade Council's execute step for an authority call scheduled by {_scheduleStep}.
    function _executeStep(DeployConfig memory c, bytes memory call, Version version, string memory id)
        internal
        view
        returns (Step memory)
    {
        Addrs memory a = _addresses(c);
        return Step(
            string.concat("execute.", id),
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            0,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, call)),
            Probes.state(
                a.implementationAuthority,
                abi.encodeCall(ITREXImplementationAuthority.currentVersion, ()),
                abi.encode(version)
            )
        );
    }

    /// @notice The guardian's veto: the Protocol Admin Safe cancels a scheduled authority call. Done once nothing is
    ///         scheduled for that operation any more.
    function _cancelStep(DeployConfig memory c, bytes memory call, string memory id)
        internal
        view
        returns (Step memory)
    {
        Addrs memory a = _addresses(c);
        bytes32 op = IAccessManager(a.upgradeAM).hashOperation(a.upgradeCouncilSafe, a.implementationAuthority, call);
        return Step(
            string.concat("cancel.", id),
            Actor.ProtocolAdminSafe,
            a.upgradeAM,
            0,
            abi.encodeCall(IAccessManager.cancel, (a.upgradeCouncilSafe, a.implementationAuthority, call)),
            Probes.state(a.upgradeAM, abi.encodeCall(IAccessManager.getSchedule, (op)), abi.encode(uint48(0)))
        );
    }

    /// @notice The guardian's veto built from the manager's own `OperationScheduled` log: caller, target and call data
    ///         are taken from the log, so the guardian never needs the Council's exact build. Works for operations on
    ///         either manager.
    function _cancelFromScheduledLog(LogEntry memory log) internal pure returns (Step memory) {
        require(
            log.topics.length >= 3 && log.topics[0] == IAccessManager.OperationScheduled.selector,
            "UpgradePlanner: not an OperationScheduled log"
        );
        (, address caller, address target, bytes memory data) = abi.decode(log.data, (uint48, address, address, bytes));
        return Step(
            string.concat("cancel.operation.", vm.toString(log.topics[1])),
            Actor.ProtocolAdminSafe,
            log.emitter,
            0,
            abi.encodeCall(IAccessManager.cancel, (caller, target, data)),
            Probes.state(
                log.emitter, abi.encodeCall(IAccessManager.getSchedule, (log.topics[1])), abi.encode(uint48(0))
            )
        );
    }

    /// @notice Reverts unless every cancel step still has an operation to cancel. A cancel built from a different
    ///         build than the Council's computes another operation id, finds nothing scheduled and would otherwise
    ///         "succeed" without vetoing anything.
    function _requireAllScheduled(Step[] memory cancels) internal view {
        require(
            _pendingCount(cancels) == cancels.length,
            "nothing scheduled for this operation from this build: veto it by id with cancelScheduled(env, ids, fromBlock, logSpan)"
        );
    }

    function _upgradeId(Version version) internal pure returns (string memory) {
        return string.concat("suiteUpgrade.", _u(Version.unwrap(version)));
    }

    function _rollbackId(Version version) internal pure returns (string memory) {
        return string.concat("rollback.", _u(Version.unwrap(version)));
    }

    function _scheduleSuiteUpgrade(DeployConfig memory c, bytes32 salt, Version version)
        internal
        view
        returns (Step memory)
    {
        return _scheduleStep(c, _suiteUpgradeCall(c, salt, version), _upgradeId(version));
    }

    function _executeSuiteUpgrade(DeployConfig memory c, bytes32 salt, Version version)
        internal
        view
        returns (Step memory)
    {
        return _executeStep(c, _suiteUpgradeCall(c, salt, version), version, _upgradeId(version));
    }

    function _cancelSuiteUpgrade(DeployConfig memory c, bytes32 salt, Version version)
        internal
        view
        returns (Step memory)
    {
        return _cancelStep(c, _suiteUpgradeCall(c, salt, version), _upgradeId(version));
    }

    function _scheduleRollback(DeployConfig memory c, Version previousVersion, Version rollbackVersion)
        internal
        view
        returns (Step memory)
    {
        return _scheduleStep(c, _rollbackCall(c, previousVersion, rollbackVersion), _rollbackId(rollbackVersion));
    }

    function _executeRollback(DeployConfig memory c, Version previousVersion, Version rollbackVersion)
        internal
        view
        returns (Step memory)
    {
        return _executeStep(
            c, _rollbackCall(c, previousVersion, rollbackVersion), rollbackVersion, _rollbackId(rollbackVersion)
        );
    }

    function _cancelRollback(DeployConfig memory c, Version previousVersion, Version rollbackVersion)
        internal
        view
        returns (Step memory)
    {
        return _cancelStep(c, _rollbackCall(c, previousVersion, rollbackVersion), _rollbackId(rollbackVersion));
    }

    /// @notice Schedule (or execute) step upgrading one of the UUPS proxies the Upgrade manager governs.
    /// @param proxy A module proxy, the UtilityChecker or the IdentityUtilities.
    function _proxyUpgradeStep(DeployConfig memory c, address proxy, address newImplementation, bool execute)
        internal
        view
        returns (Step memory)
    {
        Addrs memory a = _addresses(c);
        bytes memory call = abi.encodeCall(IUUPS.upgradeToAndCall, (newImplementation, ""));
        if (!execute) {
            return Step(
                "schedule.proxyUpgrade",
                Actor.UpgradeCouncilSafe,
                a.upgradeAM,
                0,
                abi.encodeCall(IAccessManager.schedule, (proxy, call, 0)),
                Probes.nonZero(
                    a.upgradeAM,
                    abi.encodeCall(
                        IAccessManager.getSchedule,
                        (IAccessManager(a.upgradeAM).hashOperation(a.upgradeCouncilSafe, proxy, call))
                    )
                )
            );
        }
        return Step(
            "execute.proxyUpgrade",
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            0,
            abi.encodeCall(IAccessManager.execute, (proxy, call)),
            Probes.slotEquals(proxy, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(newImplementation))))
        );
    }

    function _version(uint8 major, uint8 minor, uint8 patch) internal pure returns (Version) {
        return VersionLib.pack(major, minor, patch);
    }

    function _one(Step memory s) internal pure returns (Step[] memory out) {
        out = new Step[](1);
        out[0] = s;
    }

    function _two(Step memory s, Step memory t) internal pure returns (Step[] memory out) {
        out = new Step[](2);
        out[0] = s;
        out[1] = t;
    }

}

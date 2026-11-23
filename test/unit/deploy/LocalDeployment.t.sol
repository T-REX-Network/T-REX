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

import { Test, Vm } from "@forge-std/Test.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { RoleRevoker } from "scripts/deploy/RoleRevoker.sol";

import { Version } from "contracts/libraries/VersionLib.sol";
import { UpgradePlanner } from "scripts/deploy/UpgradePlanner.sol";
import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { DeployConfig, DeployConfigLib } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor, Probes, Step } from "scripts/deploy/lib/PlanTypes.sol";
import { RoleTable } from "scripts/deploy/lib/RoleTable.sol";

/// @notice The whole deployment on a fresh local chain, through the real Safes: genesis, protocol, configuration,
///         the five-day wait, the handover. No RPC needed, so plain `forge test` exercises the tooling.
/// @dev A local chain has neither the anchor nor the Safe Singleton Factory; both are etched from the vendored
///      runtime (the same 69 bytes as on every chain that has them). Everything else is deployed by the plan.
contract LocalDeploymentTest is Test, UpgradePlanner {

    function setUp() public {
        _requireOnchainidBuild();
        executorMode = Mode.InTest;
        bytes memory factory = BytecodeStore.create2FactoryRuntime();
        vm.etch(BytecodeStore.ANCHOR, factory);
        vm.etch(BytecodeStore.SAFE_SINGLETON_FACTORY, factory);
    }

    /// @dev The ONCHAINID contracts deploy from the via_ir build in out-onchainid/, which `forge test` does not
    ///      produce. Locally the suite skips with the command to run; CI sets TREX_REQUIRE_DEPLOY_TESTS=true, which
    ///      turns the skip into a failure so these tests can never be skipped silently there.
    function _requireOnchainidBuild() internal {
        if (BytecodeStore.onchainidBuilt()) return;
        string memory why =
            string.concat("ONCHAINID artifacts missing in out-onchainid/: run ", BytecodeStore.ONCHAINID_BUILD);
        if (vm.envOr("TREX_REQUIRE_DEPLOY_TESTS", false)) revert(why);
        emit log_string(string.concat("skipping the local deployment tests. ", why));
        vm.skip(true);
    }

    function _config() internal view returns (DeployConfig memory) {
        return DeployConfigLib.load("local");
    }

    function _deployAndConfigure(DeployConfig memory c) internal {
        assertTrue(_run(c, _genesisSteps(c), "genesis"), "genesis");
        assertTrue(_run(c, _protocolSteps(c), "protocol"), "protocol");
        assertTrue(_run(c, _configureSteps(c), "configure"), "configure");
    }

    function test_fullDeploymentHandsOverToTheSafes() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);

        // Everything in place, delays scheduled but not in force yet.
        _assertNoFailures(_verify(c, false, false));
        assertGt(_verify(c, true, false).length, 0, "delays cannot be in force before the setback");

        vm.warp(block.timestamp + c.codeDelay + 1);
        _assertNoFailures(_verify(c, true, false));

        assertTrue(_run(c, _finalizeSteps(c), "finalize"), "finalize");
        _assertNoFailures(_verify(c, true, true));
        assertLt(maxStepGas, TX_GAS_CAP, "a step needs more than the EIP-7825 cap");
    }

    function test_rerunSendsNothing() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        uint256 sent = stepsSent;
        _run(c, _genesisSteps(c), "genesis");
        _run(c, _protocolSteps(c), "protocol");
        assertEq(stepsSent, sent, "a second genesis and protocol run sent transactions");
        assertEq(_pendingCount(_genesisSteps(c)) + _pendingCount(_protocolSteps(c)), 0);
    }

    function test_addressTableMatchesWhatWasDeployed() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        Addrs memory a = _addresses(c);
        // Spot checks against the chain; every row is covered by the verifier through the step probes.
        assertGt(a.genesis.code.length, 0, "genesis deployer");
        assertGt(a.deploymentSafe.code.length, 0, "deployment safe");
        assertGt(a.trexFactory.code.length, 0, "factory");
        assertGt(a.identityBeacon.code.length, 0, "identity beacon");
        assertGt(a.utilityChecker.code.length, 0, "utility checker proxy");
        assertGt(a.utilityCheckerDeployer.code.length, 0, "deployer stub (CreateX requires code)");
        for (uint256 i = 0; i < 5; i++) {
            assertGt(a.suiteBeacons[i].code.length, 0, "suite beacon");
        }
    }

    /// @dev The real flow: Safe steps are written as Transaction Builder files, the Safe executes them, the script
    ///      runs again and carries on. Each file is executed here exactly as its JSON says, through the real Safe.
    function test_safeBatchesThenResume() public {
        DeployConfig memory c = _config();
        _run(c, _genesisSteps(c), "genesis");
        Addrs memory a = _addresses(c);
        executorMode = Mode.SafeBatches;
        uint256 rounds;
        while (!_run(c, _protocolSteps(c), "protocol-test")) {
            assertLt(++rounds, 10, "batches never finish");
            for (uint256 f = 0; f < batchFiles.length; f++) {
                _executeBatchFile(c, a.deploymentSafe, batchFiles[f]);
            }
            delete batchFiles;
        }
        assertGt(rounds, 0, "the CREATE3 steps must go through batches");
        assertEq(_pendingCount(_protocolSteps(c)), 0);
    }

    function _executeBatchFile(DeployConfig memory c, address safe, string memory file) internal {
        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), safe);
        assertEq(vm.parseJsonString(json, ".chainId"), vm.toString(block.chainid));
        uint256 count;
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(count), "]"))) {
            count++;
        }
        assertGt(count, 0, "empty batch");
        Mode saved = executorMode;
        executorMode = Mode.InTest;
        for (uint256 i = 0; i < count; i++) {
            string memory key = string.concat(".transactions[", vm.toString(i), "]");
            Step memory step;
            step.id = string.concat(file, "#", vm.toString(i));
            step.actor = Actor.DeploymentSafe;
            step.to = vm.parseJsonAddress(json, string.concat(key, ".to"));
            step.value = vm.parseUint(vm.parseJsonString(json, string.concat(key, ".value")));
            step.data = vm.parseJsonBytes(json, string.concat(key, ".data"));
            _execThroughSafe(c.deploymentSafe, safe, step);
        }
        executorMode = saved;
    }

    /// @dev The executor reads pending delays straight from AccessManager storage; check the layout it assumes.
    function test_pendingDelayStorageLayout() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        Addrs memory a = _addresses(c);
        assertEq(_pendingGrantDelay(a.platformAM, RoleTable.versionManager()), c.codeDelay, "pending grant delay");
        assertEq(IAccessManager(a.platformAM).getRoleGrantDelay(RoleTable.versionManager()), 0, "not in force yet");
        assertEq(_pendingTargetAdminDelay(a.upgradeAM, a.implementationAuthority), c.codeDelay, "pending admin delay");
        vm.warp(block.timestamp + c.codeDelay + 1);
        assertEq(IAccessManager(a.platformAM).getRoleGrantDelay(RoleTable.versionManager()), c.codeDelay);
        assertEq(IAccessManager(a.upgradeAM).getTargetAdminDelay(a.implementationAuthority), c.codeDelay);
        assertEq(_pendingGrantDelay(a.platformAM, RoleTable.versionManager()), c.codeDelay, "value after the change");
    }

    function _handOver(DeployConfig memory c) internal {
        vm.warp(block.timestamp + c.codeDelay + 1);
        assertTrue(_run(c, _finalizeSteps(c), "finalize"), "finalize");
    }

    function _fromSafe(DeployConfig memory c, Actor actor, address to, bytes memory data) internal {
        _execThroughSafe(
            _safeConfigOf(c, actor), _safeOf(_addresses(c), actor), Step("safe call", actor, to, 0, data, Probes.none())
        );
    }

    function _operationalRoles() internal pure returns (uint64[] memory roles) {
        roles = new uint64[](6);
        roles[0] = RoleTable.tokenIssuer();
        roles[1] = RoleTable.interopManager();
        roles[2] = RoleTable.reputationManager();
        roles[3] = RoleTable.claimIssuerAdmin();
        roles[4] = RoleTable.issuer();
        roles[5] = RoleTable.publicAuthority();
    }

    /// @dev OpenZeppelin's order: the operational roles are granted before ROLE_MANAGER administers them, so the
    ///      Bootstrap Operator never holds ROLE_MANAGER, at any point.
    function test_bootstrapNeverHoldsRoleManager() public {
        DeployConfig memory c = _config();
        _run(c, _genesisSteps(c), "genesis");
        _run(c, _protocolSteps(c), "protocol");
        Addrs memory a = _addresses(c);
        vm.recordLogs();
        _run(c, _configureSteps(c), "configure");
        (bool held,) = IAccessManager(a.platformAM).hasRole(RoleTable.roleManager(), c.bootstrap);
        assertFalse(held, "bootstrap holds ROLE_MANAGER");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != a.platformAM || logs[i].topics[0] != IAccessManager.RoleGranted.selector) continue;
            bool bootstrapRoleManager = uint64(uint256(logs[i].topics[1])) == RoleTable.roleManager()
                && address(uint160(uint256(logs[i].topics[2]))) == c.bootstrap;
            assertFalse(bootstrapRoleManager, "ROLE_MANAGER was granted to the bootstrap");
        }
    }

    /// @dev Any Platform ADMIN holder cuts an operator off in one transaction through the RoleRevoker, while the
    ///      Protocol Admin Safe's own ROLE_MANAGER waits for the power delay (a self-grant is visible first).
    function test_roleRevokerCutsOffAtOnceAndGrantsWait() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        uint64[] memory roles = _operationalRoles();

        // Strangers and the operator itself cannot use it.
        vm.expectRevert(abi.encodeWithSelector(RoleRevoker.RoleRevokerUnauthorized.selector, address(this)));
        RoleRevoker(a.roleRevoker).revokeRoles(roles, a.operationsSafe);
        vm.prank(a.operationsSafe);
        vm.expectRevert(abi.encodeWithSelector(RoleRevoker.RoleRevokerUnauthorized.selector, a.operationsSafe));
        RoleRevoker(a.roleRevoker).revokeRole(roles[0], a.operationsSafe);

        // Governance roles are out of its reach: their admin is ADMIN, not ROLE_MANAGER.
        vm.prank(a.protocolAdminSafe);
        vm.expectRevert();
        RoleRevoker(a.roleRevoker).revokeRole(RoleTable.versionManager(), a.upgradeCouncilSafe);
        vm.prank(a.protocolAdminSafe);
        vm.expectRevert();
        RoleRevoker(a.roleRevoker).revokeRole(RoleTable.roleManager(), a.protocolAdminSafe);

        // The Protocol Admin Safe revokes every operational role in the same block.
        _fromSafe(
            c,
            Actor.ProtocolAdminSafe,
            a.roleRevoker,
            abi.encodeCall(RoleRevoker.revokeRoles, (roles, a.operationsSafe))
        );
        for (uint256 i = 0; i < roles.length; i++) {
            (bool member,) = IAccessManager(a.platformAM).hasRole(roles[i], a.operationsSafe);
            assertFalse(member, "operational role survived");
        }

        // Granting goes the slow way: the Safe's ROLE_MANAGER carries the power delay, so a direct grant reverts.
        (, uint32 delay) = IAccessManager(a.platformAM).hasRole(RoleTable.roleManager(), a.protocolAdminSafe);
        assertEq(delay, c.powerDelay, "Safe's ROLE_MANAGER is not behind the power delay");
        vm.prank(a.protocolAdminSafe);
        vm.expectRevert();
        IAccessManager(a.platformAM).grantRole(RoleTable.interopManager(), a.protocolAdminSafe, 0);
    }

    /// @dev OpenZeppelin's review: no guarded function of an upgrade-governed target stays on ADMIN, where the
    ///      guardian cannot cancel. Read from each target's ABI in the build, not a hand list, so a new function is
    ///      covered the day it is added: every selector a stranger is refused with an authorization error
    ///      (AccessManaged, Ownable, AccessControl), and every `renounce*`, must be on VERSION_MANAGER. The
    ///      IdentityFactory's gateway trust joins the registry's on INTEROP_MANAGER.
    function test_everyGuardedUpgradeTargetFunctionIsOnTheCodeRole() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        Addrs memory a = _addresses(c);
        string[6] memory names = [
            "TREXImplementationAuthority",
            "SpenderVerificationModule",
            "SpenderWhitelistModule",
            "MaxBalancePerIdentityModule",
            "UtilityChecker",
            "IdentityUtilities"
        ];
        address[6] memory targets = [
            a.implementationAuthority,
            a.spenderVerification,
            a.spenderWhitelist,
            a.maxBalance,
            a.utilityChecker,
            a.identityUtilities
        ];
        uint256 guarded;
        for (uint256 t = 0; t < 6; t++) {
            string memory artifact = vm.readFile(BytecodeStore.artifactPath(BytecodeStore.releaseContract(names[t])));
            string[] memory signatures = vm.parseJsonKeys(artifact, ".methodIdentifiers");
            for (uint256 i = 0; i < signatures.length; i++) {
                bytes4 selector = bytes4(keccak256(bytes(signatures[i])));
                // AccessManaged.setAuthority answers only the current manager, which calls it from its own
                // `updateAuthority`. OpenZeppelin hardcodes that to ADMIN, so no mapping can move it: it is the
                // documented ADMIN limit (deploy/README.md), not a gap this table can close.
                if (selector == IAccessManaged.setAuthority.selector) continue;
                if (!_guarded(targets[t], selector, signatures[i])) continue;
                guarded++;
                assertEq(
                    IAccessManager(a.upgradeAM).getTargetFunctionRole(targets[t], selector),
                    RoleTable.versionManager(),
                    string.concat(names[t], ".", signatures[i], " is guarded but not on VERSION_MANAGER")
                );
            }
        }
        // authority 3, three modules 1 each, UtilityChecker 3 (upgrade and the two Ownable functions), IdentityUtilities
        // 4 (upgrade, grantRole, revokeRole, renounceRole). Its topic functions are TOPIC_MANAGER's, which the manager
        // does not hold, so the manager cannot reach them.
        assertGe(guarded, 13, "fewer guarded functions found than expected");
        assertEq(
            IAccessManager(a.platformAM)
                .getTargetFunctionRole(a.identityFactory, IdentityFactory.setTrustedGateway.selector),
            RoleTable.interopManager()
        );
    }

    /// @dev True for a function a manager ADMIN could run through `execute` without the guardian:
    ///      - an AccessManaged `restricted` function (a stranger gets AccessManagedUnauthorized): unmapped, it is ADMIN's;
    ///      - an Ownable or AccessControl function a stranger is refused but the manager (owner, DEFAULT_ADMIN_ROLE)
    ///        gets past;
    ///      - any `renounce*`: it only checks its argument, and the manager renouncing would end an upgrade path.
    function _guarded(address target, bytes4 selector, string memory signature) internal returns (bool) {
        if (vm.indexOf(signature, "renounce") == 0) return true;
        bytes4 asStranger = _authError(makeAddr("stranger"), target, selector);
        if (asStranger == IAccessManaged.AccessManagedUnauthorized.selector) return true;
        if (asStranger == bytes4(0)) return false;
        return _authError(_addresses(_config()).upgradeAM, target, selector) == bytes4(0);
    }

    /// @dev The authorization error `caller` gets from `selector` (zero arguments), or zero when it gets past them.
    function _authError(address caller, address target, bytes4 selector) internal returns (bytes4 err) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(abi.encodePacked(selector, new bytes(256)));
        vm.revertToState(snapshot);
        if (ok || ret.length < 4) return bytes4(0);
        err = bytes4(ret);
        bool auth = err == IAccessManaged.AccessManagedUnauthorized.selector
            || err == Ownable.OwnableUnauthorizedAccount.selector
            || err == IAccessControl.AccessControlUnauthorizedAccount.selector;
        if (!auth) err = bytes4(0);
    }

    /// @dev Step 6 verifies every role holder and mapping, not only the expected ones. Planted before finalize,
    ///      each of these passes the regular verification, and the log scan names every one:
    ///      a guardian nobody planned, an unlisted selector opened to PUBLIC_ROLE (no holder, no RoleGranted), and a
    ///      second DEFAULT_ADMIN_ROLE holder on IdentityUtilities (its own AccessControl).
    function test_governanceScanFindsOnlyWhatWasNotPlanned() public {
        DeployConfig memory c = _config();
        vm.recordLogs();
        _deployAndConfigure(c);
        Addrs memory a = _addresses(c);
        address intruder = makeAddr("intruder");
        vm.startPrank(c.bootstrap);
        IAccessManager(a.platformAM).grantRole(RoleTable.guardian(), intruder, 0);
        bytes4[] memory policy = new bytes4[](1);
        policy[0] = IdentityFactory.setIdentityTypePolicy.selector;
        IAccessManager(a.platformAM).setTargetFunctionRole(a.identityFactory, policy, type(uint64).max);
        IAccessControl(a.identityUtilities).grantRole(DEFAULT_ADMIN_ROLE, intruder);
        vm.stopPrank();
        _handOver(c);
        _assertNoFailures(_verify(c, true, true));

        string[] memory found = _unexpectedGovernance(c, _entries(vm.getRecordedLogs()));
        for (uint256 i = 0; i < found.length; i++) {
            emit log_named_string("found", found[i]);
        }
        assertEq(found.length, 3, "the guardian, the PUBLIC mapping and the IdentityUtilities admin");
        assertGt(vm.indexOf(found[0], vm.toString(intruder)), 0, "the guardian intruder is named");
        assertEq(vm.indexOf(found[1], "unplanned function role"), 0, "the PUBLIC mapping is named");
        assertEq(vm.indexOf(found[2], "unexpected IdentityUtilities holder"), 0, "the IdentityUtilities admin is named");
    }

    /// @dev A grant made once the grant delays are in force is pending: `hasRole` says "not a member" until the
    ///      delay ends. The scan reads `getAccess` and still names the holder-to-be.
    function test_governanceScanSeesAPendingGrant() public {
        DeployConfig memory c = _config();
        vm.recordLogs();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        address intruder = makeAddr("intruder");
        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (RoleTable.guardian(), intruder, 0));
        vm.prank(a.protocolAdminSafe);
        IAccessManager(a.platformAM).schedule(a.platformAM, grant, 0);
        vm.warp(block.timestamp + c.powerDelay + 1);
        vm.prank(a.protocolAdminSafe);
        IAccessManager(a.platformAM).execute(a.platformAM, grant);
        (bool member,) = IAccessManager(a.platformAM).hasRole(RoleTable.guardian(), intruder);
        assertFalse(member, "pending: hasRole hides it");

        string[] memory found = _unexpectedGovernance(c, _entries(vm.getRecordedLogs()));
        assertEq(found.length, 1, "the pending guardian");
        assertGt(vm.indexOf(found[0], vm.toString(intruder)), 0);
    }

    /// @dev Re-granting a planned role with a lower execution delay keeps showing the old delay until the change
    ///      takes effect, so the Council's 5 days could silently become zero. Verification reads the pending change
    ///      through `getAccess` and fails at once.
    function test_verificationSeesALoweredExecutionDelay() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        bytes memory lower =
            abi.encodeCall(IAccessManager.grantRole, (RoleTable.versionManager(), a.upgradeCouncilSafe, 0));
        vm.prank(a.upgradeCouncilSafe);
        IAccessManager(a.upgradeAM).schedule(a.upgradeAM, lower, 0);
        vm.warp(block.timestamp + c.codeDelay + 1);
        vm.prank(a.upgradeCouncilSafe);
        IAccessManager(a.upgradeAM).execute(a.upgradeAM, lower);
        (, uint32 shown) = IAccessManager(a.upgradeAM).hasRole(RoleTable.versionManager(), a.upgradeCouncilSafe);
        assertEq(shown, c.codeDelay, "hasRole still shows the old delay");

        string[] memory failures = _verify(c, true, true);
        bool flagged;
        for (uint256 i = 0; i < failures.length; i++) {
            if (vm.indexOf(failures[i], "execution delay change pending") != type(uint256).max) flagged = true;
        }
        assertTrue(flagged, "the pending delay cut is flagged");
    }

    /// @dev `finalize` scans before renouncing, when the Bootstrap Operator still holds ADMIN on both managers and its
    ///      two IdentityUtilities roles. That scan exempts exactly those holdings: anything else the Bootstrap holds is
    ///      still reported. Without the exemption the same state reports the four holdings, which is the scan `finalize`
    ///      runs again after renouncing.
    function test_preRenounceScanExemptsOnlyTheBootstrapsOwnHoldings() public {
        DeployConfig memory c = _config();
        vm.recordLogs();
        _deployAndConfigure(c);
        vm.warp(block.timestamp + c.codeDelay + 1);
        Vm.Log[] memory recorded = vm.getRecordedLogs();

        assertEq(_unexpectedGovernance(c, _entries(recorded), true).length, 0, "nothing beyond the Bootstrap's own");
        assertEq(_unexpectedGovernance(c, _entries(recorded), false).length, 4, "ADMIN x2 and IdentityUtilities x2");

        // A guardian the Bootstrap gives itself is not part of the exemption.
        Addrs memory a = _addresses(c);
        vm.recordLogs();
        vm.prank(c.bootstrap);
        IAccessManager(a.platformAM).grantRole(RoleTable.guardian(), c.bootstrap, 0);
        string[] memory found = _unexpectedGovernance(c, _entries(vm.getRecordedLogs()), true);
        assertEq(found.length, 1, "the extra guardian");
        assertGt(vm.indexOf(found[0], vm.toString(c.bootstrap)), 0);

        // After the handover nothing is exempt and nothing is left.
        _run(c, _finalizeSteps(c), "finalize");
        assertEq(_unexpectedGovernance(c, _entries(recorded), false).length, 0, "all renounced");
    }

    /// @dev Every role in the closed list must keep its planned admin and guardian, on both managers. An admin set to
    ///      PUBLIC_ROLE on VERSION_MANAGER would let anyone grant themselves the code role later.
    function test_verificationCatchesAPublicRoleAdmin() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        Addrs memory a = _addresses(c);
        vm.prank(c.bootstrap);
        IAccessManager(a.upgradeAM).setRoleAdmin(RoleTable.versionManager(), type(uint64).max);
        _handOver(c);
        string[] memory failures = _verify(c, true, true);
        bool flagged;
        for (uint256 i = 0; i < failures.length; i++) {
            if (vm.indexOf(failures[i], "admin of role") == 0) flagged = true;
        }
        assertTrue(flagged, "the PUBLIC admin is flagged");
    }

    /// @dev The guardian's veto taken from the manager's OperationScheduled log works whatever the guardian's build;
    ///      a veto computed from a different build finds nothing scheduled and is refused instead of "succeeding".
    function test_cancelFromTheScheduledLogAndRefuseAMismatchedOne() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        Version v1 = _version(c.versionMajor, c.versionMinor, c.versionPatch + 1);
        bytes memory scheduled = _upgradeCall(a, v1);
        vm.recordLogs();
        vm.prank(a.upgradeCouncilSafe);
        IAccessManager(a.upgradeAM).schedule(a.implementationAuthority, scheduled, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The guardian's checkout computes another call (here: another version), so another operation id.
        Step[] memory mismatched = _one(_cancelStep(c, _upgradeCall(a, _version(9, 9, 9)), "mismatched"));
        vm.expectRevert();
        this.requireAllScheduled(mismatched);

        LogEntry[] memory entries = _entries(logs);
        Step memory veto;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == IAccessManager.OperationScheduled.selector) {
                veto = _cancelFromScheduledLog(entries[i]);
            }
        }
        this.requireAllScheduled(_one(veto));
        assertTrue(_run(c, _one(veto), "cancel-by-log"), "cancelled");
        bytes32 id =
            IAccessManager(a.upgradeAM).hashOperation(a.upgradeCouncilSafe, a.implementationAuthority, scheduled);
        assertEq(IAccessManager(a.upgradeAM).getSchedule(id), 0, "nothing left scheduled");
    }

    function requireAllScheduled(Step[] memory cancels) external view {
        _requireAllScheduled(cancels);
    }

    function _assertNoFailures(string[] memory failures) internal {
        for (uint256 i = 0; i < failures.length; i++) {
            emit log_named_string("verification failure", failures[i]);
        }
        assertEq(failures.length, 0, "verification failed");
    }

}

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
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { Version } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";

import { PlanExecutor } from "./PlanExecutor.sol";
import { RoleRevoker } from "./RoleRevoker.sol";
import { DeployConfig } from "./lib/DeployConfig.sol";
import { ProbeKind, Status, Step } from "./lib/PlanTypes.sol";
import { RoleTable } from "./lib/RoleTable.sol";

/// @title DeploymentVerifier
/// @notice Read-only checks of a deployment against its config, used by VerifyDeployment.s.sol, by
///         ConfigureAndHandover.s.sol before the handover, and by the tests.
/// @dev What is checked:
///      - every genesis, protocol and configuration step reads as done (addresses, code, function roles, labels
///        aside, guardians, role admins, grants with their execution delays, identity-type policies and modules);
///      - every proxy initialized and pointing at the expected implementation and authority;
///      - beacon owners (the authority owns its five, the IdentityFactory owns the identity beacon);
///      - grant delays and target admin delays, either in force (`delaysInForce`) or at least scheduled;
///      - after the handover, the Bootstrap Operator holds none of the roles in the closed list, on either manager,
///        nor IdentityUtilities' AccessControl roles.
abstract contract DeploymentVerifier is PlanExecutor {

    /// @notice Implementations accepted on top of the deployed release, for verifying after a proxy or identity
    ///         beacon upgrade. Empty for a fresh deployment: every proxy must then point at exactly the
    ///         implementation the address table computes.
    address[] internal acceptedImplementations;

    function _accepted(address impl) internal view returns (bool) {
        for (uint256 i = 0; i < acceptedImplementations.length; i++) {
            if (acceptedImplementations[i] == impl) return true;
        }
        return false;
    }

    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Failures {
        string[] items;
        uint256 length;
    }

    function _fail(Failures memory f, string memory what) internal pure {
        if (f.length == f.items.length) {
            string[] memory grown = new string[](f.items.length * 2 + 8);
            for (uint256 i = 0; i < f.length; i++) {
                grown[i] = f.items[i];
            }
            f.items = grown;
        }
        f.items[f.length++] = what;
    }

    function _check(Failures memory f, bool ok, string memory what) internal pure {
        if (!ok) _fail(f, what);
    }

    /// @notice Every failed check, empty when the deployment matches the config.
    /// @param delaysInForce Grant and target admin delays must already apply (handover step 6), not only be set.
    /// @param afterHandover The Bootstrap Operator must hold nothing any more (after handover step 7).
    function _verify(DeployConfig memory c, bool delaysInForce, bool afterHandover)
        internal
        view
        returns (string[] memory)
    {
        Failures memory f;
        Addrs memory a = _addresses(c);
        _checkSteps(f, _genesisSteps(c));
        _checkSteps(f, _protocolSteps(c));
        _checkSteps(f, _configureSteps(c));
        _checkProxies(f, c, a);
        _checkRoleTables(f, c, a);
        _checkDelays(f, c, a, delaysInForce);
        if (afterHandover) _checkBootstrapGone(f, c, a);
        string[] memory out = new string[](f.length);
        for (uint256 i = 0; i < f.length; i++) {
            out[i] = f.items[i];
        }
        return out;
    }

    /// @dev Delay steps are checked separately ({_checkDelays}); labels have no getter.
    function _checkSteps(Failures memory f, Step[] memory steps) internal view {
        for (uint256 i = 0; i < steps.length; i++) {
            if (steps[i].probe.kind == ProbeKind.None) continue;
            Status s = _status(steps[i].probe);
            if (s != Status.Done) _fail(f, string.concat("step not done: ", steps[i].id));
        }
    }

    function _checkProxies(Failures memory f, DeployConfig memory c, Addrs memory a) internal view {
        // Suite beacons: owned by the authority and pointing at the implementations of its current version. After
        // an upgrade that is a later release, so the deployed release is checked separately below, as the one
        // recorded under the initial version.
        ITREXImplementationAuthority ia = ITREXImplementationAuthority(a.implementationAuthority);
        if (address(ia).code.length == 0) return _fail(f, "implementation authority missing");
        ITREXImplementationAuthority.SuiteBeacons memory b = ia.beacons();
        address[5] memory beacons =
            [b.tokenBeacon, b.trexRegistryBeacon, b.irsBeacon, b.mcBeacon, b.accessManagerBeacon];
        ITREXImplementationAuthority.SuiteImplementations memory live = ia.implementations();
        address[5] memory impls = [
            live.tokenImplementation,
            live.trexRegistryImplementation,
            live.irsImplementation,
            live.mcImplementation,
            live.accessManagerImplementation
        ];
        ITREXImplementationAuthority.SuiteImplementations memory first = ia.implementationsFor(_initialVersion(c));
        _check(
            f,
            keccak256(abi.encode(first)) == keccak256(abi.encode(_suiteImplementations(a))),
            "initial version does not record the deployed release"
        );
        for (uint256 i = 0; i < 5; i++) {
            _check(f, beacons[i] == a.suiteBeacons[i], string.concat("suite beacon address ", _u(i)));
            _check(
                f,
                UpgradeableBeacon(beacons[i]).owner() == a.implementationAuthority,
                string.concat("suite beacon owner ", _u(i))
            );
            _check(
                f,
                UpgradeableBeacon(beacons[i]).implementation() == impls[i],
                string.concat("suite beacon implementation ", _u(i))
            );
            _checkInitializersDisabled(f, impls[i], string.concat("suite implementation ", _u(i)));
        }
        // A later upgrade raises the version; it never goes below the one the authority was created with.
        _check(
            f,
            Version.unwrap(ia.currentVersion()) >= Version.unwrap(_initialVersion(c)),
            "authority version below the initial version"
        );
        _check(
            f,
            IAccessManaged(a.implementationAuthority).authority() == a.upgradeAM,
            "authority not governed by the Upgrade manager"
        );

        // Identity beacon: created by the factory, owned by it.
        if (a.identityBeacon.code.length > 0) {
            _check(f, UpgradeableBeacon(a.identityBeacon).owner() == a.identityFactory, "identity beacon owner");
            _check(f, IdentityFactory(a.identityFactory).beacon() == a.identityBeacon, "identity beacon address");
            address identityImpl = UpgradeableBeacon(a.identityBeacon).implementation();
            _check(f, identityImpl == a.identityImpl || _accepted(identityImpl), "identity beacon implementation");
            _checkInitializersDisabled(f, identityImpl, "Identity implementation");
        }

        // Platform contracts governed by the Platform manager.
        _check(f, IAccessManaged(a.trexFactory).authority() == a.platformAM, "TREXFactory authority");
        _check(f, IAccessManaged(a.gatewayRegistry).authority() == a.platformAM, "TrustedGatewayRegistry authority");
        _check(f, IAccessManaged(a.identityFactory).authority() == a.platformAM, "IdentityFactory authority");
        _check(f, IAccessManaged(a.reputationRegistry).authority() == a.platformAM, "ReputationRegistry authority");

        // ERC-1967 proxies: initialized, right implementation, right governance.
        _checkProxy(f, a.spenderVerification, a.spenderVerificationImpl, "SpenderVerificationModule");
        _checkProxy(f, a.spenderWhitelist, a.spenderWhitelistImpl, "SpenderWhitelistModule");
        _checkProxy(f, a.maxBalance, a.maxBalanceImpl, "MaxBalancePerIdentityModule");
        _checkProxy(f, a.utilityChecker, a.utilityCheckerImpl, "UtilityChecker");
        _checkProxy(f, a.identityUtilities, a.identityUtilitiesImpl, "IdentityUtilities");
        _check(
            f, IAccessManaged(a.spenderVerification).authority() == a.upgradeAM, "SpenderVerificationModule authority"
        );
        _check(f, IAccessManaged(a.spenderWhitelist).authority() == a.upgradeAM, "SpenderWhitelistModule authority");
        _check(f, IAccessManaged(a.maxBalance).authority() == a.upgradeAM, "MaxBalancePerIdentityModule authority");
        _check(f, Ownable(a.utilityChecker).owner() == a.upgradeAM, "UtilityChecker owner");
        // Masked code probes zero immutables and CREATE3 does not commit to constructor arguments, so the manager
        // the RoleRevoker acts on is read here: a revoker pointing elsewhere would only fail during an incident.
        if (a.roleRevoker.code.length > 0) {
            _check(f, address(RoleRevoker(a.roleRevoker).manager()) == a.platformAM, "RoleRevoker manager");
        }
    }

    function _checkProxy(Failures memory f, address proxy, address impl, string memory name) internal view {
        if (proxy.code.length == 0) return _fail(f, string.concat(name, " proxy missing"));
        address current = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        // Exactly the deployed implementation, or one accepted after an upgrade (`acceptedImplementations`).
        _check(f, current == impl || _accepted(current), string.concat(name, " proxy implementation"));
        // Read straight from OpenZeppelin's Initializable storage rather than inferred from `authority()`/`owner()`.
        _check(f, _initializedVersion(proxy) >= 1, string.concat(name, " proxy not initialized"));
        _checkInitializersDisabled(f, current, string.concat(name, " implementation"));
    }

    /// @dev ERC-7201 slot of OpenZeppelin's Initializable (v5): `_initialized` (uint64) in the low bits, then
    ///      `_initializing`.
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function _initializedVersion(address target) internal view returns (uint64) {
        return uint64(uint256(vm.load(target, INITIALIZABLE_SLOT)));
    }

    /// @dev An implementation whose initializers are not disabled could be initialized by anyone.
    function _checkInitializersDisabled(Failures memory f, address impl, string memory name) internal view {
        _check(f, _initializedVersion(impl) == type(uint64).max, string.concat(name, " initializers not disabled"));
    }

    function _checkRoleTables(Failures memory f, DeployConfig memory c, Addrs memory a) internal view {
        FunctionRole[] memory roles = _functionRoles(a);
        for (uint256 i = 0; i < roles.length; i++) {
            for (uint256 j = 0; j < roles[i].selectors.length; j++) {
                _check(
                    f,
                    IAccessManager(roles[i].manager).getTargetFunctionRole(roles[i].target, roles[i].selectors[j])
                        == roles[i].role,
                    string.concat("function role ", _u(i), ".", _u(j))
                );
            }
        }
        _checkGrants(f, _operationalGrants(c, a));
        _checkGrants(f, _safeGrants(c, a));
        RoleSetting[] memory guardians = _guardians(a);
        for (uint256 i = 0; i < guardians.length; i++) {
            _check(
                f,
                IAccessManager(guardians[i].manager).getRoleGuardian(guardians[i].role) == guardians[i].value,
                string.concat("guardian ", _u(i))
            );
        }
        RoleSetting[] memory admins = _roleAdmins(a);
        for (uint256 i = 0; i < admins.length; i++) {
            _check(
                f,
                IAccessManager(admins[i].manager).getRoleAdmin(admins[i].role) == admins[i].value,
                string.concat("role admin ", _u(i))
            );
        }
        _checkEveryAdminAndGuardian(f, a, admins, guardians);
        _check(
            f, IAccessControl(a.identityUtilities).hasRole(DEFAULT_ADMIN_ROLE, a.upgradeAM), "IdentityUtilities admin"
        );
        _check(
            f,
            IAccessControl(a.identityUtilities).hasRole(TOPIC_MANAGER_ROLE, a.operationsSafe),
            "IdentityUtilities topic manager"
        );
    }

    /// @dev Every role in the closed list, on both managers, has exactly the planned admin and guardian, ADMIN and
    ///      none when unlisted. Without it, an admin set to PUBLIC_ROLE on a role nobody lists (VERSION_MANAGER on a
    ///      manager where only the guardian is planned, say) would let anyone grant themselves that role later.
    function _checkEveryAdminAndGuardian(
        Failures memory f,
        Addrs memory a,
        RoleSetting[] memory admins,
        RoleSetting[] memory guardians
    ) internal view {
        uint64[12] memory roles = _closedRoleList();
        address[2] memory managers = [a.platformAM, a.upgradeAM];
        for (uint256 m = 0; m < 2; m++) {
            for (uint256 i = 0; i < roles.length; i++) {
                IAccessManager am = IAccessManager(managers[m]);
                string memory where = string.concat(_u(roles[i]), m == 0 ? " (platform)" : " (upgrade)");
                _check(
                    f,
                    am.getRoleAdmin(roles[i]) == _setting(admins, managers[m], roles[i], RoleTable.ADMIN),
                    string.concat("admin of role ", where)
                );
                _check(
                    f,
                    am.getRoleGuardian(roles[i]) == _setting(guardians, managers[m], roles[i], RoleTable.ADMIN),
                    string.concat("guardian of role ", where)
                );
            }
        }
    }

    function _setting(RoleSetting[] memory t, address manager, uint64 role, uint64 fallbackValue)
        internal
        pure
        returns (uint64)
    {
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i].manager == manager && t[i].role == role) return t[i].value;
        }
        return fallbackValue;
    }

    /// @dev `getAccess`, not `hasRole`: `hasRole` shows the old execution delay until a pending change takes effect,
    ///      so a lowered delay (say the Council's 5 days set to zero) would pass until it bites.
    function _checkGrants(Failures memory f, Grant[] memory grants) internal view {
        for (uint256 i = 0; i < grants.length; i++) {
            (uint48 since, uint32 delay, uint32 pendingDelay, uint48 effect) =
                IAccessManager(grants[i].manager).getAccess(grants[i].role, grants[i].account);
            string memory id = string.concat("grant ", _u(i), " role ", _u(grants[i].role));
            _check(f, since != 0 && since <= block.timestamp && delay == grants[i].executionDelay, id);
            _check(
                f,
                effect == 0 || (effect <= block.timestamp && pendingDelay == grants[i].executionDelay),
                string.concat(id, ": execution delay change pending")
            );
        }
    }

    function _checkDelays(Failures memory f, DeployConfig memory c, Addrs memory a, bool inForce) internal view {
        DelaySetting[] memory g = _grantDelays(c, a);
        for (uint256 i = 0; i < g.length; i++) {
            uint32 actual = inForce
                ? IAccessManager(g[i].manager).getRoleGrantDelay(uint64(g[i].subject))
                : _pendingGrantDelay(g[i].manager, uint64(g[i].subject));
            _check(
                f, actual == g[i].delay, string.concat("grant delay ", _u(i), inForce ? " (in force)" : " (scheduled)")
            );
        }
        DelaySetting[] memory t = _targetAdminDelays(c, a);
        for (uint256 i = 0; i < t.length; i++) {
            address target = address(uint160(t[i].subject));
            uint32 actual = inForce
                ? IAccessManager(t[i].manager).getTargetAdminDelay(target)
                : _pendingTargetAdminDelay(t[i].manager, target);
            _check(
                f,
                actual == t[i].delay,
                string.concat("target admin delay ", _u(i), inForce ? " (in force)" : " (scheduled)")
            );
        }
    }

    /// @notice Every role id the deployment uses, on both managers: the closed list the Bootstrap Operator must
    ///         not hold after the handover.
    function _closedRoleList() internal pure returns (uint64[12] memory roles) {
        roles = [
            RoleTable.ADMIN,
            RoleTable.roleManager(),
            RoleTable.guardian(),
            RoleTable.versionManager(),
            RoleTable.tokenIssuer(),
            RoleTable.assetDeployer(),
            RoleTable.interopManager(),
            RoleTable.reputationManager(),
            RoleTable.claimIssuerAdmin(),
            RoleTable.issuer(),
            RoleTable.publicAuthority(),
            // ONCHAINID's own token-factory id, in case anyone granted it.
            uint64(1)
        ];
    }

    /// @notice Every role holder accounted for: given the (manager, role, account) of each `RoleGranted` event since
    ///         the deployment, returns one failure per grant that is still held but is not in the role tables
    ///         (`_operationalGrants`, `_safeGrants`). This catches a holder nobody planned, which `hasRole` checks on
    ///         the expected holders alone cannot see.
    function _unexpectedHolders(
        DeployConfig memory c,
        address[] memory managers,
        uint64[] memory roles,
        address[] memory accounts,
        bool bootstrapExempt
    ) internal view returns (string[] memory) {
        Addrs memory a = _addresses(c);
        Grant[] memory ops = _operationalGrants(c, a);
        Grant[] memory safes = _safeGrants(c, a);
        Failures memory f;
        for (uint256 i = 0; i < roles.length; i++) {
            // A pending grant (since in the future) reads as "not a member" through `hasRole`; it is still a holder.
            (uint48 since,,,) = IAccessManager(managers[i]).getAccess(roles[i], accounts[i]);
            if (since == 0 || _planned(ops, managers[i], roles[i], accounts[i])) continue;
            if (_planned(safes, managers[i], roles[i], accounts[i])) continue;
            // Before `finalize` renounces, the Bootstrap Operator holds ADMIN on both managers by design; nothing else.
            if (bootstrapExempt && accounts[i] == c.bootstrap && roles[i] == RoleTable.ADMIN) continue;
            _fail(
                f,
                string.concat(
                    "unexpected holder ",
                    vm.toString(accounts[i]),
                    " of role ",
                    _u(roles[i]),
                    managers[i] == a.platformAM ? " (platform)" : " (upgrade)"
                )
            );
        }
        string[] memory out = new string[](f.length);
        for (uint256 i = 0; i < f.length; i++) {
            out[i] = f.items[i];
        }
        return out;
    }

    /// @notice A log, from `vm.getRecordedLogs()` in tests or `eth_getLogs` in scripts.
    struct LogEntry {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// @dev AccessControl's RoleGranted(bytes32 indexed role, address indexed account, address indexed sender).
    bytes32 internal constant ACCESS_CONTROL_ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");

    /// @notice Everything the role tables do not plan, found from the logs since the deployment (step 6):
    ///         - a holder of a manager role nobody planned, pending grants included;
    ///         - a function mapping that differs from the plan, or any unlisted selector moved off ADMIN (to
    ///           PUBLIC_ROLE, say), which needs no holder and so no RoleGranted at all;
    ///         - an IdentityUtilities AccessControl holder other than the planned ones.
    function _unexpectedGovernance(DeployConfig memory c, LogEntry[] memory logs)
        internal
        view
        returns (string[] memory)
    {
        return _unexpectedGovernance(c, logs, false);
    }

    /// @param bootstrapExempt True only for the scan `finalize` runs before renouncing: the Bootstrap Operator's own
    ///        holdings at that point (ADMIN on both managers, DEFAULT_ADMIN_ROLE and TOPIC_MANAGER_ROLE on
    ///        IdentityUtilities) are expected then and nowhere else. Anything else it holds is still reported.
    function _unexpectedGovernance(DeployConfig memory c, LogEntry[] memory logs, bool bootstrapExempt)
        internal
        view
        returns (string[] memory)
    {
        Addrs memory a = _addresses(c);
        Failures memory f;
        _scanManagerHolders(f, c, a, logs, bootstrapExempt);
        _scanFunctionRoles(f, a, logs);
        _scanIdentityUtilities(f, c, a, logs, bootstrapExempt);
        string[] memory out = new string[](f.length);
        for (uint256 i = 0; i < f.length; i++) {
            out[i] = f.items[i];
        }
        return out;
    }

    /// @dev True for a log from `emitter` with event `topic0` and at least three topics.
    function _is(LogEntry memory log, address emitter, bytes32 topic0) internal pure returns (bool) {
        return log.emitter == emitter && log.topics.length >= 3 && log.topics[0] == topic0;
    }

    function _isManagerEvent(Addrs memory a, LogEntry memory log, bytes32 topic0) internal pure returns (bool) {
        return _is(log, a.platformAM, topic0) || _is(log, a.upgradeAM, topic0);
    }

    function _scanManagerHolders(
        Failures memory f,
        DeployConfig memory c,
        Addrs memory a,
        LogEntry[] memory logs,
        bool bootstrapExempt
    ) internal view {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (_isManagerEvent(a, logs[i], IAccessManager.RoleGranted.selector)) n++;
        }
        address[] memory managers = new address[](n);
        uint64[] memory roles = new uint64[](n);
        address[] memory accounts = new address[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (!_isManagerEvent(a, logs[i], IAccessManager.RoleGranted.selector)) continue;
            managers[n] = logs[i].emitter;
            roles[n] = uint64(uint256(logs[i].topics[1]));
            accounts[n] = address(uint160(uint256(logs[i].topics[2])));
            n++;
        }
        string[] memory holders = _unexpectedHolders(c, managers, roles, accounts, bootstrapExempt);
        for (uint256 i = 0; i < holders.length; i++) {
            _fail(f, holders[i]);
        }
    }

    function _scanFunctionRoles(Failures memory f, Addrs memory a, LogEntry[] memory logs) internal view {
        FunctionRole[] memory plan = _functionRoles(a);
        for (uint256 i = 0; i < logs.length; i++) {
            if (!_isManagerEvent(a, logs[i], IAccessManager.TargetFunctionRoleUpdated.selector)) continue;
            address target = address(uint160(uint256(logs[i].topics[1])));
            bytes4 selector = abi.decode(logs[i].data, (bytes4));
            (bool listed, uint64 planned) = _plannedFunctionRole(plan, logs[i].emitter, target, selector);
            uint64 current = IAccessManager(logs[i].emitter).getTargetFunctionRole(target, selector);
            _check(
                f,
                current == (listed ? planned : RoleTable.ADMIN),
                string.concat(
                    listed ? "function role differs from the plan: " : "unplanned function role: ",
                    vm.toString(target),
                    ".",
                    vm.toString(abi.encodePacked(selector)),
                    " -> ",
                    _u(current)
                )
            );
        }
    }

    function _plannedFunctionRole(FunctionRole[] memory plan, address manager, address target, bytes4 selector)
        internal
        pure
        returns (bool, uint64)
    {
        for (uint256 i = 0; i < plan.length; i++) {
            if (plan[i].manager != manager || plan[i].target != target) continue;
            for (uint256 j = 0; j < plan[i].selectors.length; j++) {
                if (plan[i].selectors[j] == selector) return (true, plan[i].role);
            }
        }
        return (false, 0);
    }

    function _scanIdentityUtilities(
        Failures memory f,
        DeployConfig memory c,
        Addrs memory a,
        LogEntry[] memory logs,
        bool bootstrapExempt
    ) internal view {
        for (uint256 i = 0; i < logs.length; i++) {
            if (!_is(logs[i], a.identityUtilities, ACCESS_CONTROL_ROLE_GRANTED)) continue;
            bytes32 role = logs[i].topics[1];
            address account = address(uint160(uint256(logs[i].topics[2])));
            if (!IAccessControl(a.identityUtilities).hasRole(role, account)) continue;
            bool planned = (role == DEFAULT_ADMIN_ROLE && account == a.upgradeAM)
                || (role == TOPIC_MANAGER_ROLE && account == a.operationsSafe)
                || (bootstrapExempt
                    && account == c.bootstrap
                    && (role == DEFAULT_ADMIN_ROLE || role == TOPIC_MANAGER_ROLE));
            _check(
                f,
                planned,
                string.concat("unexpected IdentityUtilities holder ", vm.toString(account), " of ", vm.toString(role))
            );
        }
    }

    /// @notice The logs `vm.recordLogs()` captured, as {LogEntry}s.
    function _entries(Vm.Log[] memory recorded) internal pure returns (LogEntry[] memory out) {
        out = new LogEntry[](recorded.length);
        for (uint256 i = 0; i < recorded.length; i++) {
            out[i] = LogEntry(recorded[i].emitter, recorded[i].topics, recorded[i].data);
        }
    }

    function _planned(Grant[] memory t, address manager, uint64 role, address account) internal pure returns (bool) {
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i].manager == manager && t[i].role == role && t[i].account == account) return true;
        }
        return false;
    }

    function _checkBootstrapGone(Failures memory f, DeployConfig memory c, Addrs memory a) internal view {
        uint64[12] memory roles = _closedRoleList();
        address[2] memory managers = [a.platformAM, a.upgradeAM];
        for (uint256 m = 0; m < 2; m++) {
            for (uint256 i = 0; i < roles.length; i++) {
                // getAccess: a pending grant (not yet in effect) reads as "not a member" through hasRole.
                (uint48 since,,,) = IAccessManager(managers[m]).getAccess(roles[i], c.bootstrap);
                _check(
                    f,
                    since == 0,
                    string.concat("bootstrap still holds role ", _u(roles[i]), m == 0 ? " (platform)" : " (upgrade)")
                );
            }
        }
        _check(
            f,
            !IAccessControl(a.identityUtilities).hasRole(DEFAULT_ADMIN_ROLE, c.bootstrap),
            "bootstrap still IdentityUtilities admin"
        );
        _check(
            f,
            !IAccessControl(a.identityUtilities).hasRole(TOPIC_MANAGER_ROLE, c.bootstrap),
            "bootstrap still IdentityUtilities topic manager"
        );
    }

}

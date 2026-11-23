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

import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { IUUPS } from "scripts/deploy/PlanBuilder.sol";
import { RoleRevoker } from "scripts/deploy/RoleRevoker.sol";
import { DeployConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor, Step } from "scripts/deploy/lib/PlanTypes.sol";
import { RoleTable } from "scripts/deploy/lib/RoleTable.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice What happens when something goes wrong after the handover: a compromised Safe is cut off at once, a
///         leaked Bootstrap key is worthless, operators cannot reach code, and the guardian stops a bad operation
///         without being able to run one.
contract ForkIncidentResponseTest is ForkBase {

    /// @dev The Operations Safe is compromised. The Protocol Admin Safe (Platform ADMIN) revokes its roles through the
    ///      RoleRevoker, which holds ROLE_MANAGER with no delay, in the same block; an operation it had already
    ///      scheduled dies with the role.
    function test_compromisedOperationsSafeIsCutOffAtOnce() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Token existing = _suiteWithBalances(c, "before-incident");

        // The attacker queues a trusted gateway of their own (24 h delay) before anyone notices.
        address evilGateway = makeAddr("evil gateway");
        bytes memory trust = abi.encodeCall(TrustedGatewayRegistry.setTrustedGateway, (evilGateway, true));
        _fromSafe(
            c,
            Actor.OperationsSafe,
            a.platformAM,
            abi.encodeCall(IAccessManager.schedule, (a.gatewayRegistry, trust, 0))
        );

        uint64[] memory roles = new uint64[](2);
        roles[0] = RoleTable.tokenIssuer();
        roles[1] = RoleTable.interopManager();
        _fromSafe(
            c,
            Actor.ProtocolAdminSafe,
            a.roleRevoker,
            abi.encodeCall(RoleRevoker.revokeRoles, (roles, a.operationsSafe))
        );
        (bool issuer,) = IAccessManager(a.platformAM).hasRole(RoleTable.tokenIssuer(), a.operationsSafe);
        (bool interop,) = IAccessManager(a.platformAM).hasRole(RoleTable.interopManager(), a.operationsSafe);
        assertFalse(issuer, "TOKEN_ISSUER revoked in the same block");
        assertFalse(interop, "INTEROP_MANAGER revoked in the same block");

        _expectSafeCallReverts(
            Actor.OperationsSafe,
            a.trexFactory,
            abi.encodeCall(
                ITREXFactory.deployTREXSuite, ("after-incident", _tokenDetails("after-incident"), _noClaims())
            )
        );
        vm.warp(block.timestamp + c.configDelay + 1);
        _expectSafeCallReverts(
            Actor.OperationsSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.gatewayRegistry, trust))
        );
        assertFalse(
            TrustedGatewayRegistry(a.gatewayRegistry).isTrusted(evilGateway), "queued operation died with the role"
        );

        // Issuers are unaffected: suites live in their own managers.
        vm.prank(alice);
        existing.transfer(bob, 10);
        assertEq(existing.balanceOf(bob), 10);
    }

    /// @dev The Bootstrap Operator's key leaks after the handover. It renounced everything, so nothing it signs works.
    function test_leakedBootstrapKeyIsPowerless() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        address[2] memory managers = [a.platformAM, a.upgradeAM];
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ITREXFactory.setImplementationAuthority.selector;

        for (uint256 m = 0; m < 2; m++) {
            IAccessManager manager = IAccessManager(managers[m]);
            vm.prank(c.bootstrap);
            vm.expectRevert();
            manager.grantRole(RoleTable.ADMIN, c.bootstrap, 0);

            vm.prank(c.bootstrap);
            vm.expectRevert();
            manager.setTargetFunctionRole(a.trexFactory, selectors, RoleTable.tokenIssuer());

            vm.prank(c.bootstrap);
            vm.expectRevert();
            manager.labelRole(RoleTable.guardian(), "PWNED");

            vm.prank(c.bootstrap);
            vm.expectRevert();
            manager.updateAuthority(a.trexFactory, c.bootstrap);

            vm.prank(c.bootstrap);
            vm.expectRevert();
            manager.schedule(a.implementationAuthority, "", 0);
        }

        bytes32 adminRole = IAccessControl(a.identityUtilities).getRoleAdmin(TOPIC_MANAGER_ROLE);
        vm.prank(c.bootstrap);
        vm.expectRevert();
        IAccessControl(a.identityUtilities).grantRole(adminRole, c.bootstrap);

        vm.prank(c.bootstrap);
        vm.expectRevert();
        IdentityFactory(a.identityFactory).setTrustedVerifier(c.bootstrap, true);

        _assertVerified(c);
    }

    /// @dev The Operations Safe runs day-to-day business; no path from it reaches code, not even scheduling.
    function test_operationsCannotTouchCode() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        bytes memory upgrade = _upgradeCall(next, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1));

        _expectSafeCallReverts(Actor.OperationsSafe, a.implementationAuthority, upgrade);
        _expectSafeCallReverts(
            Actor.OperationsSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, upgrade, 0))
        );
        bytes memory beaconUpgrade = abi.encodeCall(IdentityFactory.upgradeBeacon, (next.identityImpl, "3.0.0"));
        _expectSafeCallReverts(
            Actor.OperationsSafe,
            a.platformAM,
            abi.encodeCall(IAccessManager.schedule, (a.identityFactory, beaconUpgrade, 0))
        );
        bytes memory moduleUpgrade = abi.encodeCall(IUUPS.upgradeToAndCall, (next.spenderWhitelistImpl, ""));
        _expectSafeCallReverts(Actor.OperationsSafe, a.spenderWhitelist, moduleUpgrade);
        _expectSafeCallReverts(
            Actor.OperationsSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.spenderWhitelist, moduleUpgrade, 0))
        );

        assertEq(
            UpgradeableBeacon(a.suiteBeacons[0]).implementation(), a.tokenImpl, "suites still on the deployed code"
        );
    }

    /// @dev An upgrade and its rollback are scheduled together; the guardian cancels the rollback, the upgrade
    ///      still goes through, and the cancelled rollback can no longer run.
    function test_guardianCancelsPreScheduledRollback() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        bytes memory upgrade = _upgradeCall(next, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1));
        bytes memory rollback = _upgradeCall(a, _version(c.versionMajor, c.versionMinor, c.versionPatch + 2));

        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, upgrade, 0))
        );
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, rollback, 0))
        );
        // The guardian's veto through the tooling: the rollback's implementations are read from the chain (what the
        // authority recorded under the initial version), never rebuilt.
        Step memory veto = _cancelRollback(
            c,
            _version(c.versionMajor, c.versionMinor, c.versionPatch),
            _version(c.versionMajor, c.versionMinor, c.versionPatch + 2)
        );
        assertEq(
            veto.data,
            abi.encodeCall(IAccessManager.cancel, (a.upgradeCouncilSafe, a.implementationAuthority, rollback))
        );
        assertTrue(_run(c, _one(veto), "cancel-rollback"), "cancel");

        vm.warp(block.timestamp + c.codeDelay + 1);
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, upgrade))
        );
        _expectSafeCallReverts(
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, rollback))
        );
        assertEq(UpgradeableBeacon(a.suiteBeacons[0]).implementation(), next.tokenImpl, "suites stay on the new code");
    }

    /// @dev The linked-cancellation risk: vetoing an upgrade must not leave its pre-scheduled rollback pending.
    ///      `cancelWithRollback` cancels both in one batch; neither can run afterwards.
    function test_guardianCancelsUpgradeAndRollbackTogether() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        bytes memory upgrade = _upgradeCall(next, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1));
        bytes memory rollback = _upgradeCall(a, _version(c.versionMajor, c.versionMinor, c.versionPatch + 2));
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, upgrade, 0))
        );
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, rollback, 0))
        );

        Step[] memory vetoes = _two(
            _cancelSuiteUpgrade(c, REHEARSAL_SALT, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1)),
            _cancelRollback(
                c,
                _version(c.versionMajor, c.versionMinor, c.versionPatch),
                _version(c.versionMajor, c.versionMinor, c.versionPatch + 2)
            )
        );
        assertEq(_pendingCount(vetoes), 2, "both operations scheduled");
        assertTrue(_run(c, vetoes, "cancel-with-rollback"), "cancel both");
        assertEq(_pendingCount(vetoes), 0, "nothing left scheduled");

        vm.warp(block.timestamp + c.codeDelay + 1);
        _expectSafeCallReverts(
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, upgrade))
        );
        _expectSafeCallReverts(
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, rollback))
        );
        assertEq(UpgradeableBeacon(a.suiteBeacons[0]).implementation(), a.tokenImpl, "suites stay on the deployed code");
    }

    /// @dev A trusted gateway turns hostile. Distrusting it is the same function as trusting it, under INTEROP_MANAGER
    ///      with its 24 h delay, on the registry and on the IdentityFactory alike: it cannot happen sooner, and does
    ///      once the delay has passed. An immediate distrust under its own role needs a contract change (known limit).
    function test_hostileGatewayDistrustTakesTheConfigDelay() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        address gateway = makeAddr("gateway");
        bytes memory chainRef = bytes("8453");
        bytes memory trustReg = abi.encodeCall(TrustedGatewayRegistry.setTrustedGateway, (gateway, true));
        bytes memory trustIdf =
            abi.encodeCall(IdentityFactory.setTrustedGateway, (gateway, bytes2(0x0000), chainRef, true));
        _scheduleAndExecute(c, Actor.OperationsSafe, a.platformAM, a.gatewayRegistry, trustReg, c.configDelay);
        _scheduleAndExecute(c, Actor.OperationsSafe, a.platformAM, a.identityFactory, trustIdf, c.configDelay);
        assertTrue(TrustedGatewayRegistry(a.gatewayRegistry).isTrusted(gateway), "trusted on the registry");
        assertTrue(
            IdentityFactory(a.identityFactory).isTrustedGateway(gateway, bytes2(0x0000), chainRef),
            "trusted on the factory"
        );

        // It turns hostile: no immediate path, not for the operator and not for the Protocol Admin Safe.
        bytes memory distrustReg = abi.encodeCall(TrustedGatewayRegistry.setTrustedGateway, (gateway, false));
        bytes memory distrustIdf =
            abi.encodeCall(IdentityFactory.setTrustedGateway, (gateway, bytes2(0x0000), chainRef, false));
        _expectSafeCallReverts(
            Actor.OperationsSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.gatewayRegistry, distrustReg))
        );
        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.gatewayRegistry, distrustReg);
        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.identityFactory, distrustIdf);

        _scheduleAndExecute(c, Actor.OperationsSafe, a.platformAM, a.gatewayRegistry, distrustReg, c.configDelay);
        _scheduleAndExecute(c, Actor.OperationsSafe, a.platformAM, a.identityFactory, distrustIdf, c.configDelay);
        assertFalse(TrustedGatewayRegistry(a.gatewayRegistry).isTrusted(gateway), "distrusted on the registry");
        assertFalse(
            IdentityFactory(a.identityFactory).isTrustedGateway(gateway, bytes2(0x0000), chainRef),
            "distrusted on the factory"
        );
    }

    /// @dev The guardian can cancel but never execute: only the Council can run the Council's operation.
    function test_guardianCannotExecute() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        bytes memory upgrade = _upgradeCall(next, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1));
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, upgrade, 0))
        );
        vm.warp(block.timestamp + c.codeDelay + 1);

        _expectSafeCallReverts(
            Actor.ProtocolAdminSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, upgrade))
        );
        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.implementationAuthority, upgrade);

        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, upgrade))
        );
        assertEq(UpgradeableBeacon(a.suiteBeacons[0]).implementation(), next.tokenImpl);
    }

}

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

import { Version } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { DeployConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor } from "scripts/deploy/lib/PlanTypes.sol";
import { RoleTable } from "scripts/deploy/lib/RoleTable.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice The handover: nothing can be finalized before the delays are in force; after five days every role,
///         admin, guardian and delay is as configured and the Bootstrap Operator holds nothing; the Safes act only
///         through schedule, wait and execute; the guardian can cancel; an operation left too long expires.
contract ForkHandoverTest is ForkBase {

    function test_handoverLeavesExactlyTheConfiguredState() public {
        DeployConfig memory c = _config();
        vm.recordLogs();
        _deployAndConfigure(c);

        // Before the minimum setback: delays scheduled, not in force, so the handover must wait.
        assertEq(_verify(c, false, false).length, 0, "scheduled state");
        assertGt(_verify(c, true, false).length, 0, "delays already in force before five days");

        _handOver(c);

        // Spot checks on top of the full verification run by _handOver.
        Addrs memory a = _addresses(c);
        (bool adminIsSafe, uint32 adminDelay) =
            IAccessManager(a.platformAM).hasRole(RoleTable.ADMIN, a.protocolAdminSafe);
        assertTrue(adminIsSafe);
        assertEq(adminDelay, c.powerDelay);
        (bool bootstrapAdmin,) = IAccessManager(a.platformAM).hasRole(RoleTable.ADMIN, c.bootstrap);
        assertFalse(bootstrapAdmin);
        (bool bootstrapRoleManager,) = IAccessManager(a.platformAM).hasRole(RoleTable.roleManager(), c.bootstrap);
        assertFalse(bootstrapRoleManager);
        assertEq(IAccessManager(a.upgradeAM).getRoleGuardian(RoleTable.versionManager()), RoleTable.guardian());
        (, uint32 roleManagerDelay) = IAccessManager(a.platformAM).hasRole(RoleTable.roleManager(), a.protocolAdminSafe);
        assertEq(roleManagerDelay, c.powerDelay, "the Safe's ROLE_MANAGER is behind the power delay");
        (bool revokerHolds, uint32 revokerDelay) =
            IAccessManager(a.platformAM).hasRole(RoleTable.roleManager(), a.roleRevoker);
        assertTrue(revokerHolds && revokerDelay == 0, "the RoleRevoker revokes at once");

        // Step 6, every role holder and mapping: each grant, function mapping and IdentityUtilities grant since the
        // deployment is either gone or planned.
        string[] memory unexpected = _unexpectedGovernance(c, _entries(vm.getRecordedLogs()));
        for (uint256 i = 0; i < unexpected.length; i++) {
            emit log_named_string("unexpected", unexpected[i]);
        }
        assertEq(unexpected.length, 0, "a role holder or mapping nobody planned");
    }

    /// @dev Republishes the deployed implementations one patch version up: a real, harmless upgrade operation.
    function _bumpCall(DeployConfig memory c, Addrs memory a) internal pure returns (bytes memory) {
        return _upgradeCall(a, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1));
    }

    function test_councilMustScheduleWaitAndExecute() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        bytes memory call = _bumpCall(c, a);

        // A direct call is refused: the Council's role carries the code delay.
        vm.expectRevert();
        this.councilCall(a.implementationAuthority, call);

        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, call, 0))
        );
        // Too early.
        vm.expectRevert();
        this.councilCall(a.upgradeAM, abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, call)));

        vm.warp(block.timestamp + c.codeDelay + 1);
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, call))
        );
        assertEq(
            Version.unwrap(ITREXImplementationAuthority(a.implementationAuthority).currentVersion()),
            Version.unwrap(_version(c.versionMajor, c.versionMinor, c.versionPatch + 1))
        );
    }

    function test_guardianCancels() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        bytes memory call = _bumpCall(c, a);
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, call, 0))
        );
        _fromSafe(
            c,
            Actor.ProtocolAdminSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.cancel, (a.upgradeCouncilSafe, a.implementationAuthority, call))
        );
        vm.warp(block.timestamp + c.codeDelay + 1);
        vm.expectRevert();
        this.councilCall(a.upgradeAM, abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, call)));
    }

    function test_scheduledOperationExpires() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Addrs memory a = _addresses(c);
        bytes memory call = _bumpCall(c, a);
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, call, 0))
        );
        vm.warp(block.timestamp + c.codeDelay + IAccessManager(a.upgradeAM).expiration() + 1);
        vm.expectRevert();
        this.councilCall(a.upgradeAM, abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, call)));
    }

    /// @dev One Safe transaction from the Upgrade Council, for expectRevert.
    function councilCall(address to, bytes calldata data) external {
        _fromSafe(_config(), Actor.UpgradeCouncilSafe, to, data);
    }

}

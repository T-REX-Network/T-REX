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
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { Version } from "contracts/libraries/VersionLib.sol";
import { Token } from "contracts/token/Token.sol";
import { DeployConfig } from "scripts/deploy/lib/DeployConfig.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice Upgrade rehearsal: a live suite with balances is upgraded to a newly published release through the
///         Upgrade Council (schedule, five days, execute), then rolled back the only way the authority allows,
///         by republishing the previous implementations under a higher version. Storage outside governance and the
///         beacons is never written, balances survive both moves, and the token keeps working without
///         re-initialization.
/// @dev Until a second release exists, the "next" release is this release published again under its own salt:
///      same code, new addresses, which is everything the upgrade path cares about.
contract ForkUpgradeRehearsalTest is ForkBase {

    function test_upgradeThenRollBack() public {
        DeployConfig memory c = _config();
        _deployAndConfigure(c);
        _handOver(c);
        Token token = _suiteWithBalances(c, "rehearsal");
        Addrs memory before = _addresses(c);
        Addrs memory next = _releaseAddresses(c, REHEARSAL_SALT);
        assertTrue(next.tokenImpl != before.tokenImpl, "the rehearsal release must live elsewhere");

        // Upgrade: publish, schedule, five days, execute, with every storage write recorded.
        _run(c, _publishSteps(c, REHEARSAL_SALT), "publish");
        Version v1 = _version(c.versionMajor, c.versionMinor, c.versionPatch + 1);
        _run(c, _one(_scheduleSuiteUpgrade(c, REHEARSAL_SALT, v1)), "schedule");
        vm.warp(block.timestamp + c.codeDelay + 1);
        vm.startStateDiffRecording();
        _run(c, _one(_executeSuiteUpgrade(c, REHEARSAL_SALT, v1)), "execute");
        _assertOnlyGovernanceWrites(before, vm.stopAndReturnStateDiff());

        assertEq(UpgradeableBeacon(before.suiteBeacons[0]).implementation(), next.tokenImpl);
        assertEq(token.balanceOf(alice), 100, "balance after upgrade");
        _moves(token);

        // Rollback: the implementations the authority recorded under the initial version, read from the chain and
        // republished under a higher version. Nothing is rebuilt.
        Version v0 = _version(c.versionMajor, c.versionMinor, c.versionPatch);
        Version v2 = _version(c.versionMajor, c.versionMinor, c.versionPatch + 2);
        _run(c, _one(_scheduleRollback(c, v0, v2)), "rollback-schedule");
        vm.warp(block.timestamp + c.codeDelay + 1);
        _run(c, _one(_executeRollback(c, v0, v2)), "rollback-execute");
        assertEq(UpgradeableBeacon(before.suiteBeacons[0]).implementation(), before.tokenImpl);
        // `_moves` nets alice +5 (she sends 5, is minted 5, gets 5 back).
        assertEq(token.balanceOf(alice), 105, "balance after rollback");
        _moves(token);
        _assertVerified(c);
    }

    /// @dev A transfer each way and a mint: alice ends 5 up, bob unchanged.
    function _moves(Token token) internal {
        vm.prank(alice);
        token.transfer(bob, 5);
        vm.prank(agent);
        token.mint(alice, 5);
        vm.prank(bob);
        token.transfer(alice, 5);
    }

    /// @dev The upgrade may write to the Upgrade Council Safe (approvals, nonce), the Upgrade manager (consumed
    ///      schedule), the authority (version, implementations) and the five beacons. Nothing else.
    function _assertOnlyGovernanceWrites(Addrs memory a, Vm.AccountAccess[] memory accesses) internal pure {
        for (uint256 i = 0; i < accesses.length; i++) {
            for (uint256 j = 0; j < accesses[i].storageAccesses.length; j++) {
                Vm.StorageAccess memory s = accesses[i].storageAccesses[j];
                if (!s.isWrite || s.previousValue == s.newValue) continue;
                address who = s.account;
                bool allowed = who == a.upgradeCouncilSafe || who == a.upgradeAM || who == a.implementationAuthority;
                for (uint256 k = 0; k < 5; k++) {
                    if (who == a.suiteBeacons[k]) allowed = true;
                }
                require(allowed, "upgrade wrote storage outside governance and the beacons");
            }
        }
    }

}

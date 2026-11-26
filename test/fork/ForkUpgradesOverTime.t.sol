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
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { Version } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { Token } from "contracts/token/Token.sol";
import { IUUPS } from "scripts/deploy/PlanBuilder.sol";
import { DeployConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor } from "scripts/deploy/lib/PlanTypes.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice Upgrades as they will happen over the protocol's life: every proxy kind, the identity beacon, upgrades
///         and rollbacks scheduled together, isolated suites, and several releases in a row.
/// @dev "New" implementations are this release published again under another salt (same code, new addresses).
contract ForkUpgradesOverTimeTest is ForkBase {

    /// @dev ERC-1967 beacon slot, where a BeaconProxy keeps its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _upgradeProxy(DeployConfig memory c, address proxy, address impl) internal {
        _run(c, _one(_proxyUpgradeStep(c, proxy, impl, false)), "proxy-schedule");
        vm.warp(block.timestamp + c.codeDelay + 1);
        _run(c, _one(_proxyUpgradeStep(c, proxy, impl, true)), "proxy-execute");
        assertEq(_implementationOf(proxy), impl, "proxy implementation");
    }

    function test_moduleProxyUpgradeKeepsItsState() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        _upgradeProxy(c, a.spenderWhitelist, next.spenderWhitelistImpl);
        // Verification is strict about implementations: an upgraded one fails until it is listed as accepted.
        string[] memory failures = _verify(c, true, true);
        assertEq(failures.length, 1, "only the upgraded proxy is flagged");
        assertEq(failures[0], "SpenderWhitelistModule proxy implementation");
        acceptedImplementations.push(next.spenderWhitelistImpl);

        assertEq(IAccessManaged(a.spenderWhitelist).authority(), a.upgradeAM, "governance survives the upgrade");
        vm.expectRevert();
        IModuleInit(a.spenderWhitelist).initialize(stranger);
        _assertVerified(c);
    }

    function test_utilityCheckerUpgradeThroughTheManager() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        bytes memory direct = abi.encodeCall(IUUPS.upgradeToAndCall, (next.utilityCheckerImpl, ""));
        _expectSafeCallReverts(Actor.UpgradeCouncilSafe, a.utilityChecker, direct);
        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.utilityChecker, direct);

        _upgradeProxy(c, a.utilityChecker, next.utilityCheckerImpl);
        assertEq(Ownable(a.utilityChecker).owner(), a.upgradeAM, "still owned by the Upgrade manager");
    }

    function test_identityUtilitiesUpgrade() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        _upgradeProxy(c, a.identityUtilities, next.identityUtilitiesImpl);
        assertTrue(IAccessControl(a.identityUtilities).hasRole(DEFAULT_ADMIN_ROLE, a.upgradeAM), "admin survives");
        assertTrue(
            IAccessControl(a.identityUtilities).hasRole(TOPIC_MANAGER_ROLE, a.operationsSafe), "topic manager survives"
        );
    }

    /// @dev Every identity sits behind one beacon. Upgrading it moves all of them at once, keys and bindings intact.
    function test_identityBeaconUpgradeKeepsIdentities() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Token token = _suiteWithBalances(c, "identities");
        address aliceIdentity = address(_identityAt(a, alice));
        Addrs memory next = _publish(c, REHEARSAL_SALT);

        _scheduleAndExecute(
            c,
            Actor.UpgradeCouncilSafe,
            a.platformAM,
            a.identityFactory,
            abi.encodeCall(IdentityFactory.upgradeBeacon, (next.identityImpl, "3.0.0")),
            c.codeDelay
        );

        assertEq(UpgradeableBeacon(a.identityBeacon).implementation(), next.identityImpl, "identity beacon moved");
        assertTrue(
            IERC734(aliceIdentity).keyHasPurpose(keccak256(abi.encodePacked(alice)), KeyPurposes.MANAGEMENT),
            "keys survive"
        );
        assertEq(address(_identityAt(a, alice)), aliceIdentity, "binding survives");
        vm.prank(alice);
        token.transfer(bob, 25);
        assertEq(token.balanceOf(bob), 25, "transfers still pass the identity checks");
    }

    function test_upgradeAndRollbackScheduledTogether() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Token token = _suiteWithBalances(c, "both-ways");
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
        vm.warp(block.timestamp + c.codeDelay + 1);

        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, upgrade))
        );
        assertEq(UpgradeableBeacon(a.suiteBeacons[0]).implementation(), next.tokenImpl);
        assertEq(token.balanceOf(alice), 100);

        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, rollback))
        );
        assertEq(UpgradeableBeacon(a.suiteBeacons[0]).implementation(), a.tokenImpl);
        assertEq(token.balanceOf(alice), 100);
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    /// @dev An isolated suite owns its beacons: a shared upgrade moves every shared suite and leaves it alone.
    function test_isolatedSuiteUntouchedByASharedUpgrade() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        (Token shared,) = _deploySuite(c, "shared");
        _fromSafe(
            c,
            Actor.OperationsSafe,
            a.trexFactory,
            abi.encodeCall(ITREXFactory.deployTREXSuiteIsolated, ("isolated", _tokenDetails("isolated"), _noClaims()))
        );
        address isolated = ITREXFactory(a.trexFactory).getToken("isolated");
        address isolatedBeacon = address(uint160(uint256(vm.load(isolated, BEACON_SLOT))));
        assertTrue(isolatedBeacon != a.suiteBeacons[0], "isolated suite has its own token beacon");
        address isolatedImpl = UpgradeableBeacon(isolatedBeacon).implementation();

        Addrs memory next = _publish(c, REHEARSAL_SALT);
        _upgradeSuites(c, REHEARSAL_SALT, c.versionPatch + 1);

        address sharedBeacon = address(uint160(uint256(vm.load(address(shared), BEACON_SLOT))));
        assertEq(UpgradeableBeacon(sharedBeacon).implementation(), next.tokenImpl, "shared suite moved");
        assertEq(UpgradeableBeacon(isolatedBeacon).implementation(), isolatedImpl, "isolated suite untouched");
    }

    /// @dev Releases follow each other with suites deployed in between; every shared suite ends on the latest code.
    function test_twoReleasesInARow() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        Token first = _suiteWithBalances(c, "release-one");

        _publish(c, REHEARSAL_SALT);
        _upgradeSuites(c, REHEARSAL_SALT, c.versionPatch + 1);
        (Token second,) = _deploySuite(c, "release-two");
        _commissionAgent(second);
        _register(second, alice, _identityAt(a, alice));
        _register(second, bob, _identityAt(a, bob));
        vm.prank(agent);
        second.mint(alice, 50);

        Addrs memory last = _publish(c, SECOND_SALT);
        _upgradeSuites(c, SECOND_SALT, c.versionPatch + 2);

        assertEq(UpgradeableBeacon(a.suiteBeacons[0]).implementation(), last.tokenImpl, "latest code");
        assertEq(
            Version.unwrap(ITREXImplementationAuthority(a.implementationAuthority).currentVersion()),
            Version.unwrap(_version(c.versionMajor, c.versionMinor, c.versionPatch + 2))
        );
        vm.startPrank(alice);
        first.transfer(bob, 10);
        second.transfer(bob, 10);
        vm.stopPrank();
        assertEq(first.balanceOf(bob) + second.balanceOf(bob), 20);
        _assertVerified(c);
    }

}

/// @dev Every module's initializer.
interface IModuleInit {

    function initialize(address accessManager) external;

}

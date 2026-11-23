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
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import { ITREXFactory } from "contracts/factory/ITREXFactory.sol";
import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { DeployConfig, SafeConfig } from "scripts/deploy/lib/DeployConfig.sol";
import { Actor } from "scripts/deploy/lib/PlanTypes.sol";
import { RoleTable } from "scripts/deploy/lib/RoleTable.sol";
import { ISafeProxyFactory } from "scripts/deploy/lib/SafeLib.sol";

import { ForkBase } from "./ForkBase.sol";

/// @notice How governance evolves once the protocol is live: new operators, a new admin Safe, owner rotations,
///         delay changes, and the slowest path to remap a code function.
contract ForkGovernanceChangesTest is ForkBase {

    /// @dev A new operator joins. The Protocol Admin Safe's ROLE_MANAGER carries the power delay, so the grant is
    ///      scheduled and visible for 48 h before it can be sent, and then applies only after the role's grant
    ///      delay: a compromised Protocol Admin cannot slip in an operator unnoticed.
    function test_newOperatorWaitsForTheGrantDelay() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        address operator = makeAddr("new operator");
        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (RoleTable.tokenIssuer(), operator, 0));
        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.platformAM, grant);
        _scheduleAndExecute(c, Actor.ProtocolAdminSafe, a.platformAM, a.platformAM, grant, c.powerDelay);

        (bool member,) = IAccessManager(a.platformAM).hasRole(RoleTable.tokenIssuer(), operator);
        assertFalse(member, "not a member before the grant delay");
        ITREXFactory factory = ITREXFactory(a.trexFactory);
        ITREXFactory.TokenDetails memory details = _tokenDetails("new-operator");
        ITREXFactory.ClaimDetails memory claims = _noClaims();
        vm.prank(operator);
        vm.expectRevert();
        factory.deployTREXSuite("new-operator", details, claims);

        vm.warp(block.timestamp + c.configDelay + 1);
        (member,) = IAccessManager(a.platformAM).hasRole(RoleTable.tokenIssuer(), operator);
        assertTrue(member, "member once the grant delay has passed");
        vm.prank(operator);
        factory.deployTREXSuite("new-operator", details, claims);
        assertTrue(factory.getToken("new-operator") != address(0));
    }

    /// @dev The Protocol Admin Safe hands ADMIN to a new Safe. Its own ADMIN carries a 48 h execution delay and the
    ///      role a 48 h grant delay: the new Safe is admin no sooner than 96 h after the decision.
    function test_protocolAdminMovesToANewSafe() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        (SafeConfig memory nextCfg, address nextSafe) = _newSafe(0x5001, 0x5002, 0x5003);
        uint256 start = block.timestamp;

        bytes memory grant = abi.encodeCall(IAccessManager.grantRole, (RoleTable.ADMIN, nextSafe, c.powerDelay));
        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.platformAM, grant);
        _scheduleAndExecute(c, Actor.ProtocolAdminSafe, a.platformAM, a.platformAM, grant, c.powerDelay);

        (bool member,) = IAccessManager(a.platformAM).hasRole(RoleTable.ADMIN, nextSafe);
        assertFalse(member, "grant delay still running");
        vm.warp(start + 2 * uint256(c.powerDelay) + 2);
        uint32 delay;
        (member, delay) = IAccessManager(a.platformAM).hasRole(RoleTable.ADMIN, nextSafe);
        assertTrue(member, "admin after 96 h");
        assertEq(delay, c.powerDelay, "and still behind the 48 h execution delay");

        _fromSafe(
            c,
            Actor.ProtocolAdminSafe,
            a.platformAM,
            abi.encodeCall(IAccessManager.renounceRole, (RoleTable.ADMIN, a.protocolAdminSafe))
        );
        (member,) = IAccessManager(a.platformAM).hasRole(RoleTable.ADMIN, a.protocolAdminSafe);
        assertFalse(member, "old Safe out");

        // The new Safe governs: it schedules and executes an admin action of its own.
        bytes memory label = abi.encodeCall(IAccessManager.labelRole, (RoleTable.tokenIssuer(), "TOKEN_ISSUER_V2"));
        _execWithOwners(
            nextCfg, nextSafe, a.platformAM, abi.encodeCall(IAccessManager.schedule, (a.platformAM, label, 0))
        );
        vm.warp(block.timestamp + c.powerDelay + 1);
        _execWithOwners(nextCfg, nextSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.platformAM, label)));
    }

    /// @dev An Upgrade Council member leaves. The Safe swaps the owner with a transaction to itself; the new owner set
    ///      keeps every power, and the departed owner's approval no longer counts.
    function test_safeOwnerRotationKeepsPowers() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        SafeConfig memory council = c.upgradeCouncilSafe;
        address departed = council.owners[1];
        address joiner = address(0x3999);
        _fromSafe(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeCouncilSafe,
            abi.encodeWithSignature("swapOwner(address,address,address)", council.owners[0], departed, joiner)
        );

        SafeConfig memory rotated = SafeConfig(new address[](3), council.threshold, council.saltNonce);
        rotated.owners[0] = council.owners[0];
        rotated.owners[1] = joiner;
        rotated.owners[2] = council.owners[2];
        Addrs memory next = _publish(c, REHEARSAL_SALT);
        bytes memory upgrade = _upgradeCall(next, _version(c.versionMajor, c.versionMinor, c.versionPatch + 1));
        bytes memory schedule = abi.encodeCall(IAccessManager.schedule, (a.implementationAuthority, upgrade, 0));

        // The departed owner plus one current owner no longer reach the threshold.
        SafeConfig memory stale = SafeConfig(new address[](2), 2, council.saltNonce);
        stale.owners[0] = departed;
        stale.owners[1] = council.owners[0];
        vm.expectRevert();
        this.execWithOwners(stale, a.upgradeCouncilSafe, a.upgradeAM, schedule);

        _execWithOwners(rotated, a.upgradeCouncilSafe, a.upgradeAM, schedule);
        vm.warp(block.timestamp + c.codeDelay + 1);
        _execWithOwners(
            rotated,
            a.upgradeCouncilSafe,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.execute, (a.implementationAuthority, upgrade))
        );
    }

    /// @dev The Council shortens VERSION_MANAGER's grant delay from 5 days to 1. The manager's minimum setback keeps
    ///      the old delay in force for 5 more days after the change executes, so nobody can shorten and exploit it
    ///      in one go.
    function test_delayReductionWaitsForTheSetback() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        uint32 shorter = 1 days;
        _scheduleAndExecute(
            c,
            Actor.UpgradeCouncilSafe,
            a.upgradeAM,
            a.upgradeAM,
            abi.encodeCall(IAccessManager.setGrantDelay, (RoleTable.versionManager(), shorter)),
            c.codeDelay
        );
        uint256 setback = IAccessManager(a.upgradeAM).minSetback();
        assertEq(
            IAccessManager(a.upgradeAM).getRoleGrantDelay(RoleTable.versionManager()), c.codeDelay, "old delay holds"
        );
        vm.warp(block.timestamp + setback - 1);
        assertEq(
            IAccessManager(a.upgradeAM).getRoleGrantDelay(RoleTable.versionManager()), c.codeDelay, "until the setback"
        );
        vm.warp(block.timestamp + 2);
        assertEq(IAccessManager(a.upgradeAM).getRoleGrantDelay(RoleTable.versionManager()), shorter, "then the new one");
    }

    /// @dev The known limit (deploy/README.md): the Protocol Admin Safe, Platform ADMIN, could remap
    ///      `IdentityFactory.upgradeBeacon` to a role with no delay. It cannot do it fast: the IdentityFactory's
    ///      target admin delay is the code delay, longer than its own 48 h. Nothing can cancel it, since ADMIN
    ///      operations have no guardian; the window is for everyone to see it coming.
    function test_remappingACodeFunctionTakesAtLeastTheCodeDelay() public {
        DeployConfig memory c = _config();
        Addrs memory a = _live(c);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IdentityFactory.upgradeBeacon.selector;
        bytes memory remap = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (a.identityFactory, selectors, RoleTable.tokenIssuer())
        );

        _expectSafeCallReverts(Actor.ProtocolAdminSafe, a.platformAM, remap);
        _fromSafe(
            c, Actor.ProtocolAdminSafe, a.platformAM, abi.encodeCall(IAccessManager.schedule, (a.platformAM, remap, 0))
        );

        vm.warp(block.timestamp + c.powerDelay + 1);
        _expectSafeCallReverts(
            Actor.ProtocolAdminSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.platformAM, remap))
        );
        assertEq(
            IAccessManager(a.platformAM).getTargetFunctionRole(a.identityFactory, selectors[0]),
            RoleTable.versionManager()
        );

        vm.warp(block.timestamp + c.codeDelay - c.powerDelay);
        _fromSafe(
            c, Actor.ProtocolAdminSafe, a.platformAM, abi.encodeCall(IAccessManager.execute, (a.platformAM, remap))
        );
        assertEq(
            IAccessManager(a.platformAM).getTargetFunctionRole(a.identityFactory, selectors[0]), RoleTable.tokenIssuer()
        );
    }

    /// @dev A fresh Safe v1.4.1 with three placeholder owners and threshold 2, set up like the protocol's.
    function _newSafe(uint160 o1, uint160 o2, uint160 o3) internal returns (SafeConfig memory s, address safe) {
        s = SafeConfig(new address[](3), 2, 0);
        s.owners[0] = address(o1);
        s.owners[1] = address(o2);
        s.owners[2] = address(o3);
        safe = ISafeProxyFactory(BytecodeStore.SAFE_PROXY_FACTORY)
            .createProxyWithNonce(BytecodeStore.SAFE, _safeInitializer(s), 0);
    }

}

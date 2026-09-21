// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { VersionLib } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { MockTREXAccessManagerV2 } from "test/integration/mocks/MockTREXAccessManagerV2.sol";

contract TREXFactoryAccessManagerTest is TREXSuiteTest {

    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    address internal issuerAdmin = makeAddr("issuerAdmin");

    function test_deployTREXSuite_Success_DeploysAnAccessManagerWhenNoneIsSupplied() public {
        Token deployed = _deployWithFreshManager("fresh");
        TREXAccessManager manager = TREXAccessManager(IERC173(address(deployed)).owner());

        assertGt(address(manager).code.length, 0);
        assertEq(IERC173(address(deployed.identityRegistry())).owner(), address(manager));
        assertEq(IERC173(address(deployed.identityRegistry().identityStorage())).owner(), address(manager));
        assertEq(IERC173(address(deployed.compliance())).owner(), address(manager));

        (bool issuerIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), issuerAdmin);
        (bool factoryIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), address(trexFactory));
        assertTrue(issuerIsAdmin);
        assertFalse(factoryIsAdmin);
    }

    function test_deployTREXSuite_Success_FreshManagerIsCommissionedBeforeHandover() public {
        Token deployed = _deployWithFreshManager("wired");
        TREXAccessManager manager = TREXAccessManager(IERC173(address(deployed)).owner());
        address registry = address(deployed.identityRegistry());
        address irs = address(deployed.identityRegistry().identityStorage());
        uint32 ns = manager.namespaceOf(address(deployed));
        assertEq(ns, 1);
        assertEq(manager.namespaceCount(), 1);
        assertEq(manager.namespaceOf(irs), ns);

        assertEq(
            manager.getTargetFunctionRole(address(deployed), IERC3643.mint.selector),
            RolesLib.forNamespace(ns, RolesLib.Role.AGENT_MINTER)
        );
        assertEq(
            manager.getTargetFunctionRole(registry, IERC3643IdentityRegistry.registerIdentity.selector),
            RolesLib.forNamespace(ns, RolesLib.Role.AGENT)
        );
        (bool tokenIsAgent,) = manager.hasRole(RolesLib.forNamespace(ns, RolesLib.Role.AGENT), address(deployed));
        (bool registryWrites,) = manager.hasRole(RolesLib.forNamespace(ns, RolesLib.Role.AGENT), registry);
        assertTrue(tokenIsAgent);
        assertTrue(registryWrites);
        assertEq(
            manager.getRoleAdmin(RolesLib.forNamespace(ns, RolesLib.Role.AGENT)),
            RolesLib.forNamespace(ns, RolesLib.Role.AGENT_ADMIN)
        );
        (bool factoryIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), address(trexFactory));
        assertFalse(factoryIsAdmin);

        vm.startPrank(issuerAdmin);
        manager.grantRole(RolesLib.forNamespace(ns, RolesLib.Role.AGENT_ADMIN), issuerAdmin, 0);
        manager.grantRole(RolesLib.forNamespace(ns, RolesLib.Role.AGENT), agent, 0);
        manager.grantRole(RolesLib.forNamespace(ns, RolesLib.Role.AGENT_PAUSER), agent, 0);
        manager.grantRole(RolesLib.forNamespace(ns, RolesLib.Role.AGENT_MINTER), agent, 0);
        vm.stopPrank();
        vm.startPrank(agent);
        IERC3643IdentityRegistry(registry).registerIdentity(alice, aliceIdentity, 0);
        deployed.unpause();
        deployed.mint(alice, 100);
        vm.stopPrank();
        assertEq(deployed.balanceOf(alice), 100);
    }

    function test_deployTREXSuite_RevertWhen_AccessManagerAdminIsTheFactory() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidAccessManagerAdmin.selector);
        trexFactory.deployTREXSuite("self-admin", _details(address(0), address(trexFactory)), _noClaims());

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.InvalidAccessManagerAdmin.selector);
        trexFactory.deployTREXSuiteIsolated("self-admin", _details(address(0), address(trexFactory)), _noClaims());
    }

    function test_deployTREXSuite_RevertWhen_FreshManagerReusesAStorage() public {
        ITREXFactory.TokenDetails memory details = _details(address(0), issuerAdmin);
        details.irs = address(token.identityRegistry().identityStorage());

        vm.prank(deployer);
        vm.expectPartialRevert(ErrorsLib.StorageAuthorityMismatch.selector);
        trexFactory.deployTREXSuite("fresh-reused", details, _noClaims());
        assertEq(trexFactory.getToken("fresh-reused"), address(0));
    }

    function test_deployTREXSuite_Success_SuppliedIdentityKeysAreUntouched() public {
        address wallet = makeAddr("issuerWallet");
        address supplied = address(_deployIdentity(wallet, "supplied-oid"));
        ITREXFactory.TokenDetails memory details = _details(address(0), issuerAdmin);
        details.ONCHAINID = supplied;

        vm.prank(deployer);
        trexFactory.deployTREXSuite("supplied-oid", details, _noClaims());

        Token deployed = Token(trexFactory.getToken("supplied-oid"));
        assertEq(deployed.onchainID(), supplied);
        assertTrue(_isManager(supplied, wallet));
        assertFalse(_isManager(supplied, IERC173(address(deployed)).owner()));
        assertFalse(_isManager(supplied, address(trexFactory)));
    }

    function test_deployTREXSuiteIsolated_Success_SuppliedIdentityKeysAreUntouched() public {
        address wallet = makeAddr("issuerWallet");
        address supplied = address(_deployIdentity(wallet, "supplied-oid-isolated"));
        ITREXFactory.TokenDetails memory details = _details(address(0), issuerAdmin);
        details.ONCHAINID = supplied;

        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated("supplied-oid-isolated", details, _noClaims());

        Token deployed = Token(trexFactory.getToken("supplied-oid-isolated"));
        assertEq(deployed.onchainID(), supplied);
        assertTrue(_isManager(supplied, wallet));
        assertFalse(_isManager(supplied, IERC173(address(deployed)).owner()));
        assertFalse(_isManager(supplied, address(trexFactory)));
    }

    function test_deployTREXSuite_Success_FreshManagerHoldsTheIdentityManagementKey() public {
        Token deployed = _deployWithFreshManager("identity");
        address manager = IERC173(address(deployed)).owner();
        address oid = deployed.onchainID();

        assertTrue(_isManager(oid, manager));
        assertFalse(_isManager(oid, address(trexFactory)));
        assertFalse(_isManager(oid, address(accessManager)));

        vm.prank(issuerAdmin);
        TREXAccessManager(manager).execute(oid, _addKeyCall(another));
        assertTrue(_isManager(oid, another));
    }

    function test_upgrade_Success_ManagerKeepsAddressStateAndIdentityKey() public {
        Token deployed = _deployWithFreshManager("upgrade");
        TREXAccessManager manager = TREXAccessManager(IERC173(address(deployed)).owner());
        bytes32 beaconBefore = vm.load(address(manager), BEACON_SLOT);
        bytes4[] memory mint = new bytes4[](1);
        mint[0] = IERC3643.mint.selector;
        uint64 minter = RolesLib.forNamespace(1, RolesLib.Role.AGENT_MINTER);
        uint64 agentAdmin = RolesLib.forNamespace(1, RolesLib.Role.AGENT_ADMIN);
        uint64 suiteAdmin = RolesLib.forNamespace(1, RolesLib.Role.SUITE_ADMIN);
        vm.startPrank(issuerAdmin);
        manager.grantRole(agentAdmin, issuerAdmin, 0);
        manager.setTargetFunctionRole(address(deployed), mint, minter);
        manager.setRoleAdmin(minter, agentAdmin);
        manager.setRoleGuardian(minter, suiteAdmin);
        manager.setGrantDelay(minter, 2 hours);
        manager.grantRole(minter, agent, 1 hours);
        vm.stopPrank();
        vm.warp(block.timestamp + 6 days);

        ITREXImplementationAuthority.SuiteImplementations memory impls = _suiteImplementations();
        impls.accessManagerImplementation = address(new MockTREXAccessManagerV2());
        vm.prank(deployer);
        trexImplementationAuthority.publishAndUpgrade(VersionLib.pack(5, 0, 1), impls);

        assertEq(IERC173(address(deployed)).owner(), address(manager));
        assertEq(vm.load(address(manager), BEACON_SLOT), beaconBefore);
        assertEq(
            UpgradeableBeacon(trexImplementationAuthority.beacons().accessManagerBeacon).implementation(),
            impls.accessManagerImplementation
        );
        assertEq(MockTREXAccessManagerV2(address(manager)).version(), 2);
        (bool issuerIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), issuerAdmin);
        assertTrue(issuerIsAdmin);
        (bool agentIsMinter, uint32 executionDelay) = manager.hasRole(minter, agent);
        assertTrue(agentIsMinter);
        assertEq(executionDelay, 1 hours);
        assertEq(manager.getTargetFunctionRole(address(deployed), IERC3643.mint.selector), minter);
        assertEq(manager.getRoleAdmin(minter), agentAdmin);
        assertEq(manager.getRoleGuardian(minter), suiteAdmin);
        assertEq(manager.getRoleGrantDelay(minter), 2 hours);
        address oid = deployed.onchainID();
        assertTrue(_isManager(oid, address(manager)));
        vm.prank(issuerAdmin);
        manager.execute(oid, _addKeyCall(another));
        assertTrue(_isManager(oid, another));
    }

    function test_adminRotation_Success_NewAdminAdministersIdentityAndOldCannot() public {
        Token deployed = _deployWithFreshManager("rotate");
        TREXAccessManager manager = TREXAccessManager(IERC173(address(deployed)).owner());
        address oid = deployed.onchainID();
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(issuerAdmin);
        manager.grantRole(manager.ADMIN_ROLE(), newAdmin, 0);
        manager.renounceRole(manager.ADMIN_ROLE(), issuerAdmin);
        vm.stopPrank();

        vm.prank(newAdmin);
        manager.execute(oid, _addKeyCall(another));
        assertTrue(_isManager(oid, another));

        vm.prank(issuerAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCall.selector,
                issuerAdmin,
                oid,
                KeyManager.addKeyWithData.selector
            )
        );
        manager.execute(oid, _addKeyCall(bob));
        assertTrue(_isManager(oid, address(manager)));
    }

    function test_deployTREXSuiteIsolated_Success_ManagerBeaconIsOwnedByTheIssuerAdmin() public {
        vm.recordLogs();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated("isolated-fresh", _details(address(0), issuerAdmin), _noClaims());
        ITREXImplementationAuthority.SuiteBeacons memory beacons = _isolatedBeacons();
        Token deployed = Token(trexFactory.getToken("isolated-fresh"));
        address manager = IERC173(address(deployed)).owner();

        assertNotEq(beacons.accessManagerBeacon, trexImplementationAuthority.beacons().accessManagerBeacon);
        assertEq(UpgradeableBeacon(beacons.accessManagerBeacon).owner(), issuerAdmin);
        assertEq(UpgradeableBeacon(beacons.tokenBeacon).owner(), manager);
        assertEq(address(uint160(uint256(vm.load(manager, BEACON_SLOT)))), beacons.accessManagerBeacon);

        address newImplementation = address(new TREXAccessManager());
        vm.prank(issuerAdmin);
        UpgradeableBeacon(beacons.accessManagerBeacon).upgradeTo(newImplementation);
        assertEq(UpgradeableBeacon(beacons.accessManagerBeacon).implementation(), newImplementation);
        (bool issuerIsAdmin,) = TREXAccessManager(manager).hasRole(TREXAccessManager(manager).ADMIN_ROLE(), issuerAdmin);
        assertTrue(issuerIsAdmin);
    }

    function test_deployTREXSuiteIsolated_Success_AdminRotationMovesTheManagerBeaconOnlyWhenTransferred() public {
        vm.recordLogs();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated("isolated-rotate", _details(address(0), issuerAdmin), _noClaims());
        UpgradeableBeacon beacon = UpgradeableBeacon(_isolatedBeacons().accessManagerBeacon);
        TREXAccessManager manager = TREXAccessManager(IERC173(trexFactory.getToken("isolated-rotate")).owner());
        address newAdmin = makeAddr("newAdmin");
        address newImplementation = address(new TREXAccessManager());

        vm.startPrank(issuerAdmin);
        manager.grantRole(manager.ADMIN_ROLE(), newAdmin, 0);
        manager.renounceRole(manager.ADMIN_ROLE(), issuerAdmin);
        vm.stopPrank();

        (bool oldIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), issuerAdmin);
        assertFalse(oldIsAdmin);
        assertEq(beacon.owner(), issuerAdmin);
        vm.prank(newAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newAdmin));
        beacon.upgradeTo(newImplementation);

        vm.prank(issuerAdmin);
        beacon.transferOwnership(newAdmin);

        assertEq(beacon.owner(), newAdmin);
        vm.prank(issuerAdmin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, issuerAdmin));
        beacon.upgradeTo(newImplementation);
        vm.prank(newAdmin);
        beacon.upgradeTo(newImplementation);
        assertEq(beacon.implementation(), newImplementation);
    }

    function test_deployTREXSuiteIsolated_Success_SuppliedManagerGetsNoManagerBeacon() public {
        vm.recordLogs();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated(
            "isolated-supplied", _details(address(accessManager), address(0)), _noClaims()
        );
        ITREXImplementationAuthority.SuiteBeacons memory beacons = _isolatedBeacons();

        assertEq(beacons.accessManagerBeacon, address(0));
        assertEq(IERC173(trexFactory.getToken("isolated-supplied")).owner(), address(accessManager));
    }

    function test_deployTREXSuite_Success_SuppliedManagerIsUsedAsIs() public {
        vm.prank(deployer);
        trexFactory.deployTREXSuite("supplied", _details(address(accessManager), issuerAdmin), _noClaims());

        assertEq(IERC173(trexFactory.getToken("supplied")).owner(), address(accessManager));
        (bool issuerIsAdmin,) = accessManager.hasRole(accessManager.ADMIN_ROLE(), issuerAdmin);
        assertFalse(issuerIsAdmin);
    }

    function test_deployTREXSuite_RevertWhen_NeitherManagerNorAdminIsSupplied() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexFactory.deployTREXSuite("nothing", _details(address(0), address(0)), _noClaims());
    }

    function _deployWithFreshManager(string memory salt) private returns (Token) {
        vm.prank(deployer);
        trexFactory.deployTREXSuite(salt, _details(address(0), issuerAdmin), _noClaims());
        return Token(trexFactory.getToken(salt));
    }

    function _isolatedBeacons() private view returns (ITREXImplementationAuthority.SuiteBeacons memory beacons) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(trexFactory) && logs[i].topics[0] == EventsLib.IsolatedSuiteDeployed.selector
            ) {
                beacons = abi.decode(logs[i].data, (ITREXImplementationAuthority.SuiteBeacons));
            }
        }
        assertNotEq(beacons.tokenBeacon, address(0));
    }

    function _details(address manager, address admin) private pure returns (ITREXFactory.TokenDetails memory) {
        return ITREXFactory.TokenDetails({
            name: "Fresh",
            symbol: "FRS",
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: manager,
            accessManagerAdmin: admin
        });
    }

    function _noClaims() private pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

    function _isManager(address oid, address account) private view returns (bool) {
        return IERC734(oid).keyHasPurpose(keccak256(abi.encodePacked(account)), KeyPurposes.MANAGEMENT);
    }

    function _addKeyCall(address account) private pure returns (bytes memory) {
        bytes memory signerData = abi.encodePacked(account);
        return abi.encodeCall(
            KeyManager.addKeyWithData,
            (keccak256(signerData), KeyPurposes.MANAGEMENT, KeyTypes.ECDSA, signerData, bytes(""))
        );
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { KeyManager } from "@onchain-id/solidity/contracts/KeyManager.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
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

    function test_deployTREXSuite_Success_IssuerWiresTheFreshManager() public {
        Token deployed = _deployWithFreshManager("wired");
        TREXAccessManager manager = TREXAccessManager(IERC173(address(deployed)).owner());
        address registry = address(deployed.identityRegistry());
        address irs = address(deployed.identityRegistry().identityStorage());

        (bool tokenIsAgent,) = manager.hasRole(RolesLib.AGENT, address(deployed));
        (bool registryIsAgent,) = manager.hasRole(RolesLib.AGENT, registry);
        assertTrue(tokenIsAgent);
        assertTrue(registryIsAgent);
        assertEq(manager.getTargetFunctionRole(address(deployed), IERC3643.mint.selector), manager.ADMIN_ROLE());

        vm.startPrank(issuerAdmin);
        AccessManagerSetupLib.setupRoleAdmins(manager);
        AccessManagerSetupLib.setupTokenRoles(manager, address(deployed));
        AccessManagerSetupLib.setupTREXRegistryRoles(manager, registry);
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(manager, irs);
        manager.grantRole(RolesLib.AGENT_ADMIN, issuerAdmin, 0);
        manager.grantRole(RolesLib.AGENT, agent, 0);
        vm.stopPrank();

        assertEq(manager.getTargetFunctionRole(address(deployed), IERC3643.mint.selector), RolesLib.AGENT_MINTER);
        vm.prank(agent);
        IERC3643IdentityRegistry(registry).registerIdentity(alice, aliceIdentity, 0);
        assertTrue(IERC3643IdentityRegistry(registry).contains(alice));
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

    function test_upgrade_Success_ManagerKeepsAddressRolesAndIdentityKey() public {
        Token deployed = _deployWithFreshManager("upgrade");
        address manager = IERC173(address(deployed)).owner();
        bytes32 beaconBefore = vm.load(manager, BEACON_SLOT);

        ITREXImplementationAuthority.SuiteImplementations memory impls = _suiteImplementations();
        impls.accessManagerImplementation = address(new TREXAccessManager());
        vm.prank(deployer);
        trexImplementationAuthority.publishAndUpgrade(VersionLib.pack(5, 0, 1), impls);

        assertEq(IERC173(address(deployed)).owner(), manager);
        assertEq(vm.load(manager, BEACON_SLOT), beaconBefore);
        assertEq(
            UpgradeableBeacon(trexImplementationAuthority.beacons().accessManagerBeacon).implementation(),
            impls.accessManagerImplementation
        );
        (bool issuerIsAdmin,) = TREXAccessManager(manager).hasRole(TREXAccessManager(manager).ADMIN_ROLE(), issuerAdmin);
        assertTrue(issuerIsAdmin);
        address oid = deployed.onchainID();
        assertTrue(_isManager(oid, manager));
        vm.prank(issuerAdmin);
        TREXAccessManager(manager).execute(oid, _addKeyCall(another));
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

    function test_deployTREXSuiteIsolated_Success_ManagerBeaconIsOwnedByTheManager() public {
        vm.recordLogs();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated("isolated-fresh", _details(address(0), issuerAdmin), _noClaims());
        ITREXImplementationAuthority.SuiteBeacons memory beacons = _isolatedBeacons();
        Token deployed = Token(trexFactory.getToken("isolated-fresh"));
        address manager = IERC173(address(deployed)).owner();

        assertNotEq(beacons.accessManagerBeacon, trexImplementationAuthority.beacons().accessManagerBeacon);
        assertEq(UpgradeableBeacon(beacons.accessManagerBeacon).owner(), manager);
        assertEq(UpgradeableBeacon(beacons.tokenBeacon).owner(), manager);
        assertEq(address(uint160(uint256(vm.load(manager, BEACON_SLOT)))), beacons.accessManagerBeacon);

        address newImplementation = address(new TREXAccessManager());
        vm.prank(issuerAdmin);
        TREXAccessManager(manager)
            .execute(beacons.accessManagerBeacon, abi.encodeCall(UpgradeableBeacon.upgradeTo, (newImplementation)));
        assertEq(UpgradeableBeacon(beacons.accessManagerBeacon).implementation(), newImplementation);
        (bool issuerIsAdmin,) = TREXAccessManager(manager).hasRole(TREXAccessManager(manager).ADMIN_ROLE(), issuerAdmin);
        assertTrue(issuerIsAdmin);
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

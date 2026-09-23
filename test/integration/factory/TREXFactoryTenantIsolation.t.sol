// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm, VmSafe } from "@forge-std/Vm.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { Token } from "contracts/token/Token.sol";
import { IERC173 } from "contracts/vendor/IERC173.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TREXFactoryTenantIsolationTest is TREXSuiteTest {

    AccessManager internal victim;

    function setUp() public override {
        super.setUp();
        victim = new AccessManager(address(this));
    }

    function test_deployTREXSuite_Success_WhenFactoryHoldsNoRoleOnTargetAccessManager() public {
        vm.prank(deployer);
        trexFactory.deployTREXSuite("foreign", _details(address(victim)), _noClaims());

        Token deployed = Token(trexFactory.getToken("foreign"));
        assertEq(IERC173(address(deployed)).owner(), address(victim));
        assertEq(IERC173(address(deployed.identityRegistry())).owner(), address(victim));
    }

    function test_deployTREXSuite_MakesNoCallIntoTargetAccessManager_EvenWithLegacyPrivilege() public {
        _grantLegacyFactoryPrivilege();

        vm.startStateDiffRecording();
        vm.prank(deployer);
        trexFactory.deployTREXSuite("foreign", _details(address(victim)), _noClaims());
        _assertNoAccessTo(address(victim), vm.stopAndReturnStateDiff());

        Token deployed = Token(trexFactory.getToken("foreign"));
        (bool tokenIsAgent,) = victim.hasRole(_role(RolesLib.Role.AGENT), address(deployed));
        (bool registryIsAgent,) = victim.hasRole(_role(RolesLib.Role.AGENT), address(deployed.identityRegistry()));
        (bool deployerIsAgent,) = victim.hasRole(_role(RolesLib.Role.AGENT), deployer);
        assertFalse(tokenIsAgent);
        assertFalse(registryIsAgent);
        assertFalse(deployerIsAgent);
    }

    function test_deployTREXSuiteIsolated_MakesNoCallIntoTargetAccessManager_EvenWithLegacyPrivilege() public {
        _grantLegacyFactoryPrivilege();

        vm.startStateDiffRecording();
        vm.prank(deployer);
        trexFactory.deployTREXSuiteIsolated("foreign-isolated", _details(address(victim)), _noClaims());
        _assertNoAccessTo(address(victim), vm.stopAndReturnStateDiff());

        assertEq(IERC173(trexFactory.getToken("foreign-isolated")).owner(), address(victim));
    }

    function test_deployTREXSuite_Success_ReusedStorageIsBoundByTheIssuerAfterwards() public {
        IdentityRegistryStorage irs = IdentityRegistryStorage(address(token.identityRegistry().identityStorage()));
        ITREXFactory.TokenDetails memory details = _details(address(accessManager));
        details.irs = address(irs);

        vm.prank(deployer);
        trexFactory.deployTREXSuite("sibling", details, _noClaims());

        Token sibling = Token(trexFactory.getToken("sibling"));
        assertEq(address(sibling.identityRegistry().identityStorage()), address(irs));
        assertEq(irs.linkedIdentityRegistries().length, 1);
        (bool binder,) = accessManager.hasRole(_role(RolesLib.Role.IRS_BINDER), address(trexFactory));
        assertFalse(binder);

        address siblingRegistry = address(sibling.identityRegistry());
        _grantIRSBinderRole(address(this));
        irs.bindIdentityRegistry(siblingRegistry);
        assertEq(irs.linkedIdentityRegistries().length, 2);

        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, siblingRegistry, DOMAIN);
        _grantStorageWriterRole(siblingRegistry);
        address newcomer = makeAddr("newcomer");
        IIdentity newcomerIdentity = _deployIdentity(newcomer, "newcomer-oid");
        vm.prank(agent);
        IERC3643IdentityRegistry(siblingRegistry).registerIdentity(newcomer, newcomerIdentity, 0);
        assertTrue(IERC3643IdentityRegistry(siblingRegistry).contains(newcomer));
        assertEq(address(irs.storedIdentity(newcomer)), address(newcomerIdentity));
    }

    function _grantLegacyFactoryPrivilege() private {
        victim.grantRole(_role(RolesLib.Role.AGENT_ADMIN), address(trexFactory), 0);
        victim.grantRole(_role(RolesLib.Role.IRS_BINDER), address(trexFactory), 0);
        AccessManagerSetupLib.setupRoleAdmins(victim, DOMAIN);
    }

    function _assertNoAccessTo(address target, Vm.AccountAccess[] memory accesses) private pure {
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].kind == VmSafe.AccountAccessKind.Extcodesize) {
                continue;
            }
            assertNotEq(accesses[i].account, target);
        }
    }

    function _details(address manager) private pure returns (ITREXFactory.TokenDetails memory) {
        return ITREXFactory.TokenDetails({
            name: "Foreign",
            symbol: "FRN",
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: manager,
            accessManagerAdmin: address(0)
        });
    }

    function _noClaims() private pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

}

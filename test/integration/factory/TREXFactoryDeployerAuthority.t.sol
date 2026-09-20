// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";

contract TREXFactoryDeployerAuthorityTest is TREXSuiteTest {

    AccessManager internal victim;

    function setUp() public override {
        super.setUp();
        victim = new AccessManager(address(this));
    }

    function test_deployTREXSuite_RevertWhen_DeployerHasNoAuthorityOnTargetAccessManager() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.DeployerNotAuthorizedOnAccessManager.selector, deployer, address(victim))
        );
        trexFactory.deployTREXSuite("intrusion", _details(), _noClaims());

        assertEq(trexFactory.getToken("intrusion"), address(0));
    }

    function test_deployTREXSuiteIsolated_RevertWhen_DeployerHasNoAuthorityOnTargetAccessManager() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.DeployerNotAuthorizedOnAccessManager.selector, deployer, address(victim))
        );
        trexFactory.deployTREXSuiteIsolated("intrusion", _details(), _noClaims());

        assertEq(trexFactory.getToken("intrusion"), address(0));
    }

    function test_deployTREXSuite_Success_WhenDeployerIsAdminOfTargetAccessManager() public {
        victim.grantRole(victim.ADMIN_ROLE(), deployer, 0);

        vm.prank(deployer);
        trexFactory.deployTREXSuite("owned", _details(), _noClaims());

        assertNotEq(trexFactory.getToken("owned"), address(0));
    }

    function test_deployTREXSuite_Success_WhenTargetAccessManagerDelegatesDeployment() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TREXFactory.deployTREXSuite.selector;
        victim.setTargetFunctionRole(address(trexFactory), selectors, 4242);
        victim.grantRole(4242, deployer, 0);

        vm.prank(deployer);
        trexFactory.deployTREXSuite("delegated", _details(), _noClaims());

        assertNotEq(trexFactory.getToken("delegated"), address(0));
    }

    function test_deployTREXSuite_RevertWhen_DelegatedDeploymentHasExecutionDelay() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TREXFactory.deployTREXSuite.selector;
        victim.setTargetFunctionRole(address(trexFactory), selectors, 4242);
        victim.grantRole(4242, deployer, 1 days);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.DeployerNotAuthorizedOnAccessManager.selector, deployer, address(victim))
        );
        trexFactory.deployTREXSuite("delayed", _details(), _noClaims());
    }

    function _details() private view returns (ITREXFactory.TokenDetails memory) {
        return ITREXFactory.TokenDetails({
            name: "Victim",
            symbol: "VIC",
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(victim),
            accessManagerAdmin: address(0)
        });
    }

    function _noClaims() private pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

}

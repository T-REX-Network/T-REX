// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Test } from "@forge-std/Test.sol";
import { AccessManaged, IAccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";

contract TREXFactoryDeployTREXSuite is Test {

    TREXFactory trexFactory;

    AccessManager accessManager;

    constructor() {
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.OWNER, address(this), 0);

        address implementationAuthority = makeAddr("ImplementationAuthority");

        vm.mockCall(
            address(implementationAuthority),
            ITREXImplementationAuthority.getTokenImplementation.selector,
            abi.encode(address(0x01))
        );
        vm.mockCall(
            address(implementationAuthority),
            ITREXImplementationAuthority.getCTRImplementation.selector,
            abi.encode(address(0x01))
        );
        vm.mockCall(
            address(implementationAuthority),
            ITREXImplementationAuthority.getIRImplementation.selector,
            abi.encode(address(0x01))
        );
        vm.mockCall(
            address(implementationAuthority),
            ITREXImplementationAuthority.getIRSImplementation.selector,
            abi.encode(address(0x01))
        );
        vm.mockCall(
            address(implementationAuthority),
            ITREXImplementationAuthority.getMCImplementation.selector,
            abi.encode(address(0x01))
        );
        vm.mockCall(
            address(implementationAuthority),
            ITREXImplementationAuthority.getTIRImplementation.selector,
            abi.encode(address(0x01))
        );

        trexFactory = new TREXFactory(implementationAuthority, makeAddr("IdFactory"), address(accessManager));
        AccessManagerSetupLib.setupTREXFactoryRoles(accessManager, address(trexFactory));
    }

    function testRevertsWhenAccessManagerIsNotSet() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createTokenDetails(address(0));
        ITREXFactory.ClaimDetails memory claimDetails = _createClaimDetails();

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        trexFactory.deployTREXSuite("salt", tokenDetails, claimDetails);
    }

    function testRevertsWhenMissingRoleOnFactory() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createTokenDetails(address(accessManager));
        ITREXFactory.ClaimDetails memory claimDetails = _createClaimDetails();

        vm.expectRevert(ErrorsLib.FactoryMissingAdminRoleOnAccessManager.selector);
        trexFactory.deployTREXSuite("salt", tokenDetails, claimDetails);
    }

    function testRevertsWhenMissingAgentManagerRoleOnFactory() public {
        // ADMIN_ROLE but no AGENT_MANAGER
        accessManager.grantRole(0, address(trexFactory), 0);

        ITREXFactory.TokenDetails memory tokenDetails = _createTokenDetails(address(accessManager));
        ITREXFactory.ClaimDetails memory claimDetails = _createClaimDetails();

        vm.expectRevert(ErrorsLib.FactoryMissingAgentManagerRoleOnAccessManager.selector);
        trexFactory.deployTREXSuite("salt", tokenDetails, claimDetails);
    }

    // ----- Helpers -----

    function _createTokenDetails(address accessManagerAddress) internal returns (ITREXFactory.TokenDetails memory) {
        return ITREXFactory.TokenDetails({
            owner: makeAddr("Owner"),
            name: "Token",
            symbol: "TKN",
            decimals: 18,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: new address[](0),
            tokenAgents: new address[](0),
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: accessManagerAddress
        });
    }

    function _createClaimDetails() internal pure returns (ITREXFactory.ClaimDetails memory) {
        return ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });
    }

}

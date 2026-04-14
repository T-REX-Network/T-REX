// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { console } from "@forge-std/Script.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "contracts/factory/TREXFactory.sol";
import { TREXGateway } from "contracts/factory/TREXGateway.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/authority/TREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "contracts/registry/implementation/ClaimTopicsRegistry.sol";
import { IdentityRegistry } from "contracts/registry/implementation/IdentityRegistry.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TrustedIssuersRegistry } from "contracts/registry/implementation/TrustedIssuersRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { BaseDeployScript } from "scripts/BaseDeployScript.s.sol";

// forge script DeployTREXSuite --account deployerKey --sender DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
contract DeployTREXSuite is BaseDeployScript {

    function run() external {
        address deployer = msg.sender;
        address idFactoryAddress = _readAddress("onchainid.json", "idFactory");

        vm.startBroadcast();

        // Deploy AccessManager with deployer as initial admin
        AccessManager accessManager = AccessManager(
            _deployCreate3(
                _salt("AccessManager"), abi.encodePacked(type(AccessManager).creationCode, abi.encode(deployer))
            )
        );

        // Deploy implementations
        address tokenImpl = _deployCreate3(_salt("TokenImpl"), type(Token).creationCode);
        address irImpl = _deployCreate3(_salt("IdentityRegistryImpl"), type(IdentityRegistry).creationCode);
        address irsImpl =
            _deployCreate3(_salt("IdentityRegistryStorageImpl"), type(IdentityRegistryStorage).creationCode);
        address ctrImpl = _deployCreate3(_salt("ClaimTopicsRegistryImpl"), type(ClaimTopicsRegistry).creationCode);
        address tirImpl = _deployCreate3(_salt("TrustedIssuersRegistryImpl"), type(TrustedIssuersRegistry).creationCode);
        address mcImpl = _deployCreate3(_salt("ModularComplianceImpl"), type(ModularCompliance).creationCode);

        // Deploy TREX Implementation Authority
        address trexIA = _deployCreate3(
            _salt("TREXImplementationAuthority"),
            abi.encodePacked(
                type(TREXImplementationAuthority).creationCode,
                abi.encode(true, address(0), address(0), address(accessManager))
            )
        );

        TREXImplementationAuthority(trexIA)
            .addAndUseTREXVersion(
                ITREXImplementationAuthority.Version({ major: 5, minor: 0, patch: 0 }),
                ITREXImplementationAuthority.TREXContracts({
                    tokenImplementation: tokenImpl,
                    irImplementation: irImpl,
                    irsImplementation: irsImpl,
                    ctrImplementation: ctrImpl,
                    tirImplementation: tirImpl,
                    mcImplementation: mcImpl
                })
            );

        // Deploy factories
        address trexFactory = _deployCreate3(
            _salt("TREXFactory"),
            abi.encodePacked(
                type(TREXFactory).creationCode, abi.encode(trexIA, idFactoryAddress, address(accessManager))
            )
        );

        IdFactory(idFactoryAddress).addTokenFactory(trexFactory);

        address trexGateway = _deployCreate3(
            _salt("TREXGateway"),
            abi.encodePacked(type(TREXGateway).creationCode, abi.encode(trexFactory, false, address(accessManager)))
        );

        TREXImplementationAuthority(trexIA).setTREXFactory(trexFactory);

        // Setup roles for all infrastructure contracts
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(accessManager, trexIA);
        AccessManagerSetupLib.setupTREXFactoryRoles(accessManager, trexFactory);
        AccessManagerSetupLib.setupTREXGatewayRoles(accessManager, trexGateway);
        AccessManagerSetupLib.setupLabels(accessManager);

        // Grant OWNER role to deployer
        accessManager.grantRole(RolesLib.OWNER, deployer, 0);

        vm.stopBroadcast();

        console.log("AccessManager:", address(accessManager));
        console.log("Token implementation:", tokenImpl);
        console.log("IdentityRegistry implementation:", irImpl);
        console.log("IdentityRegistryStorage implementation:", irsImpl);
        console.log("ClaimTopicsRegistry implementation:", ctrImpl);
        console.log("TrustedIssuersRegistry implementation:", tirImpl);
        console.log("ModularCompliance implementation:", mcImpl);
        console.log("TREXImplementationAuthority:", trexIA);
        console.log("TREXFactory:", trexFactory);
        console.log("TREXGateway:", trexGateway);

        string memory json = "trexsuite";
        vm.serializeAddress(json, "accessManager", address(accessManager));
        vm.serializeAddress(json, "tokenImplementation", tokenImpl);
        vm.serializeAddress(json, "identityRegistryImplementation", irImpl);
        vm.serializeAddress(json, "identityRegistryStorageImplementation", irsImpl);
        vm.serializeAddress(json, "claimTopicsRegistryImplementation", ctrImpl);
        vm.serializeAddress(json, "trustedIssuersRegistryImplementation", tirImpl);
        vm.serializeAddress(json, "modularComplianceImplementation", mcImpl);
        vm.serializeAddress(json, "trexImplementationAuthority", trexIA);
        vm.serializeAddress(json, "trexFactory", trexFactory);
        string memory output = vm.serializeAddress(json, "trexGateway", trexGateway);

        _writeDeployment("trex-suite.json", output);
    }

}

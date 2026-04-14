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

// forge script DeployTREXFactory --account deployerKey --sender DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
contract DeployTREXFactory is BaseDeployScript {

    function run() external {
        address idFactoryAddress = _readAddress("onchainid.json", "idFactory");
        address trexIA = 0xC8DF198113a9dB6615378B8539AE3129824441FB;
        address accessManager = 0x5583477DEDD03FA6e62AA9F03e0Acd98434732ec;

        vm.startBroadcast();

        // Deploy factories
        address trexFactory = _deployCreate3(
            _salt("TREXFactory"),
            abi.encodePacked(
                type(TREXFactory).creationCode, abi.encode(trexIA, idFactoryAddress, address(accessManager))
            )
        );

        TREXImplementationAuthority(trexIA).setTREXFactory(trexFactory);

        console.log("TREXFactory:", trexFactory);

        vm.stopBroadcast();
    }

}

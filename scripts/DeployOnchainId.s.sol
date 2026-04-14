// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { console } from "@forge-std/Script.sol";
import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { ImplementationAuthority } from "@onchain-id/solidity/contracts/proxy/ImplementationAuthority.sol";

import { BaseDeployScript } from "scripts/BaseDeployScript.s.sol";

// forge script DeployOnchainId --account deployerKey --sender DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
contract DeployOnchainId is BaseDeployScript {

    function run() external {
        address deployer = msg.sender;
        address claimIssuerSigner = msg.sender; //vm.envAddress("CLAIM_ISSUER_SIGNER");

        vm.startBroadcast();

        address identityImpl = _deployCreate3(
            _salt("Identity"), abi.encodePacked(type(Identity).creationCode, abi.encode(deployer, true))
        );

        address implAuthority = _deployCreate3(
            _salt("ImplementationAuthority"),
            abi.encodePacked(type(ImplementationAuthority).creationCode, abi.encode(identityImpl, deployer))
        );

        address idFactory = _deployCreate3(
            _salt("IdFactory"),
            abi.encodePacked(type(IdFactory).creationCode, abi.encode(implAuthority, address(CREATEX), deployer))
        );

        address claimIssuer = _deployCreate3(
            _salt("ClaimIssuer"), abi.encodePacked(type(ClaimIssuer).creationCode, abi.encode(claimIssuerSigner))
        );

        vm.stopBroadcast();

        console.log("Identity implementation:", identityImpl);
        console.log("ImplementationAuthority:", implAuthority);
        console.log("IdFactory:", idFactory);
        console.log("ClaimIssuer:", claimIssuer);

        string memory json = "onchainid";
        vm.serializeAddress(json, "identityImplementation", identityImpl);
        vm.serializeAddress(json, "implementationAuthority", implAuthority);
        vm.serializeAddress(json, "idFactory", idFactory);
        string memory output = vm.serializeAddress(json, "claimIssuer", claimIssuer);

        _writeDeployment("onchainid.json", output);
    }

}

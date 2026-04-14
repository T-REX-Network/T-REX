// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { console } from "@forge-std/Script.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { Token } from "contracts/token/Token.sol";

import { BaseDeployScript } from "scripts/BaseDeployScript.s.sol";

// forge script DeployToken --account deployerKey --sender DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
contract DeployToken is BaseDeployScript {

    function run() external {
        address deployer = msg.sender;
        address trexFactoryAddress = _readAddress("trex-suite.json", "trexFactory");
        address agent = msg.sender; //vm.envAddress("AGENT");
        string memory salt = "Token-TKN"; //vm.envString("TOKEN_SALT");
        string memory name = "My Token"; //vm.envString("TOKEN_NAME");
        string memory symbol = "MTKN"; //vm.envString("TOKEN_SYMBOL");

        TREXFactory trexFactory = TREXFactory(trexFactoryAddress);

        address[] memory agents = new address[](1);
        agents[0] = agent;

        vm.startBroadcast();

        AccessManager tokenAccessManager = AccessManager(0x5583477DEDD03FA6e62AA9F03e0Acd98434732ec);

        // Deploy a dedicated AccessManager for this token suite
        /*
        AccessManager tokenAccessManager = AccessManager(
            _deployCreate3(
                _salt(string.concat("TokenAccessManager-", symbol)),
                abi.encodePacked(type(AccessManager).creationCode, abi.encode(deployer))
            )
        );
        */

        // Grant roles to TREXFactory so it can setup roles and call restricted functions during deployment
        tokenAccessManager.grantRole(0, trexFactoryAddress, 0);
        tokenAccessManager.grantRole(RolesLib.OWNER, trexFactoryAddress, 0);
        tokenAccessManager.grantRole(RolesLib.IDENTITY_ADMIN, trexFactoryAddress, 0);

        // Grant OWNER role to deployer
        tokenAccessManager.grantRole(RolesLib.OWNER, deployer, 0);

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: deployer,
            name: name,
            symbol: symbol,
            decimals: 0,
            irs: address(0),
            ONCHAINID: address(0),
            irAgents: agents,
            tokenAgents: agents,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            accessManager: address(tokenAccessManager)
        });

        ITREXFactory.ClaimDetails memory claimDetails = ITREXFactory.ClaimDetails({
            claimTopics: new uint256[](0), issuers: new address[](0), issuerClaims: new uint256[][](0)
        });

        trexFactory.deployTREXSuite(salt, tokenDetails, claimDetails);

        address tokenAddress = trexFactory.getToken(salt);
        Token token = Token(tokenAddress);

        // Setup labels on the token AccessManager
        //AccessManagerSetupLib.setupLabels(tokenAccessManager);

        vm.stopBroadcast();

        console.log("Token AccessManager:", address(tokenAccessManager));
        console.log("Token:", tokenAddress);
        console.log("IdentityRegistry:", address(token.identityRegistry()));
        console.log("Compliance:", address(token.compliance()));

        string memory json = "token";
        vm.serializeAddress(json, "accessManager", address(tokenAccessManager));
        vm.serializeAddress(json, "token", tokenAddress);
        vm.serializeAddress(json, "identityRegistry", address(token.identityRegistry()));
        string memory output = vm.serializeAddress(json, "compliance", address(token.compliance()));

        _writeDeployment(string.concat("token-", symbol, ".json"), output);
    }

}

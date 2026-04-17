// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { console } from "@forge-std/Script.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { ChainlinkReferenceCrossChainHook } from "contracts/hooks/ChainlinkReferenceCrossChainHook.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { Token } from "contracts/token/Token.sol";

import { BaseDeployScript } from "scripts/BaseDeployScript.s.sol";

// forge script DeployToken --account deployerKey --sender DEPLOYER_ADDRESS --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
contract DeployToken is BaseDeployScript {

    // Base Sepolia Chainlink CCIP endpoints.
    address constant CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant LINK_TOKEN = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;

    function run() external {
        string memory salt = "MCT";
        string memory symbol = "MCT";

        TREXFactory trexFactory = TREXFactory(_readAddress("trex-suite.json", "trexFactory"));

        vm.startBroadcast();

        AccessManager tokenAccessManager = AccessManager(0x5583477DEDD03FA6e62AA9F03e0Acd98434732ec);

        // Deploy a dedicated AccessManager for this token suite
        /*
        AccessManager tokenAccessManager = AccessManager(
            _deployCreate3(
                _salt(string.concat("TokenAccessManager-", symbol)),
                abi.encodePacked(type(AccessManager).creationCode, abi.encode(msg.sender))
            )
        );
        */

        _grantFactoryAndOwnerRoles(tokenAccessManager, address(trexFactory));

        address tokenAddress = _deployTrexSuite(trexFactory, tokenAccessManager, salt, symbol);
        Token token = Token(tokenAddress);

        // Setup labels on the token AccessManager
        //AccessManagerSetupLib.setupLabels(tokenAccessManager);

        address hook = _deployAndWireHook(tokenAccessManager, tokenAddress, symbol);

        vm.stopBroadcast();

        console.log("Token AccessManager:", address(tokenAccessManager));
        console.log("Token:", tokenAddress);
        console.log("IdentityRegistry:", address(token.identityRegistry()));
        console.log("Compliance:", address(token.compliance()));
        console.log("Hook:", hook);

        string memory json = "token";
        vm.serializeAddress(json, "accessManager", address(tokenAccessManager));
        vm.serializeAddress(json, "token", tokenAddress);
        vm.serializeAddress(json, "identityRegistry", address(token.identityRegistry()));
        vm.serializeAddress(json, "compliance", address(token.compliance()));
        string memory output = vm.serializeAddress(json, "hook", hook);

        _writeDeployment(string.concat("token-", symbol, ".json"), output);
    }

    function _grantFactoryAndOwnerRoles(AccessManager accessManager, address trexFactoryAddress) internal {
        // Grant roles to TREXFactory so it can setup roles and call restricted functions during deployment
        accessManager.grantRole(0, trexFactoryAddress, 0);
        accessManager.grantRole(RolesLib.OWNER, trexFactoryAddress, 0);
        accessManager.grantRole(RolesLib.IDENTITY_ADMIN, trexFactoryAddress, 0);

        // Grant OWNER role to deployer
        accessManager.grantRole(RolesLib.OWNER, msg.sender, 0);
    }

    function _deployTrexSuite(
        TREXFactory trexFactory,
        AccessManager tokenAccessManager,
        string memory salt,
        string memory symbol
    ) internal returns (address) {
        address[] memory agents = new address[](1);
        agents[0] = msg.sender;

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            owner: msg.sender,
            name: "My Crosschain Token",
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
        return trexFactory.getToken(salt);
    }

    function _deployAndWireHook(AccessManager tokenAccessManager, address tokenAddress, string memory symbol)
        internal
        returns (address)
    {
        ChainlinkReferenceCrossChainHook hook = ChainlinkReferenceCrossChainHook(
            _deployCreate3(
                _salt(string.concat("ChainlinkReferenceCrossChainHook-", symbol)),
                abi.encodePacked(
                    type(ChainlinkReferenceCrossChainHook).creationCode,
                    abi.encode(CCIP_ROUTER, LINK_TOKEN, address(tokenAccessManager), tokenAddress)
                )
            )
        );

        AccessManagerSetupLib.setupReferenceHookRoles(tokenAccessManager, address(hook), tokenAddress);

        tokenAccessManager.grantRole(RolesLib.HOOK_MANAGER, msg.sender, 0);
        Token(tokenAddress).setHook(address(hook));

        return address(hook);
    }

}

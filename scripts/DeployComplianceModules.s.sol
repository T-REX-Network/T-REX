// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderVerificationModule } from "contracts/compliance/modular/modules/SpenderVerificationModule.sol";
import { SpenderWhitelistModule } from "contracts/compliance/modular/modules/SpenderWhitelistModule.sol";

/// @dev Minimal surface for the token's `compliance()` getter, avoiding a full token import.
interface ITokenCompliance {

    function compliance() external view returns (address);

}

/// @title DeployComplianceModules
/// @notice Deploys the two standard compliance modules (spender verification + whitelist)
///         and binds them to every supplied token's ModularCompliance.
///
/// Each module is deployed once behind a `ModuleProxy` and shared across all the tokens:
/// the modules key their state per-compliance by bind nonce, so a single instance serves
/// many compliances. `addModule` is gated by the T-REX `OWNER` role, which the deployer
/// holds from the suite deployment.
///
/// Env:
///   DEPLOYER_PRIVATE_KEY  private key holding the T-REX OWNER role
///   ACCESS_MANAGER        the T-REX suite AccessManager (module upgrade authority)
///   TOKENS_ADDRESSES           comma-separated token addresses to bind against
///
/// Usage:
///   forge script scripts/DeployComplianceModules.s.sol --rpc-url baseSepolia --broadcast
contract DeployComplianceModules is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address accessManager = vm.envAddress("ACCESS_MANAGER");
        address[] memory tokens = vm.envAddress("TOKENS_ADDRESSES", ",");

        require(accessManager != address(0), "ACCESS_MANAGER not set");
        require(tokens.length > 0, "TOKENS_ADDRESSES empty");

        vm.startBroadcast(deployerKey);

        SpenderVerificationModule verificationImpl = new SpenderVerificationModule();
        SpenderVerificationModule verification = SpenderVerificationModule(
            address(
                new ModuleProxy(
                    address(verificationImpl), abi.encodeCall(SpenderVerificationModule.initialize, (accessManager))
                )
            )
        );

        SpenderWhitelistModule whitelistImpl = new SpenderWhitelistModule();
        SpenderWhitelistModule whitelist = SpenderWhitelistModule(
            address(
                new ModuleProxy(
                    address(whitelistImpl), abi.encodeCall(SpenderWhitelistModule.initialize, (accessManager))
                )
            )
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            address compliance = ITokenCompliance(tokens[i]).compliance();
            require(compliance != address(0), "token has no compliance");
            IModularCompliance(compliance).addModule(address(verification));
            IModularCompliance(compliance).addModule(address(whitelist));
            console.log("Bound modules to token:", tokens[i], "compliance:", compliance);
        }

        vm.stopBroadcast();

        console.log("SpenderVerificationModule impl: ", address(verificationImpl));
        console.log("SpenderVerificationModule proxy:", address(verification));
        console.log("SpenderWhitelistModule impl:    ", address(whitelistImpl));
        console.log("SpenderWhitelistModule proxy:   ", address(whitelist));
    }

}

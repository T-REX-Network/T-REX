// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { SpenderVerificationModule } from "contracts/compliance/modular/modules/SpenderVerificationModule.sol";
import { SpenderWhitelistModule } from "contracts/compliance/modular/modules/SpenderWhitelistModule.sol";

/// @dev Minimal surface for the token's `compliance()` getter, avoiding a full token import.
interface ITokenCompliance {

    function compliance() external view returns (address);

}

/// @title DeployComplianceModules
/// @notice Deploys the three standard compliance modules (spender verification, spender whitelist,
///         max balance per identity) and binds them to every supplied token's ModularCompliance.
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

    /// @dev The cap the max-balance module is bound with: one million whole tokens at 18 decimals, so no
    ///      seeded position ever meets it.
    uint256 internal constant MAX_BALANCE = 1_000_000 * 10 ** 18;

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

        MaxBalancePerIdentityModule maxBalanceImpl = new MaxBalancePerIdentityModule();
        MaxBalancePerIdentityModule maxBalance = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(maxBalanceImpl), abi.encodeCall(MaxBalancePerIdentityModule.initialize, (accessManager))
                )
            )
        );

        bytes[] memory maxBalanceSettings = new bytes[](1);
        maxBalanceSettings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (MAX_BALANCE));

        for (uint256 i = 0; i < tokens.length; i++) {
            address compliance = ITokenCompliance(tokens[i]).compliance();
            require(compliance != address(0), "token has no compliance");
            IModularCompliance(compliance).addModule(address(verification));
            IModularCompliance(compliance).addModule(address(whitelist));
            IModularCompliance(compliance).addAndSetModule(address(maxBalance), maxBalanceSettings);
            console.log("Bound modules to token:", tokens[i], "compliance:", compliance);
        }

        vm.stopBroadcast();

        console.log("SpenderVerificationModule impl: ", address(verificationImpl));
        console.log("SpenderVerificationModule proxy:", address(verification));
        console.log("SpenderWhitelistModule impl:    ", address(whitelistImpl));
        console.log("SpenderWhitelistModule proxy:   ", address(whitelist));
        console.log("MaxBalancePerIdentityModule impl: ", address(maxBalanceImpl));
        console.log("MaxBalancePerIdentityModule proxy:", address(maxBalance));
    }

}

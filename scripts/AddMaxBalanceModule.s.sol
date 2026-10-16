// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";

interface ITokenCompliance {

    function compliance() external view returns (address);

}

/// @title AddMaxBalanceModule
/// @notice Deploys the max-balance-per-identity module behind a `ModuleProxy` and binds it, configured
///         with a cap no seeded position meets, to every supplied token's ModularCompliance.
///
/// A follow-up to `DeployComplianceModules.s.sol` for a deployment whose compliance-module step ran
/// the two-module version of that script. The spender modules it bound are left alone; this adds the
/// third module the console catalog lists. `addAndSetModule` is gated by the suite `OWNER` role, which
/// the deployer holds on every seeded suite.
///
/// Usage (from T-REX/):
///   ACCESS_MANAGER=<platform AccessManager> TOKENS_ADDRESSES=<gold token> \
///     forge script scripts/AddMaxBalanceModule.s.sol --rpc-url baseSepolia --broadcast --slow --verify
contract AddMaxBalanceModule is Script {

    /// @dev One million whole tokens at 18 decimals, so no seeded position ever meets the cap.
    uint256 internal constant MAX_BALANCE = 1_000_000 * 10 ** 18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address accessManager = vm.envAddress("ACCESS_MANAGER");
        address[] memory tokens = vm.envAddress("TOKENS_ADDRESSES", ",");

        require(accessManager != address(0), "ACCESS_MANAGER not set");
        require(tokens.length > 0, "TOKENS_ADDRESSES empty");

        vm.startBroadcast(deployerKey);

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
            require(!IModularCompliance(compliance).isModuleBound(address(maxBalance)), "already bound");
            IModularCompliance(compliance).addAndSetModule(address(maxBalance), maxBalanceSettings);
            console.log("Bound max-balance module to token:", tokens[i], "compliance:", compliance);
        }

        vm.stopBroadcast();

        console.log("MaxBalancePerIdentityModule impl: ", address(maxBalanceImpl));
        console.log("MaxBalancePerIdentityModule proxy:", address(maxBalance));
    }

}

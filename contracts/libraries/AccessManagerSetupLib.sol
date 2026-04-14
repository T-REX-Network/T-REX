// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma solidity ^0.8.30;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";

import { ModularCompliance } from "../compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "../factory/TREXFactory.sol";
import { TREXGateway } from "../factory/TREXGateway.sol";
import { TREXImplementationAuthority } from "../proxy/authority/TREXImplementationAuthority.sol";
import { ClaimTopicsRegistry } from "../registry/implementation/ClaimTopicsRegistry.sol";
import { IdentityRegistry } from "../registry/implementation/IdentityRegistry.sol";
import { IdentityRegistryStorage } from "../registry/implementation/IdentityRegistryStorage.sol";
import { TrustedIssuersRegistry } from "../registry/implementation/TrustedIssuersRegistry.sol";
import { Token } from "../token/Token.sol";
import { RolesLib } from "./RolesLib.sol";

/// @title AccessManagerSetupLib
/// @notice Library for setting up roles and functions in AccessManager for the TREX suite contracts
library AccessManagerSetupLib {

    function setupTokenRoles(IAccessManager accessManager, address token) external {
        // ------ TOKEN_ADMIN role ------
        bytes4[] memory functions = new bytes4[](2);
        functions[0] = Token.setName.selector;
        functions[1] = Token.setSymbol.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.TOKEN_ADMIN);

        // ------ IDENTITY_ADMIN role ------
        functions = new bytes4[](3);
        functions[0] = Token.setOnchainID.selector;
        functions[1] = Token.setIdentityRegistry.selector;
        functions[2] = Token.setCompliance.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.IDENTITY_ADMIN);

        // ------ INFRA_ADMIN role ------
        functions = new bytes4[](1);
        functions[0] = Token.setTrustedForwarder.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.INFRA_ADMIN);

        // ------ SPENDING_ADMIN role ------
        functions = new bytes4[](1);
        functions[0] = Token.setAllowanceForAll.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.SPENDING_ADMIN);

        // ------ AGENT_MINTER role ------
        functions = new bytes4[](2);
        functions[0] = Token.mint.selector;
        functions[1] = Token.batchMint.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_MINTER);

        // ------ AGENT_BURNER role ------
        functions = new bytes4[](2);
        functions[0] = Token.burn.selector;
        functions[1] = Token.batchBurn.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_BURNER);

        // ------ AGENT_PARTIAL_FREEZER role ------
        functions = new bytes4[](4);
        functions[0] = Token.freezePartialTokens.selector;
        functions[1] = Token.batchFreezePartialTokens.selector;
        functions[2] = Token.unfreezePartialTokens.selector;
        functions[3] = Token.batchUnfreezePartialTokens.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_PARTIAL_FREEZER);

        // ------ AGENT_ADDRESS_FREEZER role ------
        functions = new bytes4[](2);
        functions[0] = Token.setAddressFrozen.selector;
        functions[1] = Token.batchSetAddressFrozen.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_ADDRESS_FREEZER);

        // ------ AGENT_RECOVERY_ADDRESS role ------
        functions = new bytes4[](1);
        functions[0] = Token.recoveryAddress.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_RECOVERY_ADDRESS);

        // ------ AGENT_FORCED_TRANSFER role ------
        functions = new bytes4[](2);
        functions[0] = Token.forcedTransfer.selector;
        functions[1] = Token.batchForcedTransfer.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_FORCED_TRANSFER);

        // ------ AGENT_PAUSER role ------
        functions = new bytes4[](2);
        functions[0] = Token.pause.selector;
        functions[1] = Token.unpause.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.AGENT_PAUSER);

        // ------ HOOK_MANAGER role ------
        functions = new bytes4[](1);
        functions[0] = Token.setHook.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.HOOK_MANAGER);

        // ------ HOOK role ------
        functions = new bytes4[](1);
        functions[0] = Token.onTransferSettled.selector;
        accessManager.setTargetFunctionRole(token, functions, RolesLib.HOOK);
    }

    function setupClaimTopicsRegistryRoles(IAccessManager accessManager, address claimTopicsRegistry) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](2);
        functions[0] = ClaimTopicsRegistry.addClaimTopic.selector;
        functions[1] = ClaimTopicsRegistry.removeClaimTopic.selector;
        accessManager.setTargetFunctionRole(claimTopicsRegistry, functions, RolesLib.OWNER);
    }

    function setupIdentityRegistryRoles(IAccessManager accessManager, address identityRegistry) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](5);
        functions[0] = IdentityRegistry.setIdentityRegistryStorage.selector;
        functions[1] = IdentityRegistry.setClaimTopicsRegistry.selector;
        functions[2] = IdentityRegistry.setTrustedIssuersRegistry.selector;
        functions[3] = IdentityRegistry.disableEligibilityChecks.selector;
        functions[4] = IdentityRegistry.enableEligibilityChecks.selector;
        accessManager.setTargetFunctionRole(identityRegistry, functions, RolesLib.OWNER);

        // ------ AGENT role ------
        functions = new bytes4[](4);
        functions[0] = IdentityRegistry.updateIdentity.selector;
        functions[1] = IdentityRegistry.updateCountry.selector;
        functions[2] = IdentityRegistry.deleteIdentity.selector;
        functions[3] = IdentityRegistry.registerIdentity.selector;
        accessManager.setTargetFunctionRole(identityRegistry, functions, RolesLib.AGENT);
    }

    function setupIdentityRegistryStorageRoles(IAccessManager accessManager, address identityRegistryStorage) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](2);
        functions[0] = IdentityRegistryStorage.bindIdentityRegistry.selector;
        functions[1] = IdentityRegistryStorage.unbindIdentityRegistry.selector;
        accessManager.setTargetFunctionRole(identityRegistryStorage, functions, RolesLib.OWNER);

        // ------ AGENT role ------
        functions = new bytes4[](4);
        functions[0] = IdentityRegistryStorage.addIdentityToStorage.selector;
        functions[1] = IdentityRegistryStorage.modifyStoredIdentity.selector;
        functions[2] = IdentityRegistryStorage.modifyStoredInvestorCountry.selector;
        functions[3] = IdentityRegistryStorage.removeIdentityFromStorage.selector;
        accessManager.setTargetFunctionRole(identityRegistryStorage, functions, RolesLib.AGENT);
    }

    function setupTrustedIssuersRegistryRoles(IAccessManager accessManager, address trustedIssuersRegistry) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](3);
        functions[0] = TrustedIssuersRegistry.addTrustedIssuer.selector;
        functions[1] = TrustedIssuersRegistry.removeTrustedIssuer.selector;
        functions[2] = TrustedIssuersRegistry.updateIssuerClaimTopics.selector;
        accessManager.setTargetFunctionRole(trustedIssuersRegistry, functions, RolesLib.OWNER);
    }

    function setupModularComplianceRoles(IAccessManager accessManager, address modularCompliance) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](4);
        functions[0] = ModularCompliance.removeModule.selector;
        functions[1] = ModularCompliance.addAndSetModule.selector;
        functions[2] = ModularCompliance.addModule.selector;
        functions[3] = ModularCompliance.callModuleFunction.selector;
        accessManager.setTargetFunctionRole(modularCompliance, functions, RolesLib.OWNER);
    }

    function setupTREXGatewayRoles(IAccessManager accessManager, address trexGateway) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](10);
        functions[0] = TREXGateway.setFactory.selector;
        functions[1] = TREXGateway.setPublicDeploymentStatus.selector;
        functions[2] = TREXGateway.enableDeploymentFee.selector;
        functions[3] = TREXGateway.setDeploymentFee.selector;
        functions[4] = TREXGateway.batchAddDeployer.selector;
        functions[5] = TREXGateway.addDeployer.selector;
        functions[6] = TREXGateway.batchRemoveDeployer.selector;
        functions[7] = TREXGateway.removeDeployer.selector;
        functions[8] = TREXGateway.batchApplyFeeDiscount.selector;
        functions[9] = TREXGateway.applyFeeDiscount.selector;
        accessManager.setTargetFunctionRole(trexGateway, functions, RolesLib.OWNER);

        // ------ AGENT role ------
        functions = new bytes4[](6);
        functions[0] = TREXGateway.batchAddDeployer.selector;
        functions[1] = TREXGateway.addDeployer.selector;
        functions[2] = TREXGateway.batchRemoveDeployer.selector;
        functions[3] = TREXGateway.removeDeployer.selector;
        functions[4] = TREXGateway.batchApplyFeeDiscount.selector;
        functions[5] = TREXGateway.applyFeeDiscount.selector;
        accessManager.setTargetFunctionRole(trexGateway, functions, RolesLib.AGENT);
    }

    function setupTREXFactoryRoles(IAccessManager accessManager, address trexFactory) external {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](3);
        functions[0] = TREXFactory.setImplementationAuthority.selector;
        functions[1] = TREXFactory.setIdFactory.selector;
        functions[2] = TREXFactory.deployTREXSuite.selector;
        accessManager.setTargetFunctionRole(trexFactory, functions, RolesLib.OWNER);
    }

    function setupTREXImplementationAuthorityRoles(IAccessManager accessManager, address trexImplementationAuthority)
        external
    {
        // ------ OWNER role ------
        bytes4[] memory functions = new bytes4[](5);
        functions[0] = TREXImplementationAuthority.setTREXFactory.selector;
        functions[1] = TREXImplementationAuthority.setIAFactory.selector;
        functions[2] = TREXImplementationAuthority.addTREXVersion.selector;
        functions[3] = TREXImplementationAuthority.useTREXVersion.selector;
        functions[4] = TREXImplementationAuthority.addAndUseTREXVersion.selector;
        accessManager.setTargetFunctionRole(trexImplementationAuthority, functions, RolesLib.OWNER);
    }

    function setupReferenceHookRoles(IAccessManager accessManager, address hook, address token) external {
        // ------ TOKEN role on hook (token calls sendAuthorization) ------
        bytes4[] memory functions = new bytes4[](1);
        functions[0] = bytes4(keccak256("sendAuthorization(uint64,bytes32,uint64,address,address,uint256)"));
        accessManager.setTargetFunctionRole(hook, functions, RolesLib.TOKEN);

        // ------ HOOK_MANAGER role on hook (admin configures bridged peers) ------
        bytes4[] memory adminFns = new bytes4[](2);
        adminFns[0] = bytes4(keccak256("configureBridgedHook(uint64,bytes32)"));
        adminFns[1] = bytes4(keccak256("setGasLimit(uint200)"));
        accessManager.setTargetFunctionRole(hook, adminFns, RolesLib.HOOK_MANAGER);

        // The hook contract must hold the HOOK role so it can call Token.onTransferSettled.
        accessManager.grantRole(RolesLib.HOOK, hook, 0);
        // The token contract must hold the TOKEN role so it can call hook.sendAuthorization.
        accessManager.grantRole(RolesLib.TOKEN, token, 0);
    }

    struct RoleLabel {
        uint64 roleId;
        string label;
    }

    function setupLabels(IAccessManager accessManager) external {
        RoleLabel[16] memory labels = [
            RoleLabel({ roleId: RolesLib.OWNER, label: "TREX-Suite Owner" }),
            RoleLabel({ roleId: RolesLib.AGENT, label: "TREX-Suite Agent" }),
            RoleLabel({ roleId: RolesLib.AGENT_MINTER, label: "TREX-Suite Agent: Minter" }),
            RoleLabel({ roleId: RolesLib.AGENT_BURNER, label: "TREX-Suite Agent: Burner" }),
            RoleLabel({ roleId: RolesLib.AGENT_PARTIAL_FREEZER, label: "TREX-Suite Agent: Partial Freezer" }),
            RoleLabel({ roleId: RolesLib.AGENT_ADDRESS_FREEZER, label: "TREX-Suite Agent: Address Freezer" }),
            RoleLabel({ roleId: RolesLib.AGENT_RECOVERY_ADDRESS, label: "TREX-Suite Agent: Recovery Address" }),
            RoleLabel({ roleId: RolesLib.AGENT_FORCED_TRANSFER, label: "TREX-Suite Agent: Forced Transfer" }),
            RoleLabel({ roleId: RolesLib.AGENT_PAUSER, label: "TREX-Suite Agent: Pauser" }),
            RoleLabel({ roleId: RolesLib.TOKEN_ADMIN, label: "TREX-Suite Admin: Token" }),
            RoleLabel({ roleId: RolesLib.IDENTITY_ADMIN, label: "TREX-Suite Admin: Identity" }),
            RoleLabel({ roleId: RolesLib.INFRA_ADMIN, label: "TREX-Suite Admin: Infra" }),
            RoleLabel({ roleId: RolesLib.SPENDING_ADMIN, label: "TREX-Suite Admin: Spending" }),
            RoleLabel({ roleId: RolesLib.HOOK_MANAGER, label: "TREX-Suite Hook Manager" }),
            RoleLabel({ roleId: RolesLib.HOOK, label: "TREX-Suite Hook" }),
            RoleLabel({ roleId: RolesLib.TOKEN, label: "TREX-Suite Token" })
        ];

        bytes[] memory calls = new bytes[](labels.length);
        for (uint256 i = 0; i < labels.length; i++) {
            calls[i] = abi.encodeCall(IAccessManager.labelRole, (labels[i].roleId, labels[i].label));
        }
        Multicall(address(accessManager)).multicall(calls);
    }

}

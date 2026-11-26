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

pragma solidity 0.8.30;

import { RolesLib } from "contracts/libraries/RolesLib.sol";

/// @title RoleTable
/// @notice The role vocabulary of the two protocol AccessManagers after the handover.
/// @dev Platform AccessManager: governs the TREXFactory, the TrustedGatewayRegistry, the IdentityFactory and the
///      ReputationRegistry. Upgrade AccessManager: governs the TREXImplementationAuthority (suite beacons), the
///      compliance module proxies, the UtilityChecker and the IdentityUtilities.
///
///      T-REX ids come from {RolesLib} (`PlatformRole` entries, or names through `RolesLib.platform(bytes32)`).
///      The ONCHAINID identity-creation roles are named through RolesLib too (one vocabulary on the manager; the
///      IdentityFactory stores whatever role id a type policy names). The ASSET and SMART_CONTRACT types are gated
///      by T-REX's ASSET_DEPLOYER, because the TREXFactory mints token identities with that role.
///
///      Who holds what (OpenZeppelin review, delay tiers from the config):
///      - Protocol Admin Safe: Platform ADMIN and ROLE_MANAGER (power delay), GUARDIAN on both managers (none).
///      - RoleRevoker (a contract): ROLE_MANAGER (none), so any Platform ADMIN holder revokes operational roles at once.
///      - Upgrade Council Safe: VERSION_MANAGER on both managers and Upgrade ADMIN (code delay).
///      - Operations Safe: TOKEN_ISSUER (none), INTEROP_MANAGER and REPUTATION_MANAGER (config delay), the
///        identity-creation roles (none: the IdentityFactory refuses an execution delay on them; they get a grant
///        delay instead).
///      - TREXFactory (a contract): ASSET_DEPLOYER (none), so it can mint token identities.
library RoleTable {

    uint64 internal constant ADMIN = 0;

    // Names the platform roles hash into (RolesLib.platform(bytes32)).
    bytes32 private constant CLAIM_ISSUER_ADMIN_NAME = "CLAIM_ISSUER_ADMIN";
    bytes32 private constant ISSUER_NAME = "ISSUER";
    bytes32 private constant PUBLIC_AUTHORITY_NAME = "PUBLIC_AUTHORITY";
    bytes32 private constant ROLE_MANAGER_NAME = "ROLE_MANAGER";
    bytes32 private constant GUARDIAN_NAME = "GUARDIAN";
    bytes32 private constant TOKEN_ISSUER_NAME = "TOKEN_ISSUER";
    bytes32 private constant REPUTATION_MANAGER_NAME = "REPUTATION_MANAGER";

    /// @dev ONCHAINID identity-creation roles: claim issuer admins, issuers, public authorities.
    function claimIssuerAdmin() internal pure returns (uint64) {
        return RolesLib.platform(CLAIM_ISSUER_ADMIN_NAME);
    }

    function issuer() internal pure returns (uint64) {
        return RolesLib.platform(ISSUER_NAME);
    }

    function publicAuthority() internal pure returns (uint64) {
        return RolesLib.platform(PUBLIC_AUTHORITY_NAME);
    }

    /// @dev Admin of the operational roles. The RoleRevoker holds it with no delay (revocation at once); the
    ///      Protocol Admin Safe holds it behind the power delay (grants are visible before they apply).
    function roleManager() internal pure returns (uint64) {
        return RolesLib.platform(ROLE_MANAGER_NAME);
    }

    /// @dev Cancels scheduled operations of the delayed roles; cannot execute anything.
    function guardian() internal pure returns (uint64) {
        return RolesLib.platform(GUARDIAN_NAME);
    }

    /// @dev Everything that changes code: suite versions, beacon upgrades, proxy upgrades, the factory setters.
    function versionManager() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER);
    }

    /// @dev Deploys token suites through the TREXFactory.
    function tokenIssuer() internal pure returns (uint64) {
        return RolesLib.platform(TOKEN_ISSUER_NAME);
    }

    /// @dev Held by the TREXFactory: lets it create ASSET identities for the tokens it deploys.
    function assetDeployer() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.ASSET_DEPLOYER);
    }

    /// @dev Trusted gateways. Hardcoded by `AccessManagerSetupLib.setupTrustedGatewayRegistryRoles` too.
    function interopManager() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.INTEROP_MANAGER);
    }

    function reputationManager() internal pure returns (uint64) {
        return RolesLib.platform(REPUTATION_MANAGER_NAME);
    }

}

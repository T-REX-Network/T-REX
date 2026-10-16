// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "contracts/factory/TREXFactory.sol";
import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { VersionLib } from "contracts/libraries/VersionLib.sol";
import {
    ITREXImplementationAuthority,
    TREXImplementationAuthority
} from "contracts/proxy/beacon/TREXImplementationAuthority.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";

/**
 * @title DeployTREX
 * @notice Deploys the T-REX suite factory stack (everything short of an actual token suite).
 *
 * Deployment order (linear — each contract only needs addresses that already exist):
 *   1. The platform AccessManager. It governs the factory, the implementation authority and
 *      the gateway registry through platform roles (RolesLib.platform). Suite roles are not
 *      here: each suite the seeders deploy gets its own TREXAccessManager from the factory.
 *   2. The five suite implementations: Token, IdentityRegistryStorage, ModularCompliance,
 *      TREXRegistry (the merged IR/TIR/CTR registry — needs the ONCHAINID IdentityFactory
 *      address to read an identity's type for per-type claim topic checks) and
 *      TREXAccessManager (for suites that ask the factory for their own manager).
 *   3. TREXImplementationAuthority, seeded with v1.0.0 and the five implementations above.
 *      It self-deploys the five beacons the whole suite proxies through.
 *   4. TrustedGatewayRegistry (interop), then TREXFactory, wired to the implementation
 *      authority, the ONCHAINID IdentityFactory, the gateway registry and the AccessManager.
 *   5. Platform role wiring + grants so the deployer can publish versions, trust gateways and
 *      deploy suites afterward.
 *
 * This script does NOT deploy the ONCHAINID stack — that is a separate, already-deployed
 * shared protocol (see ../ONCHAINID/scripts/DeployOnchainID.s.sol). It reads the deployed
 * IdentityFactory address from ONCHAINID_IDENTITY_FACTORY.
 *
 * This script does NOT deploy a token suite either. `trexFactory.deployTREXSuite(...)`
 * belongs to scripts/SeedActivity.s.sol, which needs to create several varied suites and
 * explicit ONCHAINID ASSET/SMART_CONTRACT identities to back them.
 *
 * Reads DEPLOYER_PRIVATE_KEY and ONCHAINID_IDENTITY_FACTORY from the environment (see
 * .env.example). Optional FINAL_ADMIN_ADDRESS rotates ADMIN_ROLE + VERSION_MANAGER off the
 * deployer once setup is done; omit it (or set it equal to the deployer) to leave the
 * deployer in control.
 *
 * Usage:
 *   forge script scripts/DeployTREX.s.sol --rpc-url baseSepolia --broadcast --verify
 */
contract DeployTREX is Script {

    /// @dev The platform roles, as test/integration/helpers/AccessManagerHelper.sol picks them: the suite
    ///      deployer is a named platform role, the three setters the default vocabulary.
    function _suiteDeployerRole() internal pure returns (uint64) {
        return RolesLib.platform(bytes32("TOKEN_ISSUER"));
    }

    function _platformOwnerRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.OWNER);
    }

    function _versionManagerRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER);
    }

    function _interopManagerRole() internal pure returns (uint64) {
        return RolesLib.platform(RolesLib.PlatformRole.INTEROP_MANAGER);
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address idFactory = vm.envAddress("ONCHAINID_IDENTITY_FACTORY");

        vm.startBroadcast(deployerKey);

        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);
        console.log("ONCHAINID IdentityFactory:", idFactory);
        console.log("");

        // 1. AccessManager. The deployer starts as the AccessManager admin (`ADMIN_ROLE = 0`).
        //    Production deployments should rotate this to a multisig immediately via
        //    `am.grantRole(0, multisig, 0); am.revokeRole(0, deployer);` (see the admin
        //    handoff at the end of this script for the optional automated version).
        AccessManager am = new AccessManager(deployer);
        console.log("AccessManager:", address(am));

        // Suite roles are not laid out here: every suite the seeders deploy asks the factory
        // for its own TREXAccessManager (TokenDetails.accessManager == 0), which lays out its
        // domain itself at initialisation. The platform manager only governs the factory, the
        // implementation authority and the gateway registry, through platform roles.

        // 2. The five suite implementations. Deployed once; every suite proxies through the
        //    beacons the TREXImplementationAuthority owns.
        Token tokenImplementation = new Token();
        IdentityRegistryStorage irsImplementation = new IdentityRegistryStorage();
        ModularCompliance mcImplementation = new ModularCompliance();
        // Only ever used behind a beacon proxy; its constructor disables initializers.
        TREXAccessManager amImplementation = new TREXAccessManager();
        // TREXRegistry bakes the ONCHAINID IdentityFactory in as an immutable: it reads an
        // identity's type from the factory's own record for per-identity-type claim topics.
        TREXRegistry trexRegistryImplementation = new TREXRegistry(idFactory);
        console.log("Token implementation:                  ", address(tokenImplementation));
        console.log("IdentityRegistryStorage implementation:", address(irsImplementation));
        console.log("ModularCompliance implementation:      ", address(mcImplementation));
        console.log("TREXRegistry implementation:           ", address(trexRegistryImplementation));
        console.log("TREXAccessManager implementation:      ", address(amImplementation));

        // 3. TREXImplementationAuthority. Seeded with v1.0.0 for this deploy (the fixture used
        //    for reference seeds a throwaway 5.0.0 for test convenience only). The constructor
        //    deploys and owns the 5 beacons, so there is no separate version-pinning call.
        ITREXImplementationAuthority.SuiteImplementations memory impls =
            ITREXImplementationAuthority.SuiteImplementations({
                tokenImplementation: address(tokenImplementation),
                trexRegistryImplementation: address(trexRegistryImplementation),
                irsImplementation: address(irsImplementation),
                mcImplementation: address(mcImplementation),
                accessManagerImplementation: address(amImplementation)
            });
        TREXImplementationAuthority ia = new TREXImplementationAuthority(address(am), VersionLib.pack(1, 0, 0), impls);
        console.log("TREXImplementationAuthority:           ", address(ia));

        // Wires publish/upgrade/publishAndUpgrade to VERSION_MANAGER, then grants it to the
        // deployer so future versions can be published from this key.
        AccessManagerSetupLib.setupTREXImplementationAuthorityRoles(am, address(ia), _versionManagerRole());
        am.grantRole(_versionManagerRole(), deployer, 0);

        // Platform OWNER repoints the factory's identity factory; TOKEN_ISSUER (a named
        // platform role, distinct from the three setter roles as the factory wiring requires)
        // deploys suites. Both granted to the deployer so the seeders can run from this key.
        am.grantRole(_platformOwnerRole(), deployer, 0);
        am.grantRole(_suiteDeployerRole(), deployer, 0);

        ITREXImplementationAuthority.SuiteBeacons memory beacons = ia.beacons();
        console.log("  Token beacon:                        ", beacons.tokenBeacon);
        console.log("  TREXRegistry beacon:                 ", beacons.trexRegistryBeacon);
        console.log("  IdentityRegistryStorage beacon:      ", beacons.irsBeacon);
        console.log("  ModularCompliance beacon:            ", beacons.mcBeacon);
        console.log("  TREXAccessManager beacon:            ", beacons.accessManagerBeacon);

        // 4. TrustedGatewayRegistry (cross-chain interop allow-list) and TREXFactory.
        TrustedGatewayRegistry trustedGatewayRegistry = new TrustedGatewayRegistry(address(am));
        console.log("TrustedGatewayRegistry:                ", address(trustedGatewayRegistry));
        AccessManagerSetupLib.setupTrustedGatewayRegistryRoles(
            am, address(trustedGatewayRegistry), _interopManagerRole()
        );
        am.grantRole(_interopManagerRole(), deployer, 0);

        TREXFactory trexFactory = new TREXFactory(address(ia), idFactory, address(trustedGatewayRegistry), address(am));
        console.log("TREXFactory:                           ", address(trexFactory));

        // deployTREXSuite/deployTREXSuiteIsolated go to TOKEN_ISSUER; each setter goes to the
        // platform role that already owns its subject (version manager, interop manager,
        // platform owner). The suites the seeders deploy ask the factory for their own
        // TREXAccessManager, which lays out the suite's roles itself.
        AccessManagerSetupLib.setupTREXFactoryRoles(
            am,
            address(trexFactory),
            _suiteDeployerRole(),
            _versionManagerRole(),
            _interopManagerRole(),
            _platformOwnerRole()
        );

        // Deliberately NOT granting ASSET_DEPLOYER (ONCHAINID's role id 1, gating ASSET /
        // SMART_CONTRACT identity minting) to trexFactory here. That would let
        // `deployTREXSuite` auto-mint a token OID whenever `TokenDetails.ONCHAINID` is left at
        // address(0) — a standing cross-protocol trust grant this deploy script should not
        // make on its own. The seeder (scripts/SeedActivity.s.sol) instead holds
        // ASSET_DEPLOYER on its own key, creates explicit ASSET/SMART_CONTRACT identities via
        // ONCHAINID's `createIdentityFor`, and passes the real address as
        // `TokenDetails.ONCHAINID`. Nothing to do here beyond this comment.

        // ===== Admin handoff =====
        // FINAL_ADMIN_ADDRESS is optional. Unset (or equal to the deployer) leaves the
        // deployer holding ADMIN_ROLE and VERSION_MANAGER — fine for a throwaway/dev deploy.
        // Set it to rotate both roles to the real owner and strip the deployer's access to
        // them; grant-then-revoke order keeps the AccessManager from ever having zero admins
        // mid-transaction. OWNER, TOKEN_ISSUER and INTEROP_MANAGER deliberately stay with the
        // deployer for v1 — same scope choice as DeployOnchainID.s.sol's own admin handoff:
        // they are the smaller, higher-frequency operational roles the deployer needs to keep
        // driving suite deployments day-to-day, not the account that can rewrite the
        // AccessManager's own rules.
        address finalAdmin = vm.envOr("FINAL_ADMIN_ADDRESS", deployer);
        if (finalAdmin != deployer) {
            am.grantRole(am.ADMIN_ROLE(), finalAdmin, 0);
            am.grantRole(_versionManagerRole(), finalAdmin, 0);
            am.revokeRole(_versionManagerRole(), deployer);
            am.revokeRole(am.ADMIN_ROLE(), deployer);
            console.log("Admin + version-manager rotated to:", finalAdmin);
            console.log("Deployer access to ADMIN_ROLE / VERSION_MANAGER revoked.");
        } else {
            console.log("FINAL_ADMIN_ADDRESS unset - deployer retains admin + version-manager roles.");
        }

        vm.stopBroadcast();

        // ===== Summary =====
        console.log("");
        console.log("========== Deployment Summary ==========");
        console.log("AccessManager:                  ", address(am));
        console.log("Token implementation:            ", address(tokenImplementation));
        console.log("IdentityRegistryStorage impl:    ", address(irsImplementation));
        console.log("ModularCompliance implementation:", address(mcImplementation));
        console.log("TREXRegistry implementation:     ", address(trexRegistryImplementation));
        console.log("TREXAccessManager implementation:", address(amImplementation));
        console.log("TREXImplementationAuthority:     ", address(ia));
        console.log("  Token beacon:                  ", beacons.tokenBeacon);
        console.log("  TREXRegistry beacon:            ", beacons.trexRegistryBeacon);
        console.log("  IdentityRegistryStorage beacon: ", beacons.irsBeacon);
        console.log("  ModularCompliance beacon:       ", beacons.mcBeacon);
        console.log("  TREXAccessManager beacon:       ", beacons.accessManagerBeacon);
        console.log("TrustedGatewayRegistry:          ", address(trustedGatewayRegistry));
        console.log("TREXFactory:                     ", address(trexFactory));
        console.log("ONCHAINID IdentityFactory (input):", idFactory);
        console.log("=========================================");
    }

}

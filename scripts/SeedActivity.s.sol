// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IIdentity, Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { IKeyExecutor } from "@onchain-id/solidity/contracts/interface/IKeyExecutor.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { ERC734Validator } from "@onchain-id/solidity/contracts/modules/validators/ERC734Validator.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";

/**
 * @title SeedActivity
 * @notice Generates realistic, varied on-chain activity across ONCHAINID and T-REX so a
 *         subgraph indexing both protocols has real data in every field: identities of every
 *         type, key adds/removes, claims (issued + one revoked), account linking, several
 *         token suites (some claim-gated, some not) and the standard token lifecycle
 *         (register, mint, transfer, forcedTransfer, freeze/unfreeze, setAddressFrozen, burn)
 *         plus trusted-issuer / claim-topic churn on one suite's TREXRegistry.
 *
 * Explicitly out of scope for v1 (do not add without reworking this header comment): pause /
 * unpause, recovery flows, deployTREXSuiteIsolated, compliance modules (every seeded suite
 * ships with zero modules), EAS claim issuers.
 *
 * ===== Environment =====
 *   DEPLOYER_PRIVATE_KEY        broadcasts every tx; also acts as most of the "logical actors"
 *                                below (see SEED_ACTOR_KEY_1 / _2 to widen caller diversity).
 *   ONCHAINID_IDENTITY_FACTORY  the shared ONCHAINID IdentityFactory (see
 *                                ../ONCHAINID/scripts/DeployOnchainID.s.sol). Its AccessManager
 *                                is read back via `idFactory.authority()` — not a separate env
 *                                var.
 *   TREX_FACTORY                the TREXFactory produced by scripts/DeployTREX.s.sol. Its
 *                                AccessManager is read back via `trexFactory.authority()`.
 *   SEED_ACTOR_KEY_1 (optional) extra private keys used only to self-deploy additional
 *   SEED_ACTOR_KEY_2 (optional) INDIVIDUAL identities and widen `msg.sender` diversity on-chain.
 *                                Unset (0) skips that actor; the deployer alone still seeds one
 *                                INDIVIDUAL and every createIdentityFor-based type.
 *
 * ===== Idempotency =====
 * The setup checks on-chain state first (getIdentity / getToken / getKey / getClaim already
 * non-zero -> skip), so it is idempotent; the activity (key add/remove, link/revoke, forced
 * transfer, freezes, burn, issuer and topic add/remove) is added again on each run. Role gates that
 * the deployer might not hold (ROLE_CLAIM_ISSUER_ADMIN survives an admin rotation, etc.) are
 * checked with `hasRole` before the call, not try/catch: a call made under vm.startBroadcast is
 * still queued for broadcast by forge even when its revert is caught in Solidity, and later
 * fails "Simulated execution failed" in forge's separate broadcast-simulation pass — try/catch
 * does not make a broadcasted call optional. Every new identity and token suite is also
 * appended to a JSONL log for quick off-chain inspection:
 *   deployments/tokens.baseSepolia.jsonl               (this repo)      — token suites
 *   ../ONCHAINID/deployments/identities.baseSepolia.jsonl (sibling repo, absolute path — see
 *                                                          ONCHAINID_DEPLOYMENTS_DIR)
 *
 * Usage:
 *   forge script scripts/SeedActivity.s.sol --rpc-url baseSepolia --broadcast
 */
contract SeedActivity is Script {

    // ---- ONCHAINID role ids (must match ../ONCHAINID/scripts/DeployOnchainID.s.sol) ----
    uint64 internal constant ROLE_TOKEN_FACTORY = 1;
    uint64 internal constant ROLE_CLAIM_ISSUER_ADMIN = 2;
    uint64 internal constant ROLE_ISSUER = 4;
    uint64 internal constant ROLE_PUBLIC_AUTHORITY = 5;

    /// @dev Token base unit. The seed suites use 18 decimals, so every human-readable amount
    ///      below is multiplied by this to get the on-chain integer value.
    uint256 internal constant UNIT = 10 ** 18;

    /// @dev The domain a factory-deployed TREXAccessManager lays its suite out in: the first and
    ///      only domain of a manager created by `initializeSuite`.
    uint32 internal constant DOMAIN = 1;

    uint256 internal constant CLAIM_TOPIC_KYC = uint256(keccak256("SEED_CLAIM_TOPIC_KYC"));
    uint256 internal constant CLAIM_TOPIC_ACCREDITED = uint256(keccak256("SEED_CLAIM_TOPIC_ACCREDITED"));

    /// @dev Set in run() from NETWORK_NAME (default baseSepolia): deployments/tokens.<net>.jsonl
    string internal tokensLog;

    /// @dev forge's fs_permissions sandbox rejects any path containing a ".." component
    ///      outright, so this can't be a "../ONCHAINID/..." relative literal — it has to be
    ///      absolute, and has to match an fs_permissions entry in foundry.toml exactly.
    ///      ONCHAINID_DEPLOYMENTS_DIR overrides the sibling checkout's location; update the
    ///      matching entry in foundry.toml if you set it to something other than the default.
    string internal identitiesLog;

    IdentityFactory internal idFactory;
    AccessManager internal onchainAM;
    TREXFactory internal trexFactory;
    AccessManager internal trexAM;
    address internal validatorModule;

    address internal deployer;
    uint256 internal deployerKey;

    // Identities seeded this run, reused across later phases.
    address internal individual0Identity;
    address internal corporate0Identity;
    address internal iot0Identity;
    address internal aiAgent0Identity;
    address internal claimIssuer0Identity;
    address internal claimIssuer1Identity;
    uint256 internal claimIssuer0SignerKey;
    uint256 internal claimIssuer1SignerKey;

    address internal corporate0Wallet;
    address internal iot0Wallet;
    address internal aiAgent0Wallet;

    function run() external {
        require(
            block.chainid == 31337 || block.chainid == 84532 || block.chainid == 936486,
            "seed scripts run on test chains only: anvil, Base Sepolia or the T-REX Testnet"
        );
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        idFactory = IdentityFactory(vm.envAddress("ONCHAINID_IDENTITY_FACTORY"));
        trexFactory = TREXFactory(vm.envAddress("TREX_FACTORY"));
        onchainAM = AccessManager(idFactory.authority());
        trexAM = AccessManager(trexFactory.authority());
        validatorModule = idFactory.getIdentityTypeModules(IdentityTypes.INDIVIDUAL)[0].module;

        string memory onchainIdDeploymentsDir =
            vm.envOr("ONCHAINID_DEPLOYMENTS_DIR", string("../ONCHAINID/deployments"));
        // NETWORK_NAME selects the record files, matching the deploy-and-record.sh convention
        // (deployments/<NETWORK_NAME>.json). Defaults to the Base Sepolia reference deployment.
        string memory networkName = vm.envOr("NETWORK_NAME", string("baseSepolia"));
        identitiesLog = string.concat(onchainIdDeploymentsDir, "/identities.", networkName, ".jsonl");
        tokensLog = string.concat("deployments/tokens.", networkName, ".jsonl");

        console.log("Deployer:", deployer);
        console.log("ONCHAINID IdentityFactory:", address(idFactory));
        console.log("ONCHAINID AccessManager:  ", address(onchainAM));
        console.log("TREXFactory:              ", address(trexFactory));
        console.log("TREX AccessManager:       ", address(trexAM));
        console.log("");

        vm.startBroadcast(deployerKey);

        _ensureOnchainRoles();

        _seedIndividuals();
        _seedCorporateIotAiAgent();
        _seedClaimIssuers();
        _seedPublicAuthority();

        _seedKeys();
        _seedClaims();
        _seedAccountLinking();

        (address suite0Token, address suite1Token) = _seedTokenSuites();
        if (suite0Token != address(0)) {
            _seedTokenActivity(suite0Token);
            _seedTrustedIssuersAndClaimTopics(suite0Token);
        }
        if (suite1Token != address(0)) {
            _seedGatedSuiteActivity(suite1Token);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("========== Seeding Summary ==========");
        console.log("individual0 identity:", individual0Identity);
        console.log("corporate0 identity: ", corporate0Identity);
        console.log("iot0 identity:       ", iot0Identity);
        console.log("aiAgent0 identity:   ", aiAgent0Identity);
        console.log("claimIssuer0 identity:", claimIssuer0Identity);
        console.log("claimIssuer1 identity:", claimIssuer1Identity);
        console.log("======================================");
    }

    // ============ ONCHAINID role bootstrap ============

    /// @dev Grants the seeder's own key every ONCHAINID role it touches an identity-type gate
    ///      with (ROLE_TOKEN_FACTORY, ROLE_CLAIM_ISSUER_ADMIN, ROLE_ISSUER,
    ///      ROLE_PUBLIC_AUTHORITY) if it doesn't already hold them, so a fresh deployment seeds
    ///      every identity type out of the box. Only possible while the deployer still holds
    ///      ADMIN_ROLE there (none of these roles were granted to the deployer by
    ///      DeployOnchainID.s.sol itself, and its own admin handoff only ever rotates
    ///      ADMIN_ROLE + the beacon-upgrader role) — if ADMIN_ROLE was already rotated away,
    ///      the corresponding identity types are skipped further down with a log line rather
    ///      than reverting the whole run.
    function _ensureOnchainRoles() internal {
        (bool isAdmin,) = onchainAM.hasRole(onchainAM.ADMIN_ROLE(), deployer);
        if (!isAdmin) {
            console.log("WARNING: deployer lacks ADMIN_ROLE on the ONCHAINID AccessManager;");
            console.log("         role grants below will be skipped if not already held, and the");
            console.log("         identity types they gate will be skipped too.");
            return;
        }
        _grantIfMissing(onchainAM, ROLE_TOKEN_FACTORY, deployer);
        _grantIfMissing(onchainAM, ROLE_CLAIM_ISSUER_ADMIN, deployer);
        _grantIfMissing(onchainAM, ROLE_ISSUER, deployer);
        _grantIfMissing(onchainAM, ROLE_PUBLIC_AUTHORITY, deployer);
    }

    /// @dev A suite role id scoped to DOMAIN (see RolesLib.forDomain).
    function _role(RolesLib.Role role) internal pure returns (uint64) {
        return RolesLib.forDomain(DOMAIN, role);
    }

    function _grantIfMissing(AccessManager am, uint64 role, address account) internal {
        (bool isMember,) = am.hasRole(role, account);
        if (!isMember) {
            am.grantRole(role, account, 0);
        }
    }

    function _grantIfMissing(TREXAccessManager am, uint64 role, address account) internal {
        (bool isMember,) = am.hasRole(role, account);
        if (!isMember) {
            am.grantRole(role, account, 0);
        }
    }

    function _hasRole(AccessManager am, uint64 role, address account) internal view returns (bool isMember) {
        (isMember,) = am.hasRole(role, account);
    }

    /// @dev The suite roles the seeder acts under, granted in the suite's own TREXAccessManager
    ///      (the factory deploys one per suite and lays DOMAIN out in it). The deployer is that
    ///      manager's admin, which appoints AGENT_ADMIN and SUITE_ADMIN; those two appoint the
    ///      agent family and the configuration managers, so they come first. Idempotent.
    function _grantSuiteRoles(address token) internal {
        TREXAccessManager suiteAM = TREXAccessManager(Token(token).authority());
        RolesLib.Role[15] memory roles = [
            RolesLib.Role.AGENT_ADMIN,
            RolesLib.Role.SUITE_ADMIN,
            RolesLib.Role.OWNER,
            RolesLib.Role.AGENT,
            RolesLib.Role.AGENT_MINTER,
            RolesLib.Role.AGENT_BURNER,
            RolesLib.Role.AGENT_PARTIAL_FREEZER,
            RolesLib.Role.AGENT_ADDRESS_FREEZER,
            RolesLib.Role.AGENT_FORCED_TRANSFER,
            RolesLib.Role.AGENT_RECOVERY_ADDRESS,
            RolesLib.Role.AGENT_PAUSER,
            RolesLib.Role.TOKEN_MANAGER,
            RolesLib.Role.IDENTITY_MANAGER,
            RolesLib.Role.COMPLIANCE_MANAGER,
            RolesLib.Role.VALIDATION_KEEPER
        ];
        for (uint256 i = 0; i < roles.length; i++) {
            _grantIfMissing(suiteAM, _role(roles[i]), deployer);
        }
        console.log("Suite roles granted to deployer in", address(suiteAM));
    }

    // ============ Identities: INDIVIDUAL (self-deploy) ============

    function _seedIndividuals() internal {
        individual0Identity = _selfDeployIndividualIfMissing(deployerKey, "seed-individual-0");

        uint256 actor1Key = vm.envOr("SEED_ACTOR_KEY_1", uint256(0));
        if (actor1Key != 0) {
            _selfDeployIndividualIfMissing(actor1Key, "seed-individual-1");
        }
        uint256 actor2Key = vm.envOr("SEED_ACTOR_KEY_2", uint256(0));
        if (actor2Key != 0) {
            _selfDeployIndividualIfMissing(actor2Key, "seed-individual-2");
        }
    }

    /// @dev Self-deploys as `actorKey` via `createIdentity`, which needs its own broadcast
    ///      segment so `msg.sender` on the factory call is the actor, not the deployer.
    function _selfDeployIndividualIfMissing(uint256 actorKey, string memory salt) internal returns (address) {
        address wallet = vm.addr(actorKey);
        address existing = _identityOf(wallet);
        if (existing != address(0)) {
            console.log("INDIVIDUAL already deployed for", wallet, "->", existing);
            return existing;
        }

        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(wallet, KeyPurposes.MANAGEMENT);

        if (actorKey != deployerKey) {
            vm.stopBroadcast();
            vm.startBroadcast(actorKey);
        }
        address identity = idFactory.createIdentity(IdentityTypes.INDIVIDUAL, salt, keys);
        if (actorKey != deployerKey) {
            vm.stopBroadcast();
            vm.startBroadcast(deployerKey);
        }

        console.log("INDIVIDUAL deployed for", wallet, "->", identity);
        _logIdentity(identity, wallet, "INDIVIDUAL", salt);
        return identity;
    }

    // ============ Identities: CORPORATE / IOT / AI_AGENT (createIdentityFor, ROLE_ISSUER) ============

    function _seedCorporateIotAiAgent() internal {
        if (!_hasRole(onchainAM, ROLE_ISSUER, deployer)) {
            console.log("Skipping CORPORATE/IOT/AI_AGENT: deployer lacks ROLE_ISSUER on ONCHAINID AccessManager");
            return;
        }

        corporate0Wallet = _derive("seed-corporate-0-wallet");
        corporate0Identity =
            _createIdentityForIfMissing(corporate0Wallet, IdentityTypes.CORPORATE, "seed-corporate-0", "CORPORATE");

        iot0Wallet = _derive("seed-iot-0-wallet");
        iot0Identity = _createIdentityForIfMissing(iot0Wallet, IdentityTypes.IOT, "seed-iot-0", "IOT");

        aiAgent0Wallet = _derive("seed-ai-agent-0-wallet");
        aiAgent0Identity =
            _createIdentityForIfMissing(aiAgent0Wallet, IdentityTypes.AI_AGENT, "seed-ai-agent-0", "AI_AGENT");
    }

    function _createIdentityForIfMissing(address wallet, uint256 identityType, string memory salt, string memory label)
        internal
        returns (address)
    {
        address existing = _identityOf(wallet);
        if (existing != address(0)) {
            console.log(string.concat(label, " already deployed for wallet"), wallet);
            console.log("  -> identity", existing);
            return existing;
        }

        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(wallet, KeyPurposes.MANAGEMENT);
        address identity = idFactory.createIdentityFor(wallet, identityType, salt, keys);

        console.log(string.concat(label, " deployed for wallet"), wallet);
        console.log("  -> identity", identity);
        _logIdentity(identity, wallet, label, salt);
        return identity;
    }

    // ============ Identities: CLAIM_ISSUER (ROLE_CLAIM_ISSUER_ADMIN or open, mirrors fixture) ============

    function _seedClaimIssuers() internal {
        claimIssuer0SignerKey = uint256(keccak256("seed-claim-issuer-signer-0"));
        claimIssuer1SignerKey = uint256(keccak256("seed-claim-issuer-signer-1"));

        claimIssuer0Identity = _deployClaimIssuerIfMissing(claimIssuer0SignerKey, "seed-claim-issuer-0");
        claimIssuer1Identity = _deployClaimIssuerIfMissing(claimIssuer1SignerKey, "seed-claim-issuer-1");
    }

    /// @dev A claim issuer is an Identity of type CLAIM_ISSUER holding a CLAIM_SIGNER key (plus
    ///      MANAGEMENT, to satisfy the factory's post-deploy shape check). Gated behind
    ///      ROLE_CLAIM_ISSUER_ADMIN in DeployOnchainID.s.sol's policy; {_ensureOnchainRoles}
    ///      self-grants it to the deployer alongside the other identity-type gates, so this is
    ///      only ever skipped if ADMIN_ROLE itself was rotated away first.
    /// @dev Checked with hasRole rather than try/catch: a reverting call made under
    ///      vm.startBroadcast is still queued for broadcast by forge even when caught in
    ///      Solidity, and later fails "Simulated execution failed" in forge's separate
    ///      broadcast-simulation pass — try/catch does not make a broadcasted call optional.
    function _deployClaimIssuerIfMissing(uint256 signerKey, string memory salt) internal returns (address) {
        address signer = vm.addr(signerKey);
        address existing = _identityOf(signer);
        if (existing != address(0)) {
            console.log("CLAIM_ISSUER already deployed for", signer, "->", existing);
            return existing;
        }
        if (!_hasRole(onchainAM, ROLE_CLAIM_ISSUER_ADMIN, deployer)) {
            console.log("Skipping CLAIM_ISSUER deploy for", signer, "- deployer lacks ROLE_CLAIM_ISSUER_ADMIN");
            return address(0);
        }

        Structs.KeyParam[] memory keys = new Structs.KeyParam[](2);
        keys[0] = _ecdsaKey(signer, KeyPurposes.MANAGEMENT);
        keys[1] = _ecdsaKey(signer, KeyPurposes.CLAIM_SIGNER);

        address identity = idFactory.createIdentityFor(signer, IdentityTypes.CLAIM_ISSUER, salt, keys);
        console.log("CLAIM_ISSUER deployed for", signer, "->", identity);
        _logIdentity(identity, signer, "CLAIM_ISSUER", salt);
        return identity;
    }

    // ============ Identities: PUBLIC_AUTHORITY ============

    function _seedPublicAuthority() internal {
        if (!_hasRole(onchainAM, ROLE_PUBLIC_AUTHORITY, deployer)) {
            console.log("Skipping PUBLIC_AUTHORITY: deployer lacks ROLE_PUBLIC_AUTHORITY on ONCHAINID AccessManager");
            return;
        }

        address wallet = _derive("seed-public-authority-0-wallet");
        _createIdentityForIfMissing(
            wallet, IdentityTypes.PUBLIC_AUTHORITY, "seed-public-authority-0", "PUBLIC_AUTHORITY"
        );
    }

    // ============ Keys: add a second key to a few identities, remove one ============

    function _seedKeys() internal {
        if (individual0Identity == address(0)) return;

        address secondKey = _derive("seed-second-key-0");
        bytes32 secondKeyHash = keccak256(abi.encodePacked(secondKey));

        if (!IERC734(individual0Identity).keyHasPurpose(secondKeyHash, KeyPurposes.ACTION)) {
            Identity(payable(individual0Identity))
                .addKeyWithData(secondKeyHash, KeyPurposes.ACTION, KeyTypes.ECDSA, abi.encodePacked(secondKey), "");
            console.log("Added ACTION key", secondKey, "to individual0 identity");
        }

        // Remove the second key again, right after adding it, so KeyRemoved is also emitted.
        if (IERC734(individual0Identity).keyHasPurpose(secondKeyHash, KeyPurposes.ACTION)) {
            Identity(payable(individual0Identity)).removeKey(secondKeyHash, KeyPurposes.ACTION);
            console.log("Removed ACTION key", secondKey, "from individual0 identity");
        }
    }

    // ============ Claims: issue from each CLAIM_ISSUER, revoke one ============

    uint256 internal constant CLAIM_TOPIC_THROWAWAY = uint256(keccak256("SEED_CLAIM_TOPIC_THROWAWAY"));

    /// @dev addClaim's on-chain caller must hold a claim key on the SUBJECT identity (see
    ///      ERC734Validator._requireClaimKey — the issuer's key only produces the off-chain
    ///      signature, checked separately), so claims can only be pushed onto identities the
    ///      deployer actually manages. That is individual0 alone: corporate0/iot0/aiAgent0 are
    ///      createIdentityFor'd with their own synthetic wallet as MANAGEMENT key (required —
    ///      createIdentityFor rejects keys that don't match the account for non-single-binding
    ///      types), which the deployer never controls. They stay claim-free and only
    ///      participate in the unrestricted suite0.
    function _seedClaims() internal {
        if (claimIssuer0Identity == address(0) || individual0Identity == address(0)) return;

        _addClaimIfMissing(
            individual0Identity, CLAIM_TOPIC_KYC, claimIssuer0Identity, claimIssuer0SignerKey, "seed:kyc:individual0"
        );
        if (claimIssuer1Identity != address(0)) {
            _addClaimIfMissing(
                individual0Identity,
                CLAIM_TOPIC_ACCREDITED,
                claimIssuer1Identity,
                claimIssuer1SignerKey,
                "seed:accredited:individual0"
            );
        }

        // A throwaway claim purely so revokeClaimByDigest / ClaimRevoked show up too, without
        // pulling KYC or ACCREDITED back out from under the gated suites below.
        bytes32 digest = _addClaimIfMissing(
            individual0Identity, CLAIM_TOPIC_THROWAWAY, claimIssuer0Identity, claimIssuer0SignerKey, "seed:throwaway"
        );
        if (digest != bytes32(0)) {
            _revokeAsIssuer(claimIssuer0Identity, claimIssuer0SignerKey, digest);
            console.log("Revoked throwaway claim on individual0 identity");
        }
    }

    /// @dev revokeClaimByDigest requires the on-chain caller to hold a MANAGEMENT key on the
    ///      ISSUER identity (ERC734Validator._requireManagement) — the deployer doesn't hold
    ///      one there (the issuer's own synthetic signer does), so this runs as a short
    ///      broadcast segment under that signer's own key instead, funded with a little ETH
    ///      first since it otherwise holds none.
    function _revokeAsIssuer(address issuerIdentity, uint256 issuerSignerKey, bytes32 digest) internal {
        address signer = vm.addr(issuerSignerKey);
        if (signer.balance == 0) {
            payable(signer).transfer(0.01 ether);
        }
        vm.stopBroadcast();
        vm.startBroadcast(issuerSignerKey);
        IClaimIssuer(issuerIdentity).revokeClaimByDigest(digest);
        vm.stopBroadcast();
        vm.startBroadcast(deployerKey);
    }

    /// @return digest the claim's EIP-712 digest (bytes32(0) if the claim already existed and
    ///         nothing was added, since the digest is only needed right after a fresh add here).
    function _addClaimIfMissing(
        address identity,
        uint256 topic,
        address issuerIdentity,
        uint256 issuerSignerKey,
        string memory uri
    ) internal returns (bytes32 digest) {
        bytes32 claimId = keccak256(abi.encode(issuerIdentity, topic));
        (,, address existingIssuer,,,) = IClaimIssuer(identity).getClaim(claimId);
        if (existingIssuer != address(0)) {
            console.log("Claim already present, topic", topic, "on", identity);
            return bytes32(0);
        }

        Structs.ClaimData memory data = _claimData(uri);
        bytes memory signature;
        (digest, signature) = _signClaim(identity, topic, data, issuerIdentity, issuerSignerKey);

        IIdentity(identity).addClaim(topic, 1, issuerIdentity, signature, data, uri);
        console.log("Added claim, topic", topic, "issuer", issuerIdentity);
        console.log("  -> identity", identity);
    }

    function _claimData(string memory uri) internal view returns (Structs.ClaimData memory) {
        bytes32 metadataHash = ERC734Validator(validatorModule).getMetadataHash(1, uri);
        return Structs.ClaimData({
            issuedAt: block.timestamp, validUntil: 0, metadataHash: metadataHash, payload: bytes(uri)
        });
    }

    function _signClaim(
        address identity,
        uint256 topic,
        Structs.ClaimData memory data,
        address issuerIdentity,
        uint256 issuerSignerKey
    ) internal view returns (bytes32 digest, bytes memory signature) {
        digest = IIdentity(issuerIdentity).getClaimHash(identity, topic, data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerSignerKey, digest);
        signature = abi.encode(abi.encodePacked(vm.addr(issuerSignerKey)), abi.encodePacked(r, s, v));
    }

    // ============ Account linking: linkAccount / revokeAccount (ERC-7930 + EIP-712) ============

    bytes32 internal constant LINK_ACCOUNT_TYPEHASH =
        keccak256("LinkAccount(bytes account,address identity,uint256 nonce,uint256 expiry)");

    function _seedAccountLinking() internal {
        if (individual0Identity == address(0)) return;

        uint256 secondWalletKey = uint256(keccak256("seed-second-wallet-0"));
        address secondWallet = vm.addr(secondWalletKey);
        bytes memory account = InteroperableAddress.formatEvmV1(block.chainid, secondWallet);

        if (idFactory.getIdentity(account) != address(0)) {
            console.log("Second wallet already linked:", secondWallet);
            return;
        }

        uint256 nonce = idFactory.nonceForAccount(account);
        uint256 expiry = block.timestamp + 1 days;
        bytes32 digest = _linkDigest(account, individual0Identity, nonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(secondWalletKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Not wrapped in try/catch: the getIdentity check above already makes this idempotent,
        // and a reverting call made under vm.startBroadcast is still queued for broadcast by
        // forge even when caught in Solidity, then fails "Simulated execution failed" in
        // forge's separate broadcast-simulation pass — try/catch does not make a broadcasted
        // call optional.
        bytes memory linkCall = abi.encodeCall(IIdentityFactory.linkAccount, (account, signature, nonce, expiry));
        IKeyExecutor(individual0Identity).execute(address(idFactory), 0, linkCall);
        console.log("Linked second wallet", secondWallet, "to individual0 identity");

        // Immediately revoke it again so AccountRevoked is also emitted (binding stays
        // on-chain, status flips — see IIdentityFactory.revokeAccount).
        bytes memory revokeCall = abi.encodeCall(IIdentityFactory.revokeAccount, (account));
        IKeyExecutor(individual0Identity).execute(address(idFactory), 0, revokeCall);
        console.log("Revoked second wallet", secondWallet, "from individual0 identity");
    }

    function _linkDigest(bytes memory account, address identity, uint256 nonce, uint256 expiry)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("IdentityFactory")),
                keccak256(bytes("1")),
                block.chainid,
                address(idFactory)
            )
        );
        bytes32 structHash = keccak256(abi.encode(LINK_ACCOUNT_TYPEHASH, keccak256(account), identity, nonce, expiry));
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    // ============ Token suites ============

    /// @return suite0Token an open (no claim-topic gating) suite's token, or address(0) if skipped
    /// @return suite1Token a claim-topic-gated suite's token, or address(0) if skipped
    function _seedTokenSuites() internal returns (address suite0Token, address suite1Token) {
        if (!_hasRole(onchainAM, ROLE_TOKEN_FACTORY, deployer)) {
            console.log("Skipping token suites: deployer lacks ROLE_TOKEN_FACTORY on ONCHAINID AccessManager");
            return (address(0), address(0));
        }

        suite0Token =
            _deploySuiteIfMissing("seed-token-0", "Seed Open Token", "SOT0", new uint256[](0), new address[](0));

        if (claimIssuer0Identity != address(0)) {
            uint256[] memory topics = new uint256[](1);
            topics[0] = CLAIM_TOPIC_KYC;
            address[] memory issuers = new address[](1);
            issuers[0] = claimIssuer0Identity;
            suite1Token = _deploySuiteIfMissing("seed-token-1", "Seed KYC-Gated Token", "SKT1", topics, issuers);
        }

        // A third, differently-configured suite (varied ClaimDetails, no activity beyond
        // deployment) purely to widen the on-chain TREXSuiteDeployed / beacon-proxy surface.
        if (claimIssuer1Identity != address(0)) {
            uint256[] memory topics = new uint256[](1);
            topics[0] = CLAIM_TOPIC_ACCREDITED;
            address[] memory issuers = new address[](1);
            issuers[0] = claimIssuer1Identity;
            _deploySuiteIfMissing("seed-token-2", "Seed Accredited Token", "SAT2", topics, issuers);
        }
    }

    function _deploySuiteIfMissing(
        string memory salt,
        string memory name,
        string memory symbol,
        uint256[] memory claimTopics,
        address[] memory issuers
    ) internal returns (address) {
        address existing = trexFactory.getToken(salt);
        if (existing != address(0)) {
            console.log("Suite already deployed for salt", salt, "-> token", existing);
            return existing;
        }

        address assetIdentity = _mintAssetIdentityIfMissing(salt);
        if (assetIdentity == address(0)) return address(0);

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: name,
            symbol: symbol,
            decimals: 18,
            irs: address(0),
            ONCHAINID: assetIdentity,
            complianceModules: new address[](0),
            complianceSettings: new bytes[](0),
            // The factory deploys the suite's own TREXAccessManager, which lays the suite's roles
            // out in DOMAIN as it is initialised; the deployer administers it from the first block.
            accessManager: address(0),
            accessManagerAdmin: deployer
        });

        uint256[][] memory issuerClaims = new uint256[][](claimTopics.length > 0 ? 1 : 0);
        if (claimTopics.length > 0) {
            issuerClaims[0] = claimTopics;
        }
        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: claimTopics, issuers: issuers, issuerClaims: issuerClaims });

        trexFactory.deployTREXSuite(salt, tokenDetails, claimDetails);
        address token = trexFactory.getToken(salt);
        _grantSuiteRoles(token);

        console.log("Deployed suite", salt, "-> token", token);
        console.log("  onchainID", assetIdentity);
        _logToken(salt, token);
        return token;
    }

    /// @dev ASSET is single-binding: `_account` is never checked against the supplied keys and
    ///      never needs to sign anything, so a synthetic per-suite placeholder is enough. The
    ///      identity's MANAGEMENT key is the deployer's own address so the deployer can operate
    ///      it later if needed (e.g. to add claims about the asset itself).
    /// @dev Not try/catch-guarded: {_seedTokenSuites} already checks ROLE_TOKEN_FACTORY before
    ///      calling this, and a reverting call made under vm.startBroadcast is still queued for
    ///      broadcast by forge even when caught in Solidity (see {_deployClaimIssuerIfMissing}).
    function _mintAssetIdentityIfMissing(string memory salt) internal returns (address) {
        address placeholder = _derive(string.concat("seed-asset-account:", salt));
        address existing = _identityOf(placeholder);
        if (existing != address(0)) return existing;

        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(deployer, KeyPurposes.MANAGEMENT);

        address identity = idFactory.createIdentityFor(placeholder, IdentityTypes.ASSET, salt, keys);
        _logIdentity(identity, placeholder, "ASSET", salt);
        return identity;
    }

    // ============ Token activity: register, mint, transfer, forcedTransfer, freeze, burn ============

    function _seedTokenActivity(address tokenAddress) internal {
        Token token = Token(tokenAddress);
        IERC3643IdentityRegistry ir = token.identityRegistry();
        _unpauseIfNeeded(token);

        _registerIfMissing(
            ir,
            deployer,
            IIdentity(individual0Identity),
            250 /* FRANCE */
        );
        if (corporate0Identity != address(0)) {
            _registerIfMissing(
                ir,
                corporate0Wallet,
                IIdentity(corporate0Identity),
                840 /* UNITED_STATES */
            );
        }
        if (iot0Identity != address(0)) {
            _registerIfMissing(
                ir,
                iot0Wallet,
                IIdentity(iot0Identity),
                724 /* SPAIN */
            );
        }

        if (token.balanceOf(deployer) == 0) {
            token.mint(deployer, 1_000_000 * UNIT);
            console.log("Minted 1,000,000 to deployer on", tokenAddress);
        }

        if (corporate0Identity != address(0) && token.balanceOf(corporate0Wallet) == 0) {
            require(token.transfer(corporate0Wallet, 10_000 * UNIT), "transfer failed");
        }
        if (iot0Identity != address(0) && token.balanceOf(iot0Wallet) == 0) {
            require(token.transfer(iot0Wallet, 5_000 * UNIT), "transfer failed");
        }

        if (
            corporate0Identity != address(0) && iot0Identity != address(0)
                && token.balanceOf(corporate0Wallet) >= 1_000 * UNIT
        ) {
            token.forcedTransfer(corporate0Wallet, iot0Wallet, 1_000 * UNIT);
            console.log("Forced-transferred 1,000 corporate0 -> iot0 on", tokenAddress);
        }

        if (corporate0Identity != address(0)) {
            token.freezePartialTokens(corporate0Wallet, 500 * UNIT);
            token.unfreezePartialTokens(corporate0Wallet, 500 * UNIT);
        }
        if (iot0Identity != address(0)) {
            token.setAddressFrozen(iot0Wallet, true);
        }

        if (token.balanceOf(deployer) >= 1_000 * UNIT) {
            token.burn(deployer, 1_000 * UNIT);
            console.log("Burned 1,000 from deployer on", tokenAddress);
        }
    }

    /// @dev Lighter activity for a claim-gated suite: only individual0 carries the required
    ///      claim (see {_seedClaims} — corporate0/iot0/aiAgent0 can never receive one, since
    ///      addClaim's caller must hold a key on the claim's subject and the deployer holds
    ///      none on those), so this registers + mints to individual0 alone. isVerified would
    ///      reject a transfer to any of the others here.
    function _seedGatedSuiteActivity(address tokenAddress) internal {
        Token token = Token(tokenAddress);
        IERC3643IdentityRegistry ir = token.identityRegistry();
        _unpauseIfNeeded(token);

        _registerIfMissing(
            ir,
            deployer,
            IIdentity(individual0Identity),
            250 /* FRANCE */
        );
        if (token.balanceOf(deployer) == 0) {
            token.mint(deployer, 100_000 * UNIT);
            console.log("Minted 100,000 to deployer on gated suite", tokenAddress);
        }
    }

    /// @dev Every T-REX token deploys paused (see Token.init). Plain `transfer()` reverts with
    ///      EnforcedPause until an agent lifts it; mint/burn/forcedTransfer are unaffected (see
    ///      Token._update / _forceUpdate). This is a one-time infrastructure step, not a
    ///      demonstration of the pause/unpause feature itself — that stays out of scope for v1
    ///      per this file's header comment.
    function _unpauseIfNeeded(Token token) internal {
        if (token.paused()) {
            token.unpause();
        }
    }

    function _registerIfMissing(IERC3643IdentityRegistry ir, address userAddress, IIdentity identity, uint16 country)
        internal
    {
        if (address(ir.identity(userAddress)) != address(0)) return;
        ir.registerIdentity(userAddress, identity, country);
        console.log("Registered", userAddress, "on identity registry", address(ir));
    }

    // ============ Trusted issuers / claim topics churn (add then remove, net no-op) ============

    function _seedTrustedIssuersAndClaimTopics(address tokenAddress) internal {
        if (claimIssuer1Identity == address(0)) return;

        TREXRegistry registry = TREXRegistry(address(Token(tokenAddress).identityRegistry()));

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_ACCREDITED;
        registry.addTrustedIssuer(claimIssuer1Identity, topics);
        registry.removeTrustedIssuer(claimIssuer1Identity);

        registry.addClaimTopic(CLAIM_TOPIC_ACCREDITED);
        registry.removeClaimTopic(CLAIM_TOPIC_ACCREDITED);

        console.log("Exercised addTrustedIssuer/removeTrustedIssuer + addClaimTopic/removeClaimTopic on", tokenAddress);
    }

    // ============ Shared helpers ============

    function _identityOf(address wallet) internal view returns (address) {
        return idFactory.getIdentity(InteroperableAddress.formatEvmV1(block.chainid, wallet));
    }

    function _ecdsaKey(address addr, uint256 purpose) internal pure returns (Structs.KeyParam memory) {
        return Structs.KeyParam({
            keyHash: keccak256(abi.encodePacked(addr)),
            purpose: purpose,
            keyType: KeyTypes.ECDSA,
            signerData: abi.encodePacked(addr),
            clientData: ""
        });
    }

    /// @dev Deterministic placeholder address for logical actors this script never needs a
    ///      real signature from (corporate/IOT/AI-agent wallets, per-suite ASSET accounts).
    function _derive(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }

    function _logIdentity(address identity, address account, string memory identityType, string memory salt) internal {
        string memory line = string.concat(
            "{\"identity\":\"",
            vm.toString(identity),
            "\",\"account\":\"",
            vm.toString(account),
            "\",\"type\":\"",
            identityType,
            "\",\"salt\":\"",
            salt,
            "\"}"
        );
        vm.writeLine(identitiesLog, line);
    }

    function _logToken(string memory salt, address token) internal {
        string memory line = string.concat(
            "{\"salt\":\"",
            salt,
            "\",\"token\":\"",
            vm.toString(token),
            "\",\"accessManager\":\"",
            vm.toString(Token(token).authority()),
            "\"}"
        );
        vm.writeLine(tokensLog, line);
    }

}

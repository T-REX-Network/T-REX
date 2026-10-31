// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IIdentity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdentityFactory } from "@onchain-id/solidity/contracts/factory/IdentityFactory.sol";
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IdentityTypes } from "@onchain-id/solidity/contracts/libraries/IdentityTypes.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { ERC734Validator } from "@onchain-id/solidity/contracts/modules/validators/ERC734Validator.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";

/**
 * @title SeedGoldToken
 * @notice Deploys a fifth T-REX suite ("Gold Token" / GOLD, KYC-gated) and seeds the one thing
 *         SeedActivity.s.sol deliberately does not: a fully investor-driven flow. Five synthetic
 *         investor wallets each self-deploy their own ONCHAINID identity (not deployer-owned),
 *         get a KYC claim pushed by their own key, get registered on Gold Token's identity
 *         registry by the agent, and then two of them are seeded with an initial mint while the
 *         rest only ever receive GOLD through real peer-to-peer `transfer()` calls signed by the
 *         sending investor's own key — not `mint`/`forcedTransfer` on their behalf.
 *
 * ===== Dependency =====
 * This script MUST run after scripts/SeedActivity.s.sol against the same deployment: it reuses
 * that script's claimIssuer0 (identity + CLAIM_SIGNER key, both re-derived here the same way
 * SeedActivity.s.sol derives them, then looked up on-chain) rather than deploying a new claim
 * issuer. If claimIssuer0 isn't found on-chain, this script aborts with a clear message instead
 * of silently deploying a duplicate issuer.
 *
 * ===== Environment =====
 *   DEPLOYER_PRIVATE_KEY        broadcasts every deployer-signed tx (suite deploy, role setup,
 *                                registerIdentity, mint). Also funds each investor wallet with a
 *                                little ETH so it can broadcast its own txs.
 *   ONCHAINID_IDENTITY_FACTORY  the shared ONCHAINID IdentityFactory (see SeedActivity.s.sol).
 *   TREX_FACTORY                the TREXFactory produced by scripts/DeployTREX.s.sol.
 *
 * ===== Idempotency =====
 * Suite deploy and each investor's identity/claim are guarded by on-chain state checks
 * (getToken / getIdentity / getClaim already non-zero -> skip), same as SeedActivity.s.sol. The
 * trade transfers are NOT idempotency-guarded beyond a balance check — re-running this script is
 * expected and adds more real trading activity each time, same philosophy SeedActivity.s.sol
 * documents for its own token activity (see that file's header comment).
 *
 * ===== Investor key derivation =====
 * investorKey[i] = uint256(keccak256(abi.encodePacked("gold-investor", i)))   for i in 0..4
 * Deterministic and reproducible off-script with `cast wallet address --private-key <key>` if
 * you need to recompute an address independently.
 *
 * ===== Scripted trade sequence (decimals = 18; amounts below are whole GOLD, scaled by UNIT) =====
 *   mint      : investor0 += 480, investor1 += 260   (2 of 5 investors seeded, simulating buyers)
 *   transfer 1: investor0 -> investor2   150
 *   transfer 2: investor1 -> investor3    90
 *   transfer 3: investor2 -> investor4    60
 *   transfer 4: investor3 -> investor0    40
 *   Expected balances after one run: investor0=370 investor1=170 investor2=90 investor3=50
 *   investor4=60 (sums to 740 = 480+260, matching total minted).
 *
 * Usage:
 *   forge script scripts/SeedGoldToken.s.sol --rpc-url baseSepolia --broadcast
 */
contract SeedGoldToken is Script {

    /// @dev Token base unit. GOLD uses 18 decimals, so every human-readable amount below is
    ///      multiplied by this to get the on-chain integer value.
    uint256 internal constant UNIT = 10 ** 18;

    /// @dev The domain a factory-deployed TREXAccessManager lays its suite out in: the first and
    ///      only domain of a manager created by `initializeSuite`.
    uint32 internal constant DOMAIN = 1;

    uint256 internal constant CLAIM_TOPIC_KYC = uint256(keccak256("SEED_CLAIM_TOPIC_KYC"));

    string internal constant GOLD_SALT = "seed-token-gold";
    /// @dev Set in run() from NETWORK_NAME (default baseSepolia): deployments/tokens.<net>.jsonl
    string internal tokensLog;
    uint256 internal constant INVESTOR_COUNT = 5;
    uint256 internal constant FUND_AMOUNT = 0.03 ether;

    string internal identitiesLog;

    IdentityFactory internal idFactory;
    AccessManager internal onchainAM;
    TREXFactory internal trexFactory;
    AccessManager internal trexAM;
    address internal validatorModule;

    address internal deployer;
    uint256 internal deployerKey;

    address internal claimIssuer0Identity;
    uint256 internal claimIssuer0SignerKey;

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

        // Re-derive claimIssuer0 exactly as SeedActivity.s.sol does, then look it up on-chain —
        // this script never deploys its own claim issuer, see header comment.
        claimIssuer0SignerKey = uint256(keccak256("seed-claim-issuer-signer-0"));
        claimIssuer0Identity = _identityOf(vm.addr(claimIssuer0SignerKey));
        require(
            claimIssuer0Identity != address(0),
            "claimIssuer0 not found on-chain - run SeedActivity.s.sol against this deployment first"
        );

        console.log("Deployer:", deployer);
        console.log("ONCHAINID IdentityFactory:", address(idFactory));
        console.log("TREXFactory:              ", address(trexFactory));
        console.log("claimIssuer0 identity:    ", claimIssuer0Identity);
        console.log("");

        vm.startBroadcast(deployerKey);

        address token = _deployGoldSuiteIfMissing();
        require(token != address(0), "Gold Token suite not available");
        IERC3643IdentityRegistry ir = Token(token).identityRegistry();

        address[INVESTOR_COUNT] memory wallets;
        address[INVESTOR_COUNT] memory identities;
        uint16[INVESTOR_COUNT] memory countries = [uint16(250), 840, 826, 276, 392];

        for (uint256 i = 0; i < INVESTOR_COUNT; i++) {
            uint256 investorKey = uint256(keccak256(abi.encodePacked("gold-investor", i)));
            string memory label = string.concat("investor", vm.toString(i));
            string memory idSalt = string.concat("gold-investor-", vm.toString(i));

            (wallets[i], identities[i]) = _setupInvestor(investorKey, idSalt, label);
            _registerIfMissing(ir, wallets[i], IIdentity(identities[i]), countries[i]);
        }

        // ---- Initial distribution: only 2 of 5 investors receive a direct mint. ----
        _mintIfNeeded(Token(token), wallets[0], 480 * UNIT, "investor0");
        _mintIfNeeded(Token(token), wallets[1], 260 * UNIT, "investor1");

        // ---- Real peer-to-peer trades, each signed by the sending investor's own key. ----
        uint256 investor0Key = uint256(keccak256(abi.encodePacked("gold-investor", uint256(0))));
        uint256 investor1Key = uint256(keccak256(abi.encodePacked("gold-investor", uint256(1))));
        uint256 investor2Key = uint256(keccak256(abi.encodePacked("gold-investor", uint256(2))));
        uint256 investor3Key = uint256(keccak256(abi.encodePacked("gold-investor", uint256(3))));

        _tradeIfPossible(Token(token), investor0Key, wallets[0], wallets[2], 150 * UNIT, "investor0 -> investor2");
        _tradeIfPossible(Token(token), investor1Key, wallets[1], wallets[3], 90 * UNIT, "investor1 -> investor3");
        _tradeIfPossible(Token(token), investor2Key, wallets[2], wallets[4], 60 * UNIT, "investor2 -> investor4");
        _tradeIfPossible(Token(token), investor3Key, wallets[3], wallets[0], 40 * UNIT, "investor3 -> investor0");

        vm.stopBroadcast();

        console.log("");
        console.log("========== Gold Token Seeding Summary ==========");
        console.log("Gold Token (GOLD):", token);
        for (uint256 i = 0; i < INVESTOR_COUNT; i++) {
            console.log(string.concat("investor", vm.toString(i)), wallets[i]);
            console.log("  balance:", Token(token).balanceOf(wallets[i]));
        }
        console.log("==================================================");
    }

    // ============ Gold Token suite ============

    /// @dev Same shape as SeedActivity.s.sol's `_deploySuiteIfMissing` for a claim-gated suite:
    ///      decimals = 18 to match the pattern the existing 3 seed suites use, KYC-gated with the
    ///      same CLAIM_TOPIC_KYC / claimIssuer0 that seed-token-1 already requires, so the claim
    ///      machinery reused below actually satisfies it.
    function _deployGoldSuiteIfMissing() internal returns (address) {
        address existing = trexFactory.getToken(GOLD_SALT);
        if (existing != address(0)) {
            console.log("Gold Token suite already deployed -> token", existing);
            _grantSuiteRoles(existing);
            return existing;
        }

        // 1 == ROLE_TOKEN_FACTORY, see SeedActivity.s.sol's role-id constants.
        require(_hasRole(onchainAM, 1, deployer), "deployer lacks ROLE_TOKEN_FACTORY - run SeedActivity.s.sol first");

        address assetIdentity = _mintAssetIdentityIfMissing();

        ITREXFactory.TokenDetails memory tokenDetails = ITREXFactory.TokenDetails({
            name: "Gold Token",
            symbol: "GOLD",
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

        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC_KYC;
        address[] memory issuers = new address[](1);
        issuers[0] = claimIssuer0Identity;
        uint256[][] memory issuerClaims = new uint256[][](1);
        issuerClaims[0] = topics;

        ITREXFactory.ClaimDetails memory claimDetails =
            ITREXFactory.ClaimDetails({ claimTopics: topics, issuers: issuers, issuerClaims: issuerClaims });

        trexFactory.deployTREXSuite(GOLD_SALT, tokenDetails, claimDetails);
        address token = trexFactory.getToken(GOLD_SALT);
        _grantSuiteRoles(token);
        _unpauseIfNeeded(Token(token));

        console.log("Deployed Gold Token suite -> token", token);
        console.log("  onchainID", assetIdentity);
        _logToken(GOLD_SALT, token);
        return token;
    }

    /// @dev ASSET is single-binding, mirrors SeedActivity.s.sol's `_mintAssetIdentityIfMissing`.
    function _mintAssetIdentityIfMissing() internal returns (address) {
        address placeholder = _derive(string.concat("seed-asset-account:", GOLD_SALT));
        address existing = _identityOf(placeholder);
        if (existing != address(0)) return existing;

        Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
        keys[0] = _ecdsaKey(deployer, KeyPurposes.MANAGEMENT);

        address identity = idFactory.createIdentityFor(placeholder, IdentityTypes.ASSET, GOLD_SALT, keys);
        _logIdentity(identity, placeholder, "ASSET", GOLD_SALT);
        return identity;
    }

    /// @dev Every T-REX token deploys paused (see Token.init); a one-time infra step, mirrors
    ///      SeedActivity.s.sol's `_unpauseIfNeeded`.
    function _unpauseIfNeeded(Token token) internal {
        if (token.paused()) {
            token.unpause();
        }
    }

    /// @dev The suite roles the seeder acts under, granted in the gold suite's own
    ///      TREXAccessManager; mirrors SeedActivity.s.sol's `_grantSuiteRoles`: AGENT_ADMIN and
    ///      SUITE_ADMIN first, since they appoint the rest. Idempotent.
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

    // ============ Investors: self-deployed identity + investor-signed KYC claim ============

    /// @dev Self-deploys as `investorKey` via `createIdentity` (self-deploy is open for
    ///      INDIVIDUAL, see ../ONCHAINID/scripts/DeployOnchainID.s.sol's identity-type policy),
    ///      then pushes a KYC claim signed off-chain by claimIssuer0's signer key. `addClaim`'s
    ///      on-chain caller must hold a claim key on the claim's SUBJECT identity (see
    ///      ERC734Validator._requireClaimKey) — a MANAGEMENT key satisfies that too (see
    ///      ERC734Validator._keyHasPurpose), and the investor's own MANAGEMENT key on their own
    ///      identity is exactly what self-deploy just installed — so both calls broadcast as the
    ///      investor's own key in one segment. Mirrors SeedActivity.s.sol's
    ///      `_selfDeployIndividualIfMissing` for the deploy half and `_addClaimIfMissing` /
    ///      `_revokeAsIssuer` for the fund-then-switch-broadcast-segment half.
    function _setupInvestor(uint256 investorKey, string memory idSalt, string memory label)
        internal
        returns (address wallet, address identity)
    {
        wallet = vm.addr(investorKey);
        identity = _identityOf(wallet);
        bool needsIdentity = identity == address(0);

        bytes32 claimId = keccak256(abi.encode(claimIssuer0Identity, CLAIM_TOPIC_KYC));
        bool needsClaim = true;
        if (!needsIdentity) {
            (,, address existingIssuer,,,) = IClaimIssuer(identity).getClaim(claimId);
            needsClaim = existingIssuer == address(0);
        }

        if (!needsIdentity && !needsClaim) {
            console.log(label, "already set up:", wallet);
            console.log("  -> identity", identity);
            return (wallet, identity);
        }

        if (wallet.balance == 0) {
            payable(wallet).transfer(FUND_AMOUNT);
        }

        vm.stopBroadcast();
        vm.startBroadcast(investorKey);

        if (needsIdentity) {
            Structs.KeyParam[] memory keys = new Structs.KeyParam[](1);
            keys[0] = _ecdsaKey(wallet, KeyPurposes.MANAGEMENT);
            identity = idFactory.createIdentity(IdentityTypes.INDIVIDUAL, idSalt, keys);
            console.log(label, "identity self-deployed:", wallet);
            console.log("  -> identity", identity);
            _logIdentity(identity, wallet, "INDIVIDUAL", idSalt);
        }

        if (needsClaim) {
            string memory uri = string.concat("gold:kyc:", label);
            Structs.ClaimData memory data = _claimData(uri);
            (, bytes memory signature) =
                _signClaim(identity, CLAIM_TOPIC_KYC, data, claimIssuer0Identity, claimIssuer0SignerKey);
            IIdentity(identity).addClaim(CLAIM_TOPIC_KYC, 1, claimIssuer0Identity, signature, data, uri);
            console.log(label, "KYC claim added on identity", identity);
        }

        vm.stopBroadcast();
        vm.startBroadcast(deployerKey);
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

    // ============ Registration (agent-gated) / mint / trade ============

    /// @dev Copied from SeedActivity.s.sol's `_registerIfMissing`; agent-gated, broadcasts as
    ///      deployer.
    function _registerIfMissing(IERC3643IdentityRegistry ir, address userAddress, IIdentity identity, uint16 country)
        internal
    {
        if (address(ir.identity(userAddress)) != address(0)) return;
        ir.registerIdentity(userAddress, identity, country);
        console.log("Registered", userAddress, "on identity registry", address(ir));
    }

    function _mintIfNeeded(Token token, address to, uint256 amount, string memory label) internal {
        if (token.balanceOf(to) == 0) {
            token.mint(to, amount);
            console.log("Minted", amount, "GOLD to", label);
        } else {
            console.log(label, "already holds GOLD, skipping initial mint");
        }
    }

    /// @dev Real peer-to-peer transfer, broadcast as the sending investor's own key — the same
    ///      fund-then-switch-broadcast-segment pattern used for identity self-deploy above and
    ///      for SeedActivity.s.sol's `_revokeAsIssuer`, reused here for a plain ERC-20-style
    ///      `transfer`. Not idempotency-guarded beyond a balance check: re-running is expected
    ///      and adds more trading activity each time (see header comment).
    function _tradeIfPossible(
        Token token,
        uint256 fromKey,
        address from,
        address to,
        uint256 amount,
        string memory label
    ) internal {
        if (token.balanceOf(from) < amount) {
            console.log("Skipping trade (insufficient balance):", label);
            return;
        }

        vm.stopBroadcast();
        vm.startBroadcast(fromKey);
        require(token.transfer(to, amount), "transfer failed");
        vm.stopBroadcast();
        vm.startBroadcast(deployerKey);

        console.log(label, "- transferred", amount, "GOLD");
    }

    // ============ Shared helpers (mirrors SeedActivity.s.sol) ============

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

    function _derive(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
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

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Script, console } from "@forge-std/Script.sol";

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IKeyExecutor } from "@onchain-id/solidity/contracts/interface/IKeyExecutor.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "contracts/factory/TREXFactory.sol";
import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/**
 * @title SeedInterop
 * @notice Seeds every cross-chain flow of the Gold Token on one chain, so a subgraph and an SDK
 *         see real routes, validations, a delegation and a recall without a second chain.
 *
 * The "satellite" is chain SATELLITE_CHAIN_ID (default 31338, a local id no public network uses), reached
 * through a loopback ERC-7786 gateway (test/integration/mocks/ERC7786GatewayMock.sol) that
 * attributes everything it delivers to that chain. The deployer plays the satellite's Lite: it
 * is registered as the token's peer there, so the settlements and burn proofs it authors through
 * the gateway are admitted. Gold investors 0 and 1 own one satellite wallet each: their own
 * address on the satellite chain, linked to their identity through the factory's cross-chain
 * link (the wallet sends the proposal itself through the gateway, the identity settles it).
 *
 * What lands on chain, in order:
 *   gateway trusted, route + peer set, validity and reconciliation windows set, two satellite
 *   wallets linked, investor0 delegates 100 GOLD to its satellite wallet, validation 1 issued
 *   and settled for 30 (satellite 0 -> satellite 1), validation 2 issued and left pending,
 *   validation 3 issued toward investor1's native wallet and its leg resent once, a recall of 20
 *   instructed on satellite wallet 1 and settled by a burn proof.
 *
 * ===== Environment =====
 *   DEPLOYER_PRIVATE_KEY        the suite agent (every suite role was granted by the seeders)
 *   ONCHAINID_IDENTITY_FACTORY  the ONCHAINID IdentityFactory
 *   TREX_FACTORY                the TREXFactory; the Gold Token is read from it
 *   TRUSTED_GATEWAY_REGISTRY    the platform TrustedGatewayRegistry
 *   SATELLITE_CHAIN_ID          optional, default 31338; never a real chain, the gateway is a mock
 *   NETWORK_NAME                selects deployments/interop.<net>.json
 *
 * ===== Idempotency =====
 * Infrastructure steps check on-chain state first. The gateway address, once deployed, is kept in
 * the record and reused. The movement steps (delegation, validations, recall) run once: the record
 * carries `movementsSeeded` and a re-run skips them unless INTEROP_FORCE_MOVEMENTS=true.
 *
 * Usage:
 *   forge script scripts/SeedInterop.s.sol --rpc-url baseSepolia --broadcast --slow
 */
contract SeedInterop is Script {

    uint256 internal constant UNIT = 10 ** 18;
    string internal constant GOLD_SALT = "seed-token-gold";
    uint256 internal constant FUND_AMOUNT = 0.01 ether;
    string internal constant JSON = "interop";

    uint256 internal deployerKey;
    address internal deployer;
    IIdentityFactory internal idFactory;
    Token internal token;
    ModularCompliance internal compliance;
    TrustedGatewayRegistry internal registry;
    ERC7786GatewayMock internal gateway;

    uint256 internal satelliteChainId;
    bytes2 internal chainType;
    bytes internal chainReference;
    bytes32 internal chainKey;
    bytes internal tokenEnvelope;
    bytes internal factoryEnvelope;

    uint256[2] internal investorKeys;
    address[2] internal wallets;
    address[2] internal identities;
    bytes[2] internal satellites;

    string internal recordPath;
    bool internal movementsSeeded;

    bytes32 internal settledValidation;
    bytes32 internal pendingValidation;
    bytes32 internal resentValidation;
    uint256 internal recallId;

    function run() external {
        _load();

        vm.startBroadcast(deployerKey);
        _ensureGateway();
        _ensureRouteAndPeer();
        _ensureWindows();
        vm.stopBroadcast();

        for (uint256 i = 0; i < 2; i++) {
            _ensureSatelliteWallet(i);
        }

        if (movementsSeeded && !vm.envOr("INTEROP_FORCE_MOVEMENTS", false)) {
            console.log("Movements already seeded, skipping (set INTEROP_FORCE_MOVEMENTS=true to add more)");
        } else {
            _delegateOut();
            vm.startBroadcast(deployerKey);
            _seedValidations();
            _seedRecall();
            vm.stopBroadcast();
            movementsSeeded = true;
        }

        _record();
        _summary();
    }

    // ============ Setup ============

    function _load() internal {
        require(
            block.chainid == 31337 || block.chainid == 84532 || block.chainid == 936486,
            "seed scripts run on test chains only: anvil, Base Sepolia or the T-REX Testnet"
        );
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        idFactory = IIdentityFactory(vm.envAddress("ONCHAINID_IDENTITY_FACTORY"));
        TREXFactory trexFactory = TREXFactory(vm.envAddress("TREX_FACTORY"));
        registry = TrustedGatewayRegistry(vm.envAddress("TRUSTED_GATEWAY_REGISTRY"));
        satelliteChainId = vm.envOr("SATELLITE_CHAIN_ID", uint256(31338));
        require(satelliteChainId != block.chainid, "SATELLITE_CHAIN_ID must differ from this chain");

        address gold = trexFactory.getToken(GOLD_SALT);
        require(gold != address(0), "Gold Token not deployed - run seed-gold.sh first");
        token = Token(gold);
        compliance = ModularCompliance(address(token.compliance()));

        (chainType, chainReference,) = InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(satelliteChainId));
        chainKey = MessageTypesLib.chainKey(chainType, chainReference);
        tokenEnvelope = InteroperableAddress.formatEvmV1(block.chainid, address(token));
        factoryEnvelope = InteroperableAddress.formatEvmV1(block.chainid, address(idFactory));

        for (uint256 i = 0; i < 2; i++) {
            investorKeys[i] = uint256(keccak256(abi.encodePacked("gold-investor", i)));
            wallets[i] = vm.addr(investorKeys[i]);
            identities[i] = idFactory.getIdentity(InteroperableAddress.formatEvmV1(block.chainid, wallets[i]));
            require(identities[i] != address(0), "gold investor has no identity - run seed-gold.sh first");
            satellites[i] = InteroperableAddress.formatEvmV1(satelliteChainId, wallets[i]);
        }

        string memory networkName = vm.envOr("NETWORK_NAME", string("baseSepolia"));
        recordPath = string.concat("deployments/interop.", networkName, ".json");
        if (vm.exists(recordPath)) {
            string memory json = vm.readFile(recordPath);
            gateway = ERC7786GatewayMock(vm.parseJsonAddress(json, ".gatewayMock"));
            movementsSeeded = vm.parseJsonBool(json, ".movementsSeeded");
            settledValidation = vm.parseJsonBytes32(json, ".settledValidation");
            pendingValidation = vm.parseJsonBytes32(json, ".pendingValidation");
            resentValidation = vm.parseJsonBytes32(json, ".resentValidation");
            recallId = vm.parseJsonUint(json, ".recallId");
        }

        console.log("Deployer (plays the Lite):", deployer);
        console.log("Gold Token:               ", address(token));
        console.log("Satellite chain id:       ", satelliteChainId);
        console.log("investor0:", wallets[0], "identity", identities[0]);
        console.log("investor1:", wallets[1], "identity", identities[1]);
        console.log("");
    }

    // ============ Infrastructure ============

    function _ensureGateway() internal {
        if (address(gateway) != address(0) && address(gateway).code.length > 0) {
            console.log("Loopback gateway already deployed:", address(gateway));
        } else {
            gateway = new ERC7786GatewayMock(satelliteChainId);
            console.log("Loopback gateway deployed:", address(gateway));
        }
        if (!registry.isTrusted(address(gateway))) {
            registry.setTrustedGateway(address(gateway), true);
            console.log("Gateway trusted in TrustedGatewayRegistry");
        }
        idFactory.setTrustedGateway(address(gateway), chainType, chainReference, true);
        console.log("Gateway trusted in IdentityFactory for the satellite chain");
    }

    function _ensureRouteAndPeer() internal {
        if (token.routeFor(chainKey) != address(gateway)) {
            token.setRoute(chainType, chainReference, address(gateway));
            console.log("Route set toward the satellite chain");
        }
        bytes memory peer = InteroperableAddress.formatEvmV1(satelliteChainId, deployer);
        if (keccak256(token.peerFor(chainKey)) != keccak256(peer)) {
            token.setPeer(chainKey, peer);
            console.log("Peer set: the deployer on the satellite chain");
        }
    }

    function _ensureWindows() internal {
        if (compliance.defaultValidityWindow() == 0) {
            compliance.setDefaultValidityWindow(1 days);
            console.log("Default validity window set to 1 day");
        }
        if (compliance.reconciliationWindowOf(chainKey) == 0) {
            compliance.setReconciliationWindow(chainKey, 1 hours);
            console.log("Reconciliation window set to 1 hour");
        }
    }

    // ============ Satellite wallets ============

    function _ensureSatelliteWallet(uint256 i) internal {
        if (idFactory.getIdentity(satellites[i]) != address(0)) {
            console.log("Satellite wallet already linked for investor", i);
            return;
        }

        _fund(wallets[i]);

        vm.startBroadcast(investorKeys[i]);
        bytes memory payload = abi.encode(satellites[i], identities[i], block.timestamp + 1 days);
        gateway.sendMessage(factoryEnvelope, payload, new bytes[](0));
        gateway.relay(gateway.queueLength() - 1);
        bytes memory settle = abi.encodeCall(IIdentityFactory.settlePendingCrossChainLink, (satellites[i], true));
        IKeyExecutor(identities[i]).execute(address(idFactory), 0, settle);
        vm.stopBroadcast();

        console.log("Satellite wallet linked for investor", i);
    }

    function _fund(address wallet) internal {
        if (wallet.balance >= FUND_AMOUNT) return;
        vm.startBroadcast(deployerKey);
        payable(wallet).transfer(FUND_AMOUNT);
        vm.stopBroadcast();
    }

    // ============ Movements ============

    function _delegateOut() internal {
        if (token.bridgedBalanceOf(satellites[0]) != 0) {
            console.log("investor0 already holds a bridged position, skipping the delegation");
            return;
        }
        require(token.balanceOf(wallets[0]) >= 100 * UNIT, "investor0 holds less than 100 GOLD");
        _fund(wallets[0]);
        vm.startBroadcast(investorKeys[0]);
        token.delegateOut(wallets[0], satellites[0], 100 * UNIT);
        vm.stopBroadcast();
        console.log("investor0 delegated 100 GOLD to its satellite wallet");
    }

    function _seedValidations() internal {
        // The salt is the requester's nonce: the id is `keccak256(canonicalKey(from), salt)`, so a seed run
        // that is replayed takes a fresh one.
        settledValidation = compliance.requestTransferValidation(
            satellites[0], satellites[1], 10 * UNIT, 50 * UNIT, "", _salt("settled")
        );
        _liteSends(
            MessageTypesLib.encodeSettlement(
                MessageTypesLib.SettlementNotification({
                    validationId: settledValidation,
                    from: satellites[0],
                    to: satellites[1],
                    amount: 30 * UNIT,
                    hash: compliance.validationOf(settledValidation).hash
                })
            )
        );
        console.log("Validation settled for 30 GOLD, id", vm.toString(settledValidation));

        pendingValidation = compliance.requestTransferValidation(
            satellites[0], satellites[1], 5 * UNIT, 20 * UNIT, "", _salt("pending")
        );
        console.log("Validation left pending, id", vm.toString(pendingValidation));

        bytes memory nativeInvestor1 = InteroperableAddress.formatEvmV1(block.chainid, wallets[1]);
        resentValidation = compliance.requestTransferValidation(
            satellites[0], nativeInvestor1, 1 * UNIT, 10 * UNIT, "", _salt("resent")
        );
        compliance.resendValidation(resentValidation, chainKey, nativeInvestor1, "");
        console.log(
            "Validation issued toward investor1's native wallet and resent once, id", vm.toString(resentValidation)
        );
    }

    /// @dev A salt per seeded validation, distinct per run so a replayed seed never reuses an id.
    function _salt(string memory label) internal view returns (bytes32) {
        return keccak256(abi.encode(label, block.timestamp, block.chainid));
    }

    function _seedRecall() internal {
        recallId = token.instructRecall(satellites[1], 20 * UNIT, wallets[1]);
        _liteSends(
            MessageTypesLib.encodeBurnProof(
                MessageTypesLib.BurnProof({ recallId: recallId, burnedWallet: satellites[1], amount: 20 * UNIT })
            )
        );
        console.log("Recall of 20 GOLD instructed and settled, id", recallId);
    }

    function _liteSends(bytes memory payload) internal {
        gateway.sendMessage(tokenEnvelope, payload, new bytes[](0));
        gateway.relay(gateway.queueLength() - 1);
    }

    // ============ Record ============

    function _record() internal {
        vm.serializeAddress(JSON, "gatewayMock", address(gateway));
        vm.serializeUint(JSON, "satelliteChainId", satelliteChainId);
        vm.serializeBytes32(JSON, "chainKey", chainKey);
        vm.serializeAddress(JSON, "token", address(token));
        vm.serializeAddress(JSON, "compliance", address(compliance));
        vm.serializeBytes(JSON, "satelliteWallet0", satellites[0]);
        vm.serializeBytes(JSON, "satelliteWallet1", satellites[1]);
        vm.serializeAddress(JSON, "investor0", wallets[0]);
        vm.serializeAddress(JSON, "investor1", wallets[1]);
        vm.serializeBytes32(JSON, "settledValidation", settledValidation);
        vm.serializeBytes32(JSON, "pendingValidation", pendingValidation);
        vm.serializeBytes32(JSON, "resentValidation", resentValidation);
        vm.serializeUint(JSON, "recallId", recallId);
        string memory json = vm.serializeBool(JSON, "movementsSeeded", movementsSeeded);
        vm.writeJson(json, recordPath);
        console.log("Recorded", recordPath);
    }

    function _summary() internal view {
        console.log("");
        console.log("========== Interop Seeding Summary ==========");
        console.log("Loopback gateway:        ", address(gateway));
        console.log("Route open:              ", token.isChainOpen(chainKey));
        console.log("investor0 bridged:       ", token.bridgedBalanceOf(satellites[0]));
        console.log("investor1 bridged:       ", token.bridgedBalanceOf(satellites[1]));
        console.log("investor1 native:        ", token.balanceOf(wallets[1]));
        console.log("settled validation:      ", vm.toString(settledValidation));
        console.log("pending validation:      ", vm.toString(pendingValidation));
        console.log("resent validation:       ", vm.toString(resentValidation));
        console.log("=============================================");
    }

}

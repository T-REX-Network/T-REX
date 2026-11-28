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

import { Script, console } from "@forge-std/Script.sol";

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IKeyExecutor } from "@onchain-id/solidity/contracts/interface/IKeyExecutor.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TREXFactory } from "contracts/factory/TREXFactory.sol";
import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/**
 * @title SeedInterop
 * @notice Seeds every cross-chain flow of the Gold Token on one chain, so a subgraph and an SDK
 *         see real routes, validations, a home wallet's move out and a bring home without a second chain.
 *
 * The "satellite" is chain SATELLITE_CHAIN_ID (default 31338, a local id no public network uses), reached
 * through a loopback ERC-7786 gateway (test/integration/mocks/ERC7786GatewayMock.sol) that
 * attributes everything it delivers to that chain. The deployer plays the satellite's Lite: it
 * is registered as the token's peer there, so the receipts it authors through
 * the gateway are admitted. Gold investors 0 and 1 own one satellite wallet each: their own
 * address on the satellite chain, linked to their identity through the factory's cross-chain
 * link (the wallet sends the proposal itself through the gateway, the identity settles it).
 *
 * What lands on chain, in order:
 *   gateway trusted, route + peer set, measured times, validity windows, waiting time, ask limits
 *   and ticket caps set, two satellite wallets linked, investor0 moves 100 GOLD out of its home wallet to
 *   its satellite wallet (burned at home onto hold, landed by the move out's receipt), validation 1 issued and settled for 30 (satellite 0 -> satellite 1), validation 2 issued
 *   and left pending, validation 3 issued toward investor1's native wallet, a bring home of 20
 *   from satellite wallet 1 to investor1's home wallet, ended by its receipt.
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
 * the record and reused. The movement steps (move out, validations, bring home) run once: the record
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
    bytes32 internal bringHomeTicket;

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
            _moveOutFromHome();
            vm.startBroadcast(deployerKey);
            _seedValidations();
            _seedBringHome();
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
            bringHomeTicket = vm.parseJsonBytes32(json, ".bringHomeTicket");
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
        // The loopback gateway plays the home receipt bridge: its receiving policy admits the satellite's
        // receipt bridge (the deployer, who plays every satellite contract) at full finality only.
        gateway.setReceivingPolicy(_satelliteChainSelector(), _satelliteReceiptBridge(), bytes4(0));
        if (!registry.isTrusted(address(gateway))) {
            registry.setTrustedGateway(address(gateway), true, 0);
            console.log("Gateway trusted at full finality in TrustedGatewayRegistry");
        }
        idFactory.setTrustedGateway(address(gateway), chainType, chainReference, true);
        console.log("Gateway trusted in IdentityFactory for the satellite chain");
    }

    /// @dev The CCIP selector the loopback setup gives the satellite chain. CCIP selectors are not chain ids.
    function _satelliteChainSelector() internal view returns (uint64) {
        return uint64(uint256(keccak256(abi.encode("away chain selector", satelliteChainId))));
    }

    /// @dev The satellite's receipt bridge as CCIP reports a sender: the deployer plays it.
    function _satelliteReceiptBridge() internal view returns (bytes memory) {
        return abi.encode(deployer);
    }

    function _ensureRouteAndPeer() internal {
        if (token.receiptRouteFor(chainKey) != address(gateway)) {
            token.setReceiptRoute(
                chainType, chainReference, address(gateway), _satelliteChainSelector(), _satelliteReceiptBridge()
            );
            console.log("Receipt route set toward the satellite chain");
        }
        bytes memory peer = InteroperableAddress.formatEvmV1(satelliteChainId, deployer);
        if (keccak256(token.peerFor(chainKey)) != keccak256(peer)) {
            token.setPeer(chainKey, peer);
            console.log("Peer set: the deployer on the satellite chain");
        }
    }

    /// @dev OpenZeppelin's sizing for Base with a monitored on-call time of 30 minutes: tickets on the ticket route
    ///  need a validity window above 6.2 minutes, tickets at full finality above 24.6 minutes, and the waiting time
    ///  must be above 91.4 minutes; these are sized off chain. The measured times are set first: the waiting time is
    ///  checked against their full finality delivery plus clock lead.
    function _ensureWindows() internal {
        if (compliance.measuredTimesOf(chainKey).fullFinalityDelivery == 0) {
            compliance.setMeasuredTimes(
                chainKey, ITickets.MeasuredTimes({ clockLead: 30, fullFinalityDelivery: 1148, reorgSlotShift: 60 })
            );
            console.log("Measured times set for the satellite chain, from OpenZeppelin's Base sizing");
        }
        if (compliance.validityWindows().onTicketRoute == 0) {
            compliance.setValidityWindows(15 minutes, 25 minutes);
            console.log("Validity windows set to 15 minutes on the ticket route, 25 minutes on the receipt route");
        }
        if (compliance.waitingTimeOf(chainKey) == 0) {
            compliance.setWaitingTime(chainKey, 95 minutes);
            console.log("Waiting time set to 95 minutes");
        }
        if (compliance.askLimits().askWindow == 0) {
            compliance.setAskLimits(
                ITickets.AskLimits({
                    openTicketsPerIdentity: 10, asksPerIdentityPerWindow: 20, askWindow: 1 days, smallestAmount: UNIT
                })
            );
            console.log("Ask limits set: 10 open tickets and 20 asks a day per identity, 1 GOLD at least");
        }
        if (compliance.ticketLimitsOf(chainKey).perTicketCap == 0) {
            compliance.setTicketLimits(chainKey, 1000 * UNIT, 10_000 * UNIT);
            console.log("Ticket caps set: 1,000 GOLD per ticket, 10,000 GOLD per waiting time");
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

    /// @dev investor0 moves 100 GOLD from its home wallet to its away wallet: burned at home onto hold, then the
    ///  move out's receipt from the away chain lands it there.
    function _moveOutFromHome() internal {
        if (token.awayBalanceOf(satellites[0]) != 0) {
            console.log("investor0 already holds an away balance, skipping the move out");
            return;
        }
        require(token.balanceOf(wallets[0]) >= 100 * UNIT, "investor0 holds less than 100 GOLD");
        _fund(wallets[0]);
        bytes memory homeWallet = InteroperableAddress.formatEvmV1(block.chainid, wallets[0]);
        vm.startBroadcast(investorKeys[0]);
        bytes32 ticketId =
            compliance.askToMove(homeWallet, satellites[0], 100 * UNIT, 100 * UNIT, "", _salt("move out"));
        vm.stopBroadcast();

        vm.startBroadcast(deployerKey);
        _liteSends(
            MessageTypesLib.encodeSettlement(
                MessageTypesLib.ReceiptMessage({
                    ticketId: ticketId,
                    from: "",
                    to: satellites[0],
                    amount: 100 * UNIT,
                    askBlockHash: bytes32(0),
                    seenMax: 0,
                    seenValidUntil: 0,
                    half: 1,
                    answer: MessageTypesLib.ReceiptAnswer.Executed
                })
            )
        );
        vm.stopBroadcast();
        console.log("investor0 moved 100 GOLD out to its away wallet");
    }

    function _seedValidations() internal {
        // The salt is the requester's nonce: the id is built from the whole request, salt included, so a seed
        // run that is replayed takes a fresh one.
        settledValidation =
            compliance.askToMove(satellites[0], satellites[1], 10 * UNIT, 50 * UNIT, "", _salt("settled"));
        _liteSends(
            MessageTypesLib.encodeSettlement(
                MessageTypesLib.ReceiptMessage({
                    ticketId: settledValidation,
                    from: satellites[0],
                    to: satellites[1],
                    amount: 30 * UNIT,
                    askBlockHash: compliance.ticketOf(settledValidation).askBlockHash,
                    seenMax: compliance.ticketOf(settledValidation).amountMax,
                    seenValidUntil: compliance.ticketOf(settledValidation).validUntil,
                    half: 0,
                    answer: MessageTypesLib.ReceiptAnswer.Executed
                })
            )
        );
        console.log("Validation settled for 30 GOLD, id", vm.toString(settledValidation));

        pendingValidation =
            compliance.askToMove(satellites[0], satellites[1], 5 * UNIT, 20 * UNIT, "", _salt("pending"));
        console.log("Validation left pending, id", vm.toString(pendingValidation));

        bytes memory nativeInvestor1 = InteroperableAddress.formatEvmV1(block.chainid, wallets[1]);
        resentValidation =
            compliance.askToMove(satellites[0], nativeInvestor1, 1 * UNIT, 10 * UNIT, "", _salt("resent"));
        // Its receipt may be asked for only one waiting time after its valid until, so it is not asked for here.
        console.log("Validation issued toward investor1's native wallet, id", vm.toString(resentValidation));
    }

    /// @dev A salt per seeded validation, distinct per run so a replayed seed never reuses an id.
    function _salt(string memory label) internal view returns (bytes32) {
        return keccak256(abi.encode(label, block.timestamp, block.chainid));
    }

    /// @dev The agent brings 20 GOLD of satellite wallet 1 home to investor1's home wallet: the away token burns them
    ///  and its receipt for the bring home's half mints them at home.
    function _seedBringHome() internal {
        bringHomeTicket = compliance.bringHome(satellites[1], 20 * UNIT, wallets[1], _salt("bring home"));
        _liteSends(
            MessageTypesLib.encodeSettlement(
                MessageTypesLib.ReceiptMessage({
                    ticketId: bringHomeTicket,
                    from: satellites[1],
                    to: "",
                    amount: 20 * UNIT,
                    askBlockHash: bytes32(0),
                    seenMax: 0,
                    seenValidUntil: 0,
                    half: 1,
                    answer: MessageTypesLib.ReceiptAnswer.Executed
                })
            )
        );
        console.log("Bring home of 20 GOLD done, id", vm.toString(bringHomeTicket));
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
        vm.serializeBytes32(JSON, "bringHomeTicket", bringHomeTicket);
        string memory json = vm.serializeBool(JSON, "movementsSeeded", movementsSeeded);
        vm.writeJson(json, recordPath);
        console.log("Recorded", recordPath);
    }

    function _summary() internal view {
        console.log("");
        console.log("========== Interop Seeding Summary ==========");
        console.log("Loopback gateway:        ", address(gateway));
        console.log("Route open:              ", token.isChainOpen(chainKey));
        console.log("investor0 bridged:       ", token.awayBalanceOf(satellites[0]));
        console.log("investor1 bridged:       ", token.awayBalanceOf(satellites[1]));
        console.log("investor1 native:        ", token.balanceOf(wallets[1]));
        console.log("settled validation:      ", vm.toString(settledValidation));
        console.log("pending validation:      ", vm.toString(pendingValidation));
        console.log("resent validation:       ", vm.toString(resentValidation));
        console.log("=============================================");
    }

}

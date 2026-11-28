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

import { Test } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { IERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { ERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/base/ERC3643ClaimTopicsRegistry.sol";
import { ERC3643Compliance } from "contracts/ERC-3643/base/ERC3643Compliance.sol";
import { ERC3643IdentityRegistry } from "contracts/ERC-3643/base/ERC3643IdentityRegistry.sol";
import { ERC3643IdentityRegistryStorage } from "contracts/ERC-3643/base/ERC3643IdentityRegistryStorage.sol";
import { ERC3643Token } from "contracts/ERC-3643/base/ERC3643Token.sol";
import { ERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/base/ERC3643TrustedIssuersRegistry.sol";
import { ComplianceLedgerLib } from "contracts/compliance/modular/ComplianceLedgerLib.sol";
import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModuleSetLib } from "contracts/compliance/modular/ModuleSetLib.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { AsyncApprovalModule } from "contracts/compliance/modular/modules/AsyncApprovalModule.sol";
import { AwayChainVolumeModule } from "contracts/compliance/modular/modules/AwayChainVolumeModule.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { SpenderWhitelistModule } from "contracts/compliance/modular/modules/SpenderWhitelistModule.sol";
import { ITrustedGatewayRegistry } from "contracts/interop/ITrustedGatewayRegistry.sol";
import { TREXMessagingLib } from "contracts/interop/TREXMessagingLib.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { TokenLedgerLib } from "contracts/token/TokenLedgerLib.sol";
import { TREXAccessManager } from "contracts/utils/TREXAccessManager.sol";
import { Utils } from "test/unit/helpers/Utils.sol";

/// @notice Pins every field of every ERC-7201 namespaced struct to the slot it sits in today.
/// @dev A namespace's base slot comes from its string alone, so a struct that changes shape under an unchanged
///  string makes an upgraded proxy read old bytes under new names, with no revert. No deployment test sees it,
///  and `forge inspect <Contract> storageLayout` does not list namespaced structs at all. Each test here points
///  the real struct type at its real namespace slot, writes every field, and reads the raw slots back.
///
///  When a test fails:
///  - a field was appended at the end of the struct: safe, add its assertion here;
///  - a field was removed, reordered, retyped or inserted before the end: every later field moved under the
///    same slot, so give the struct a new namespace string and write the migration (docs/erc3643-oz-swap.md).
///  A field removed or renamed stops this file from compiling, which forces the same decision.
contract NamespaceFieldsTest is Test {

    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    bytes32 internal constant KEY = bytes32(uint256(0xC0FFEE));
    uint256 internal constant NUMBER = 7;

    function test_ERC3643Token() public {
        bytes32 base = Utils.erc7201("erc3643.storage.ERC3643Token");
        ERC3643Token.ERC3643TokenStorage storage tokenStorage;
        assembly ("memory-safe") {
            tokenStorage.slot := base
        }

        tokenStorage.frozen[ALICE] = true;
        tokenStorage.frozenTokens[ALICE] = 11;
        tokenStorage.identityRegistry = IERC3643IdentityRegistry(address(0x1));
        tokenStorage.compliance = IERC3643Compliance(address(0x2));
        tokenStorage.onchainId = address(0x3);

        assertEq(_word(_entry(_field(base, 0), _key(ALICE))), 1, "frozen");
        assertEq(_word(_entry(_field(base, 1), _key(ALICE))), 11, "frozenTokens");
        assertEq(_word(_field(base, 2)), 0x1, "identityRegistry");
        assertEq(_word(_field(base, 3)), 0x2, "compliance");
        assertEq(_word(_field(base, 4)), 0x3, "onchainId");
    }

    function test_IdentityRegistry() public {
        bytes32 base = Utils.erc7201("erc3643.storage.IdentityRegistry");
        ERC3643IdentityRegistry.ERC3643IdentityRegistryStorage storage registryStorage;
        assembly ("memory-safe") {
            registryStorage.slot := base
        }

        registryStorage.identityStorage = IERC3643IdentityRegistryStorage(address(0x1));
        registryStorage.issuersRegistry = IERC3643TrustedIssuersRegistry(address(0x2));
        registryStorage.topicsRegistry = IERC3643ClaimTopicsRegistry(address(0x3));

        assertEq(_word(_field(base, 0)), 0x1, "identityStorage");
        assertEq(_word(_field(base, 1)), 0x2, "issuersRegistry");
        assertEq(_word(_field(base, 2)), 0x3, "topicsRegistry");
    }

    function test_IdentityRegistryStorage() public {
        bytes32 base = Utils.erc7201("erc3643.storage.IdentityRegistryStorage");
        ERC3643IdentityRegistryStorage.ERC3643IdentityRegistryStorageStorage storage identityStorage;
        assembly ("memory-safe") {
            identityStorage.slot := base
        }

        identityStorage.identities[ALICE].identityContract = IIdentity(address(0x1));
        identityStorage.identities[ALICE].investorCountry = 42;
        identityStorage.identityRegistries.add(BOB);

        // identityContract fills bytes 0 to 19, investorCountry the two bytes after it.
        assertEq(_word(_entry(_field(base, 0), _key(ALICE))), 0x1 | (42 << 160), "identities");
        assertEq(_word(_field(base, 1)), 1, "identityRegistries: one entry");
    }

    function test_TrustedIssuersRegistry() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TrustedIssuersRegistry");
        ERC3643TrustedIssuersRegistry.ERC3643TrustedIssuersRegistryStorage storage issuersStorage;
        assembly ("memory-safe") {
            issuersStorage.slot := base
        }

        issuersStorage.trustedIssuers.add(ALICE);
        issuersStorage.trustedIssuerClaimTopics[ALICE].add(NUMBER);
        issuersStorage.claimTopicsToTrustedIssuers[NUMBER].add(ALICE);

        // An EnumerableSet takes two slots, so the second field starts at slot 2.
        assertEq(_word(_field(base, 0)), 1, "trustedIssuers: one entry");
        assertEq(_word(_entry(_field(base, 2), _key(ALICE))), 1, "trustedIssuerClaimTopics");
        assertEq(_word(_entry(_field(base, 3), bytes32(NUMBER))), 1, "claimTopicsToTrustedIssuers");
    }

    function test_ClaimTopicsRegistry() public {
        bytes32 base = Utils.erc7201("erc3643.storage.ClaimTopicsRegistry");
        ERC3643ClaimTopicsRegistry.ERC3643ClaimTopicsRegistryStorage storage topicsStorage;
        assembly ("memory-safe") {
            topicsStorage.slot := base
        }

        topicsStorage.claimTopics.add(NUMBER);

        assertEq(_word(_field(base, 0)), 1, "claimTopics: one entry");
    }

    function test_Compliance() public {
        bytes32 base = Utils.erc7201("erc3643.storage.Compliance");
        ERC3643Compliance.ERC3643ComplianceStorage storage complianceStorage;
        assembly ("memory-safe") {
            complianceStorage.slot := base
        }

        complianceStorage.tokenBound = address(0x1);

        assertEq(_word(_field(base, 0)), 0x1, "tokenBound");
    }

    function test_TREXToken() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TREXToken");
        TokenLedgerLib.TokenStorage storage ledgerStorage;
        assembly ("memory-safe") {
            ledgerStorage.slot := base
        }

        ledgerStorage.decimals = 18;
        ledgerStorage.awayBalance[KEY] = 11;
        ledgerStorage.totalAwayBalance = 12;
        ledgerStorage.inTransit[bytes32(NUMBER)] = 13;
        ledgerStorage.totalOnHold = 14;
        ledgerStorage.reservedForTickets[KEY] = 15;

        assertEq(_word(_field(base, 0)), 18, "decimals");
        assertEq(_word(_entry(_field(base, 1), KEY)), 11, "awayBalance");
        assertEq(_word(_field(base, 2)), 12, "totalAwayBalance");
        assertEq(_word(_entry(_field(base, 3), bytes32(NUMBER))), 13, "inTransit");
        assertEq(_word(_field(base, 4)), 14, "totalOnHold");
        assertEq(_word(_entry(_field(base, 5), KEY)), 15, "reservedForTickets");
    }

    function test_TREXMessaging() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TREXMessaging");
        TREXMessagingLib.MessagingStorage storage messagingStorage;
        assembly ("memory-safe") {
            messagingStorage.slot := base
        }

        messagingStorage.registry = ITrustedGatewayRegistry(address(0x1));
        messagingStorage.receiptRoutes[KEY] = address(0x2);
        messagingStorage.peers[KEY] = hex"01";
        messagingStorage.received[ALICE][KEY] = true;
        messagingStorage.chains[KEY].chainType = 0xabcd;
        messagingStorage.chains[KEY].chainReference = hex"02";
        messagingStorage.pinnedRoutes[bytes32(NUMBER)][KEY] = address(0xe);
        messagingStorage.pinnedPeers[bytes32(NUMBER)][KEY] = bytes32(uint256(0xf));
        messagingStorage.inboundPaused[KEY] = true;
        messagingStorage.pins[KEY].bridge = address(0x3);
        messagingStorage.pins[KEY].peerKey = bytes32(uint256(0x4));
        messagingStorage.ticketRoutes[KEY] = address(0x5);
        messagingStorage.awayReceiptBridges[KEY][ALICE].chainSelector = 0x6;
        messagingStorage.awayReceiptBridges[KEY][ALICE].bridge = hex"07";
        TREXMessagingLib.FormerRoute storage formerRoute = messagingStorage.formerReceiptRoutes[KEY];
        formerRoute.bridge = address(0x8);
        formerRoute.changedAt = 0x9;
        formerRoute.peer = hex"0a";
        messagingStorage.hostileChangedAt[KEY] = 0xd;

        assertEq(_word(_field(base, 0)), 0x1, "registry");
        assertEq(_word(_entry(_field(base, 1), KEY)), 0x2, "receiptRoutes");
        assertEq(_slot(_entry(_field(base, 2), KEY)), _shortBytes(0x01), "peers");
        assertEq(_word(_entry(_entry(_field(base, 3), _key(ALICE)), KEY)), 1, "received");
        bytes32 chain = _entry(_field(base, 4), KEY);
        assertEq(_word(_field(chain, 0)), 0xabcd, "chains.chainType");
        assertEq(_slot(_field(chain, 1)), _shortBytes(0x02), "chains.chainReference");
        // The develop version's fields keep their slots, and the new fields are appended after them.
        assertEq(_word(_entry(_entry(_field(base, 5), bytes32(NUMBER)), KEY)), 0xe, "pinnedRoutes");
        assertEq(_word(_entry(_entry(_field(base, 6), bytes32(NUMBER)), KEY)), 0xf, "pinnedPeers");
        assertEq(_word(_entry(_field(base, 7), KEY)), 1, "inboundPaused");
        assertEq(_word(_entry(_field(base, 8), KEY)), 0x5, "ticketRoutes, the former fastRoutes");
        bytes32 pin = _entry(_field(base, 9), KEY);
        assertEq(_word(_field(pin, 0)), 0x3, "pins.bridge");
        assertEq(_word(_field(pin, 1)), 0x4, "pins.peerKey");
        bytes32 awaySide = _entry(_entry(_field(base, 10), KEY), _key(ALICE));
        assertEq(_word(_field(awaySide, 0)), 0x6, "awayReceiptBridges.chainSelector");
        assertEq(_slot(_field(awaySide, 1)), _shortBytes(0x07), "awayReceiptBridges.bridge");
        bytes32 former = _entry(_field(base, 11), KEY);
        // bridge fills bytes 0 to 19, changedAt bytes 20 to 27.
        assertEq(_word(_field(former, 0)), 0x8 | (0x9 << 160), "formerReceiptRoutes.bridge and changedAt");
        assertEq(_slot(_field(former, 1)), _shortBytes(0x0a), "formerReceiptRoutes.peer");
        assertEq(_word(_entry(_field(base, 12), KEY)), 0xd, "hostileChangedAt");
    }

    function test_TREXAccessManager() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TREXAccessManager");
        TREXAccessManager.DomainStorage storage domainStorage;
        assembly ("memory-safe") {
            domainStorage.slot := base
        }

        domainStorage.count = 2;
        domainStorage.names[1] = "Acme";
        domainStorage.domainOf[ALICE] = 1;

        assertEq(_word(_field(base, 0)), 2, "count");
        // A string of up to 31 bytes is stored inline, its length doubled in the last byte.
        assertEq(_slot(_entry(_field(base, 1), bytes32(uint256(1)))), bytes32("Acme") | bytes32(uint256(8)), "names");
        assertEq(_word(_entry(_field(base, 2), _key(ALICE))), 1, "domainOf");
    }

    function test_TREXEligibility() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TREXEligibility");
        TREXRegistry.Storage storage eligibilityStorage;
        assembly ("memory-safe") {
            eligibilityStorage.slot := base
        }

        eligibilityStorage.checksDisabled = true;
        eligibilityStorage.claimTopicsByIdentityType[NUMBER].add(NUMBER);

        assertEq(_word(_field(base, 0)), 1, "checksDisabled");
        assertEq(_word(_entry(_field(base, 1), bytes32(NUMBER))), 1, "claimTopicsByIdentityType");
    }

    function test_TREXCompliance() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TREXCompliance");
        ModuleSetLib.ModuleSet storage moduleSet;
        assembly ("memory-safe") {
            moduleSet.slot := base
        }

        moduleSet.modules.add(ALICE);
        moduleSet.byType[IModule.ModuleType.SPENDER].add(ALICE);

        // An EnumerableSet takes two slots, so byType starts at slot 2.
        assertEq(_word(_field(base, 0)), 1, "modules: one entry");
        bytes32 spenderKey = bytes32(uint256(uint8(IModule.ModuleType.SPENDER)));
        assertEq(_word(_entry(_field(base, 2), spenderKey)), 1, "byType");
    }

    function test_ComplianceLedger() public {
        bytes32 base = Utils.erc7201("erc3643.storage.ComplianceLedger");
        ComplianceLedgerLib.Ledger storage ledger;
        assembly ("memory-safe") {
            ledger.slot := base
        }

        ledger.position[ALICE] = 11;
        ledger.pendingIn[ALICE] = 12;
        ledger.pendingOut[ALICE] = 13;
        ledger.ownerOf[ALICE] = BOB;
        ledger.pendingTotal = 14;
        ledger.onHoldForward[KEY] = 15;

        assertEq(_word(_entry(_field(base, 0), _key(ALICE))), 11, "position");
        assertEq(_word(_entry(_field(base, 1), _key(ALICE))), 12, "pendingIn");
        assertEq(_word(_entry(_field(base, 2), _key(ALICE))), 13, "pendingOut");
        assertEq(_word(_entry(_field(base, 4), _key(ALICE))), uint256(uint160(BOB)), "ownerOf");
        assertEq(_word(_field(base, 5)), 14, "pendingTotal");
        assertEq(_word(_entry(_field(base, 6), KEY)), 15, "onHoldForward");
    }

    function test_TransferValidation() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TransferValidation");
        TicketLib.ValidationStorage storage validationStorage;
        assembly ("memory-safe") {
            validationStorage.slot := base
        }

        validationStorage.validityWindows = ITickets.ValidityWindows({ onTicketRoute: 10, onReceiptRoute: 11 });
        validationStorage.waitingTimes[KEY] = 12;
        _writeTicket(validationStorage.validations[bytes32(NUMBER)]);
        ITickets.WaitingReceipt storage waiting = validationStorage.waitingReceipts[KEY];
        waiting.bodyHash = bytes32(uint256(31));
        waiting.chainKey = bytes32(uint256(32));
        waiting.deliveredBy = ALICE;
        waiting.peerKey = bytes32(uint256(39));
        waiting.amount = 40;
        waiting.arrivedAt = 41;
        validationStorage.receiptHashes[KEY] = bytes32(uint256(35));
        validationStorage.ticketLimits[KEY] = ITickets.TicketLimits({ perTicketCap: 36, perWindowCap: 37 });
        validationStorage.latestValidUntilSent[KEY] = 38;
        validationStorage.blockedAwayChains[KEY] = true;
        validationStorage.measuredTimes[KEY] = ITickets.MeasuredTimes({
            shortestValidityWindow: 1,
            shortestWaitingTime: 2,
            clockLead: 3,
            clockLag: 4,
            fullFinalityDelivery: 5,
            reorgSlotShift: 6
        });
        validationStorage.validityWindowFloors = ITickets.ValidityWindows({ onTicketRoute: 42, onReceiptRoute: 43 });
        validationStorage.latestStopWaitingAt = 44;
        validationStorage.asksPaused = true;
        validationStorage.askLimits = ITickets.AskLimits({
            openTicketsPerIdentity: 45, asksPerIdentityPerWindow: 46, askWindow: 47, smallestAmount: 48
        });
        validationStorage.askLimitOverrides[ALICE] = 49;
        validationStorage.identityAsks[ALICE] =
            TicketLib.IdentityAsks({ openTickets: 50, asksInWindow: 51, windowStartedAt: 52 });
        validationStorage.openBringHome[KEY] = bytes32(uint256(53));
        validationStorage.uncountedCredit[KEY] = 54;
        validationStorage.uncountedCreditFrom[KEY] = bytes32(uint256(55));
        validationStorage.ticketRouteVolumes[KEY] = TicketLib.TicketRouteVolume({ windowStart: 56, amount: 57 });
        validationStorage.asksPausedOn[KEY] = true;

        // Two uint64 fill bytes 0 to 15 of one slot.
        assertEq(_word(_field(base, 0)), 10 | (11 << 64), "validityWindows");
        assertEq(_word(_entry(_field(base, 1), KEY)), 12, "waitingTimes");
        _assertTicket(_entry(_field(base, 2), bytes32(NUMBER)));

        bytes32 waitingSlot = _entry(_field(base, 3), KEY);
        assertEq(_word(_field(waitingSlot, 0)), 31, "waitingReceipts.bodyHash");
        assertEq(_word(_field(waitingSlot, 1)), 32, "waitingReceipts.chainKey");
        assertEq(_word(_field(waitingSlot, 2)), uint256(uint160(ALICE)), "waitingReceipts.deliveredBy");
        assertEq(_word(_field(waitingSlot, 3)), 39, "waitingReceipts.peerKey");
        assertEq(_word(_field(waitingSlot, 4)), 40, "waitingReceipts.amount");
        assertEq(_word(_field(waitingSlot, 5)), 41, "waitingReceipts.arrivedAt");
        assertEq(_word(_entry(_field(base, 4), KEY)), 35, "receiptHashes");
        bytes32 limits = _entry(_field(base, 5), KEY);
        assertEq(_word(_field(limits, 0)), 36, "ticketLimits.perTicketCap");
        assertEq(_word(_field(limits, 1)), 37, "ticketLimits.perWindowCap");
        assertEq(_word(_entry(_field(base, 6), KEY)), 38, "latestValidUntilSent");
        assertEq(_word(_entry(_field(base, 7), KEY)), 1, "blockedAwayChains");
        bytes32 times = _entry(_field(base, 8), KEY);
        assertEq(_word(_field(times, 0)), 1 | (2 << 64) | (3 << 128) | (4 << 192), "measuredTimes, first four");
        assertEq(_word(_field(times, 1)), 5 | (6 << 64), "measuredTimes, last two");
        assertEq(_word(_field(base, 9)), 42 | (43 << 64), "validityWindowFloors");
        // latestStopWaitingAt fills bytes 0 to 7, asksPaused byte 8.
        assertEq(_word(_field(base, 10)), 44 | (1 << 64), "latestStopWaitingAt and asksPaused");
        assertEq(_word(_field(base, 11)), 45 | (46 << 32) | (47 << 64), "askLimits, the three counts");
        assertEq(_word(_field(base, 12)), 48, "askLimits.smallestAmount");
        assertEq(_word(_entry(_field(base, 13), _key(ALICE))), 49, "askLimitOverrides");
        assertEq(_word(_entry(_field(base, 14), _key(ALICE))), 50 | (51 << 32) | (52 << 64), "identityAsks");
        assertEq(_word(_entry(_field(base, 15), KEY)), 53, "openBringHome");
        assertEq(_word(_entry(_field(base, 16), KEY)), 54, "uncountedCredit");
        assertEq(_word(_entry(_field(base, 17), KEY)), 55, "uncountedCreditFrom");
        bytes32 volume = _entry(_field(base, 18), KEY);
        assertEq(_word(_field(volume, 0)), 56, "ticketRouteVolumes.windowStart");
        assertEq(_word(_field(volume, 1)), 57, "ticketRouteVolumes.amount");
        assertEq(_word(_entry(_field(base, 19), KEY)), 1, "asksPausedOn");
    }

    function _writeTicket(ITickets.Ticket storage ticket) private {
        ticket.askBlockHash = bytes32(uint256(21));
        ticket.amountMin = 22;
        ticket.amountMax = 23;
        ticket.validUntil = 24;
        ticket.fromChainKey = bytes32(uint256(26));
        ticket.toChainKey = bytes32(uint256(27));
        ticket.fromKey = bytes32(uint256(28));
        ticket.fromWallet = hex"01";
        ticket.toKey = bytes32(uint256(29));
        ticket.fromIdentity = ALICE;
        ticket.toIdentity = BOB;
        ticket.relocation = true;
        ticket.status = ITickets.TicketStatus.OnHold;
        ticket.moved = 30;
        ticket.spender = hex"03";
        ticket.salt = bytes32(uint256(33));
        ticket.requestedMax = 34;
        ticket.seenValidUntil = 60;
        ticket.stopWaitingAt = 61;
        ticket.lastSentAt = 62;
        ticket.asksForReceipt = 63;
        ticket.half = 64;
        ticket.secondHalfToKey = bytes32(uint256(65));
        ticket.secondHalfValidUntil = 66;
        ticket.secondHalfSends = 67;
        ticket.secondHalfOwed = true;
        ticket.newHalves = 68;
        ticket.kind = ITickets.TicketKind.BRING_HOME;
        ticket.homeWallet = BOB;
        ticket.written = true;
        ticket.carriedFrom = bytes32(uint256(69));
        ticket.carriedAmount = 70;
        ticket.carriedBy = bytes32(uint256(71));
        ticket.shortCancel = true;
        ticket.onReceiptRoute = true;
        ticket.waitedForApproval = true;
        ticket.lastHalfToTheReceiver = 72;
    }

    function _assertTicket(bytes32 entry) private view {
        assertEq(_word(_field(entry, 0)), 21, "validations.askBlockHash");
        assertEq(_word(_field(entry, 1)), 22, "validations.amountMin");
        assertEq(_word(_field(entry, 2)), 23, "validations.amountMax");
        assertEq(_word(_field(entry, 3)), 24, "validations.validUntil");
        assertEq(_word(_field(entry, 4)), 26, "validations.fromChainKey");
        assertEq(_word(_field(entry, 5)), 27, "validations.toChainKey");
        assertEq(_word(_field(entry, 6)), 28, "validations.fromKey");
        assertEq(_slot(_field(entry, 7)), _shortBytes(0x01), "validations.fromWallet");
        assertEq(_word(_field(entry, 8)), 29, "validations.toKey");
        assertEq(_word(_field(entry, 9)), uint256(uint160(ALICE)), "validations.fromIdentity");
        // toIdentity fills bytes 0 to 19, relocation byte 20, status byte 21.
        assertEq(
            _word(_field(entry, 10)),
            uint256(uint160(BOB)) | (1 << 160) | (uint256(ITickets.TicketStatus.OnHold) << 168),
            "validations.toIdentity, relocation and status"
        );
        assertEq(_word(_field(entry, 11)), 30, "validations.moved");
        assertEq(_slot(_field(entry, 12)), _shortBytes(0x03), "validations.spender");
        assertEq(_word(_field(entry, 13)), 33, "validations.salt");
        assertEq(_word(_field(entry, 14)), 34, "validations.requestedMax");
        // seenValidUntil, stopWaitingAt and lastSentAt fill bytes 0 to 23, asksForReceipt byte 24, half byte 25.
        assertEq(
            _word(_field(entry, 15)),
            60 | (61 << 64) | (62 << 128) | (63 << 192) | (64 << 200),
            "validations: the clock, asksForReceipt and half"
        );
        assertEq(_word(_field(entry, 16)), 65, "validations.secondHalfToKey");
        // secondHalfValidUntil bytes 0 to 7, secondHalfSends 8, secondHalfOwed 9, newHalves 10, kind 11,
        // homeWallet bytes 12 to 31.
        assertEq(
            _word(_field(entry, 17)),
            66 | (67 << 64) | (1 << 72) | (68 << 80) | (uint256(ITickets.TicketKind.BRING_HOME) << 88)
                | (uint256(uint160(BOB)) << 96),
            "validations: the second half, kind and homeWallet"
        );
        assertEq(_word(_field(entry, 18)), 1, "validations.written");
        assertEq(_word(_field(entry, 19)), 69, "validations.carriedFrom");
        assertEq(_word(_field(entry, 20)), 70, "validations.carriedAmount");
        assertEq(_word(_field(entry, 21)), 71, "validations.carriedBy");
        // shortCancel byte 0, onReceiptRoute byte 1, waitedForApproval byte 2, lastHalfToTheReceiver byte 3.
        assertEq(
            _word(_field(entry, 22)),
            1 | (1 << 8) | (1 << 16) | (72 << 24),
            "validations: shortCancel, the route and lastHalfToTheReceiver"
        );
    }

    function test_AwayChainVolumeModule() public {
        bytes32 base = Utils.erc7201("erc3643.storage.AwayChainVolumeModule");
        AwayChainVolumeModule.AwayChainVolumeStorage storage volumeStorage;
        assembly ("memory-safe") {
            volumeStorage.slot := base
        }

        volumeStorage.volumeLimits[ALICE][NUMBER][KEY] =
            AwayChainVolumeModule.VolumeLimit({ limitPerWindow: 11, window: 12 });
        volumeStorage.volumes[ALICE][NUMBER][KEY] = AwayChainVolumeModule.Volume({ windowStart: 13, amount: 14 });

        bytes32 limit = _entry(_entry(_entry(_field(base, 0), _key(ALICE)), bytes32(NUMBER)), KEY);
        assertEq(_word(_field(limit, 0)), 11, "volumeLimits.limitPerWindow");
        assertEq(_word(_field(limit, 1)), 12, "volumeLimits.window");
        bytes32 volume = _entry(_entry(_entry(_field(base, 1), _key(ALICE)), bytes32(NUMBER)), KEY);
        assertEq(_word(_field(volume, 0)), 13, "volumes.windowStart");
        assertEq(_word(_field(volume, 1)), 14, "volumes.amount");
    }

    function test_AbstractModuleUpgradeable() public {
        bytes32 base = Utils.erc7201("erc3643.storage.AbstractModuleUpgradeable");
        AbstractModuleUpgradeable.AbstractModuleStorage storage moduleStorage;
        assembly ("memory-safe") {
            moduleStorage.slot := base
        }

        moduleStorage.complianceBound[ALICE] = true;
        moduleStorage.nonces[ALICE] = 11;

        assertEq(_word(_entry(_field(base, 0), _key(ALICE))), 1, "complianceBound");
        assertEq(_word(_entry(_field(base, 1), _key(ALICE))), 11, "nonces");
    }

    function test_MaxBalancePerIdentityModule() public {
        bytes32 base = Utils.erc7201("erc3643.storage.MaxBalancePerIdentityModule");
        MaxBalancePerIdentityModule.MaxBalanceStorage storage maxBalanceStorage;
        assembly ("memory-safe") {
            maxBalanceStorage.slot := base
        }

        maxBalanceStorage.maxBalance[ALICE][NUMBER] = 11;

        assertEq(_word(_entry(_entry(_field(base, 0), _key(ALICE)), bytes32(NUMBER))), 11, "maxBalance");
    }

    function test_AsyncApprovalModule() public {
        bytes32 base = Utils.erc7201("erc3643.storage.AsyncApprovalModule");
        AsyncApprovalModule.AsyncApprovalStorage storage approvalStorage;
        assembly ("memory-safe") {
            approvalStorage.slot := base
        }

        approvalStorage.approvers[ALICE][NUMBER].push(ALICE);
        approvalStorage.requests[ALICE][bytes32(NUMBER)].approved = 11;
        approvalStorage.approvals[ALICE][NUMBER][KEY] = AsyncApprovalModule.Approval({ count: 22, expiry: 33 });
        approvalStorage.usedApprovalIds[ALICE][ALICE][KEY] = true;

        bytes32 byCompliance = _entry(_field(base, 0), _key(ALICE));
        assertEq(_word(_entry(byCompliance, bytes32(NUMBER))), 1, "approvers");
        assertEq(_word(_entry(_entry(_field(base, 1), _key(ALICE)), bytes32(NUMBER))), 11, "requests");
        uint256 packed = _word(_entry(_entry(_entry(_field(base, 2), _key(ALICE)), bytes32(NUMBER)), KEY));
        assertEq(uint64(packed), 22, "approvals.count");
        assertEq(uint64(packed >> 64), 33, "approvals.expiry");
        assertEq(_word(_entry(_entry(_entry(_field(base, 3), _key(ALICE)), _key(ALICE)), KEY)), 1, "usedApprovalIds");

        approvalStorage.approversVersion[ALICE] = 44;
        assertEq(_word(_entry(_field(base, 4), _key(ALICE))), 44, "approversVersion");
    }

    function test_SpenderWhitelistModule() public {
        bytes32 base = Utils.erc7201("erc3643.storage.SpenderWhitelistModule");
        SpenderWhitelistModule.SpenderWhitelistStorage storage whitelistStorage;
        assembly ("memory-safe") {
            whitelistStorage.slot := base
        }

        whitelistStorage.allowedSpenders[ALICE][NUMBER][KEY] = true;

        bytes32 byCompliance = _entry(_field(base, 0), _key(ALICE));
        assertEq(_word(_entry(_entry(byCompliance, bytes32(NUMBER)), KEY)), 1, "allowedSpenders");
    }

    // ============================================================
    // Slot arithmetic, as the compiler lays storage out
    // ============================================================

    /// @dev The slot of the field at `index` in a struct that starts at `base`.
    function _field(bytes32 base, uint256 index) private pure returns (bytes32) {
        return bytes32(uint256(base) + index);
    }

    /// @dev The slot of `key`'s value in a mapping whose own slot is `mappingSlot`.
    function _entry(bytes32 mappingSlot, bytes32 key) private pure returns (bytes32) {
        return keccak256(abi.encode(key, mappingSlot));
    }

    function _key(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _slot(bytes32 slot) private view returns (bytes32) {
        return vm.load(address(this), slot);
    }

    function _word(bytes32 slot) private view returns (uint256) {
        return uint256(vm.load(address(this), slot));
    }

    /// @dev A one-byte `bytes` value as stored inline: the byte first, the length doubled in the last byte.
    function _shortBytes(bytes1 value) private pure returns (bytes32) {
        return bytes32(value) | bytes32(uint256(2));
    }

}

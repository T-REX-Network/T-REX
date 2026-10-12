// SPDX-License-Identifier: GPL-3.0
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
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ModuleSetLib } from "contracts/compliance/modular/ModuleSetLib.sol";
import { TransferValidationLib } from "contracts/compliance/modular/TransferValidationLib.sol";
import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
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
        ledgerStorage.bridgedBalance[KEY] = 11;
        ledgerStorage.totalBridged = 12;
        ledgerStorage.inTransit[NUMBER] = 13;
        ledgerStorage.totalInTransit = 14;
        ledgerStorage.reservedForValidations[KEY] = 15;

        assertEq(_word(_field(base, 0)), 18, "decimals");
        assertEq(_word(_entry(_field(base, 1), KEY)), 11, "bridgedBalance");
        assertEq(_word(_field(base, 2)), 12, "totalBridged");
        assertEq(_word(_entry(_field(base, 3), bytes32(NUMBER))), 13, "inTransit");
        assertEq(_word(_field(base, 4)), 14, "totalInTransit");
        assertEq(_word(_entry(_field(base, 5), KEY)), 15, "reservedForValidations");
    }

    function test_TREXMessaging() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TREXMessaging");
        TREXMessagingLib.MessagingStorage storage messagingStorage;
        assembly ("memory-safe") {
            messagingStorage.slot := base
        }

        messagingStorage.registry = ITrustedGatewayRegistry(address(0x1));
        messagingStorage.routes[KEY] = address(0x2);
        messagingStorage.peers[KEY] = hex"01";
        messagingStorage.received[ALICE][KEY] = true;
        messagingStorage.chains[KEY].chainType = 0xabcd;
        messagingStorage.chains[KEY].chainReference = hex"02";
        messagingStorage.pinnedRoutes[NUMBER][KEY] = address(0x3);

        assertEq(_word(_field(base, 0)), 0x1, "registry");
        assertEq(_word(_entry(_field(base, 1), KEY)), 0x2, "routes");
        assertEq(_slot(_entry(_field(base, 2), KEY)), _shortBytes(0x01), "peers");
        assertEq(_word(_entry(_entry(_field(base, 3), _key(ALICE)), KEY)), 1, "received");
        bytes32 chain = _entry(_field(base, 4), KEY);
        assertEq(_word(_field(chain, 0)), 0xabcd, "chains.chainType");
        assertEq(_slot(_field(chain, 1)), _shortBytes(0x02), "chains.chainReference");
        assertEq(_word(_entry(_entry(_field(base, 5), bytes32(NUMBER)), KEY)), 0x3, "pinnedRoutes");
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
        ledger.gap = -14;
        ledger.ownerOf[ALICE] = BOB;

        assertEq(_word(_entry(_field(base, 0), _key(ALICE))), 11, "position");
        assertEq(_word(_entry(_field(base, 1), _key(ALICE))), 12, "pendingIn");
        assertEq(_word(_entry(_field(base, 2), _key(ALICE))), 13, "pendingOut");
        assertEq(int256(_word(_field(base, 3))), -14, "gap");
        assertEq(_word(_entry(_field(base, 4), _key(ALICE))), uint256(uint160(BOB)), "ownerOf");
    }

    function test_TransferValidation() public {
        bytes32 base = Utils.erc7201("erc3643.storage.TransferValidation");
        TransferValidationLib.ValidationStorage storage validationStorage;
        assembly ("memory-safe") {
            validationStorage.slot := base
        }

        validationStorage.defaultValidityWindow = 11;
        validationStorage.reconciliationWindows[KEY] = 12;
        validationStorage.issuancePaused[KEY] = true;
        validationStorage.lastValidationId = 13;
        ITransferValidation.Validation storage validation = validationStorage.validations[NUMBER];
        validation.hash = bytes32(uint256(21));
        validation.amountMin = 22;
        validation.amountMax = 23;
        validation.expiry = 24;
        validation.releaseAt = 25;
        validation.fromChainKey = bytes32(uint256(26));
        validation.toChainKey = bytes32(uint256(27));
        validation.fromKey = bytes32(uint256(28));
        validation.fromWallet = hex"01";
        validation.toKey = bytes32(uint256(29));
        validation.twoLegs = true;
        validation.fromIdentity = ALICE;
        validation.toIdentity = BOB;
        validation.relocation = true;
        validation.status = ITransferValidation.ValidationStatus.AwaitingMint;
        validation.executedAmount = 30;
        validation.legWallet = hex"02";

        assertEq(_word(_field(base, 0)), 11, "defaultValidityWindow");
        assertEq(_word(_entry(_field(base, 1), KEY)), 12, "reconciliationWindows");
        assertEq(_word(_entry(_field(base, 2), KEY)), 1, "issuancePaused");
        assertEq(_word(_field(base, 3)), 13, "lastValidationId");

        bytes32 entry = _entry(_field(base, 4), bytes32(NUMBER));
        assertEq(_word(_field(entry, 0)), 21, "validations.hash");
        assertEq(_word(_field(entry, 1)), 22, "validations.amountMin");
        assertEq(_word(_field(entry, 2)), 23, "validations.amountMax");
        // expiry fills bytes 0 to 7, releaseAt bytes 8 to 15.
        assertEq(_word(_field(entry, 3)), 24 | (25 << 64), "validations.expiry and releaseAt");
        assertEq(_word(_field(entry, 4)), 26, "validations.fromChainKey");
        assertEq(_word(_field(entry, 5)), 27, "validations.toChainKey");
        assertEq(_word(_field(entry, 6)), 28, "validations.fromKey");
        assertEq(_slot(_field(entry, 7)), _shortBytes(0x01), "validations.fromWallet");
        assertEq(_word(_field(entry, 8)), 29, "validations.toKey");
        // twoLegs fills byte 0, fromIdentity bytes 1 to 20.
        assertEq(_word(_field(entry, 9)), 1 | (uint256(uint160(ALICE)) << 8), "validations.twoLegs and fromIdentity");
        // toIdentity fills bytes 0 to 19, relocation byte 20, status byte 21.
        assertEq(
            _word(_field(entry, 10)),
            uint256(uint160(BOB)) | (1 << 160) | (uint256(ITransferValidation.ValidationStatus.AwaitingMint) << 168),
            "validations.toIdentity, relocation and status"
        );
        assertEq(_word(_field(entry, 11)), 30, "validations.executedAmount");
        assertEq(_slot(_field(entry, 12)), _shortBytes(0x02), "validations.legWallet");
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

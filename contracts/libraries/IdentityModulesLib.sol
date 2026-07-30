// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IERC734 } from "@onchain-id/solidity/contracts/interface/IERC734.sol";
import { IERC735 } from "@onchain-id/solidity/contracts/interface/IERC735.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IKeyExecutor } from "@onchain-id/solidity/contracts/interface/IKeyExecutor.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { ERC734Validator } from "@onchain-id/solidity/contracts/modules/validators/ERC734Validator.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import {
    MODULE_TYPE_EXECUTOR,
    MODULE_TYPE_FALLBACK,
    MODULE_TYPE_VALIDATOR
} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/// @notice Builds the ONCHAINID module bundle and key set used when this project mints identities.
///
/// @dev ONCHAINID's `Identity` is a {SmartAccount} with no native ERC-734/735 surface: `addClaim`,
///      `getClaim`, `getClaimIdsByTopic`, `isClaimValid`, the ERC-734 key getters and friends are all
///      reached through installed modules. The key/claim registry itself lives in the merged
///      {ERC734Validator}, which is enshrined on the identity as an immutable and also serves the
///      claim + ERC-734 getter surface via fallback handlers. An identity minted without it therefore
///      cannot hold or verify claims, which every ERC-3643 flow depends on. `Identity.initialize`
///      additionally rejects a bundle with neither a validator nor an executor; the ERC734Validator
///      install (and the KeyApprovalModule executor) satisfy that.
///
///      This mirrors the reference `legacyQueueModules` bundle from ONCHAINID's own test helpers
///      (`IdentityHelper.legacyQueueModules`), which is not part of the library's published contracts.
library IdentityModulesLib {

    /// @notice Number of module installs in {legacyQueueModules}: 1 validator install for the merged
    ///         ERC734Validator, 4 for the KeyApprovalModule (1 executor + 3 fallbacks), and 15 for the
    ///         ERC734Validator claim/getter surface (1 executor + 14 fallbacks).
    uint256 private constant MODULE_INSTALL_COUNT = 20;

    /// @notice Builds the single-entry MANAGEMENT key set granting `managementKey` control of the identity.
    /// @param managementKey the address to register as the identity's ECDSA management key
    function managementKeys(address managementKey) internal pure returns (Structs.KeyParam[] memory keys) {
        keys = new Structs.KeyParam[](1);
        keys[0] = Structs.KeyParam({
            keyHash: keccak256(abi.encodePacked(managementKey)),
            purpose: KeyPurposes.MANAGEMENT,
            keyType: KeyTypes.ECDSA,
            signerData: abi.encodePacked(managementKey),
            clientData: ""
        });
    }

    /// @notice Builds the module bundle that restores the legacy ERC-734/735 surface on a new identity.
    /// @param keyApprovalModule the KeyApprovalModule singleton (executor + execute/approve/getCurrentNonce
    ///        fallbacks; its MANAGEMENT purpose lets it dispatch self-targeted calls)
    /// @param validatorModule the ERC734Validator singleton: installed as the account validator (it holds
    ///        the enshrined key registry) and backing the whole claim + ERC-734 getter surface via fallback
    ///        handlers
    function legacyQueueModules(address keyApprovalModule, address validatorModule)
        internal
        pure
        returns (Structs.ModuleInstall[] memory installs)
    {
        installs = new Structs.ModuleInstall[](MODULE_INSTALL_COUNT);

        // ----- ERC734Validator: validator (holds the key registry) -----
        // Empty initData -> onInstall does not seed a key; MANAGEMENT comes from the `_keys` array.
        // The validator owns scoping now, so no account-level purpose is granted to it (purpose: 0).
        installs[0] = Structs.ModuleInstall({
            moduleType: MODULE_TYPE_VALIDATOR, module: validatorModule, initData: "", purpose: 0
        });

        // ----- KeyApprovalModule: 1 executor + 3 fallbacks -----
        // MANAGEMENT purpose registers the module as a key so it can dispatch self-targeted calls.
        installs[1] = Structs.ModuleInstall({
            moduleType: MODULE_TYPE_EXECUTOR, module: keyApprovalModule, initData: "", purpose: KeyPurposes.MANAGEMENT
        });
        installs[2] = _fallback(keyApprovalModule, IKeyExecutor.execute.selector);
        installs[3] = _fallback(keyApprovalModule, IKeyExecutor.approve.selector);
        installs[4] = _fallback(keyApprovalModule, IKeyExecutor.getCurrentNonce.selector);

        // ----- ERC734Validator claim surface: 1 executor + 10 claim fallbacks -----
        installs[5] = Structs.ModuleInstall({
            moduleType: MODULE_TYPE_EXECUTOR, module: validatorModule, initData: "", purpose: 0
        });
        installs[6] = _fallback(validatorModule, IERC735.addClaim.selector);
        installs[7] = _fallback(validatorModule, IERC735.removeClaim.selector);
        installs[8] = _fallback(validatorModule, IERC735.getClaim.selector);
        installs[9] = _fallback(validatorModule, IERC735.getClaimIdsByTopic.selector);
        installs[10] = _fallback(validatorModule, IIdentity.isClaimValid.selector);
        installs[11] = _fallback(validatorModule, IIdentity.getClaimHash.selector);
        installs[12] = _fallback(validatorModule, IClaimIssuer.revokeClaimByDigest.selector);
        installs[13] = _fallback(validatorModule, IClaimIssuer.isDigestRevoked.selector);
        installs[14] = _fallback(validatorModule, IClaimIssuer.addClaimTo.selector);
        installs[15] = _fallback(validatorModule, ERC734Validator.addClaimByTrustedIssuer.selector);

        // ----- ERC-734 getters served by the merged module via fallback -----
        installs[16] = _fallback(validatorModule, IERC734.keyHasPurpose.selector);
        installs[17] = _fallback(validatorModule, IERC734.getKey.selector);
        installs[18] = _fallback(validatorModule, IERC734.getKeyPurposes.selector);
        installs[19] = _fallback(validatorModule, IERC734.getKeysByPurpose.selector);
    }

    function _fallback(address module, bytes4 selector) private pure returns (Structs.ModuleInstall memory) {
        return Structs.ModuleInstall({
            moduleType: MODULE_TYPE_FALLBACK, module: module, initData: abi.encodePacked(selector), purpose: 0
        });
    }

}

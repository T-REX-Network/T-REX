// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { IERC735 } from "@onchain-id/solidity/contracts/interface/IERC735.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IKeyExecutor } from "@onchain-id/solidity/contracts/interface/IKeyExecutor.sol";
import { KeyPurposes } from "@onchain-id/solidity/contracts/libraries/KeyPurposes.sol";
import { KeyTypes } from "@onchain-id/solidity/contracts/libraries/KeyTypes.sol";
import { ClaimsModule } from "@onchain-id/solidity/contracts/modules/claims/ClaimsModule.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";
import { MODULE_TYPE_EXECUTOR, MODULE_TYPE_FALLBACK } from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";

/// @notice Builds the ONCHAINID module bundle and key set used when this project mints identities.
///
/// @dev ONCHAINID's `Identity` is an ERC-7579 account with no native ERC-734/735 surface: `addClaim`,
///      `getClaim`, `getClaimIdsByTopic`, `isClaimValid` and friends are all reached through fallback
///      modules. An identity minted without the ClaimsModule therefore cannot hold or verify claims,
///      which every ERC-3643 flow depends on. `Identity.initialize` additionally rejects a bundle with
///      neither a validator nor an executor; the KeyApprovalModule executor satisfies that.
///
///      This mirrors the reference `legacyQueueModules` bundle from ONCHAINID's own test helpers,
///      which is not part of the library's published contracts.
library IdentityModulesLib {

    /// @notice Number of module installs in {legacyQueueModules}: 4 for the KeyApprovalModule
    ///         (1 executor + 3 fallbacks) and 11 for the ClaimsModule (1 executor + 10 fallbacks).
    uint256 private constant MODULE_INSTALL_COUNT = 15;

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
    /// @param keyApprovalModule the KeyApprovalModule singleton (executor; also satisfies
    ///        `Identity.initialize`'s validator-or-executor requirement)
    /// @param claimsModule the ClaimsModule singleton, which backs the whole claim surface
    function legacyQueueModules(address keyApprovalModule, address claimsModule)
        internal
        pure
        returns (Structs.ModuleInstall[] memory installs)
    {
        installs = new Structs.ModuleInstall[](MODULE_INSTALL_COUNT);

        // ----- KeyApprovalModule: 1 executor + 3 fallbacks -----
        // MANAGEMENT purpose registers the module as a key so it can dispatch self-targeted calls.
        installs[0] = Structs.ModuleInstall({
            moduleType: MODULE_TYPE_EXECUTOR, module: keyApprovalModule, initData: "", purpose: KeyPurposes.MANAGEMENT
        });
        installs[1] = _fallback(keyApprovalModule, IKeyExecutor.execute.selector);
        installs[2] = _fallback(keyApprovalModule, IKeyExecutor.approve.selector);
        installs[3] = _fallback(keyApprovalModule, IKeyExecutor.getCurrentNonce.selector);

        // ----- ClaimsModule: 1 executor + 10 fallbacks -----
        installs[4] =
            Structs.ModuleInstall({ moduleType: MODULE_TYPE_EXECUTOR, module: claimsModule, initData: "", purpose: 0 });
        installs[5] = _fallback(claimsModule, IERC735.addClaim.selector);
        installs[6] = _fallback(claimsModule, IERC735.removeClaim.selector);
        installs[7] = _fallback(claimsModule, IERC735.getClaim.selector);
        installs[8] = _fallback(claimsModule, IERC735.getClaimIdsByTopic.selector);
        installs[9] = _fallback(claimsModule, IIdentity.isClaimValid.selector);
        installs[10] = _fallback(claimsModule, IIdentity.getClaimHash.selector);
        installs[11] = _fallback(claimsModule, IClaimIssuer.revokeClaimByDigest.selector);
        installs[12] = _fallback(claimsModule, IClaimIssuer.isDigestRevoked.selector);
        installs[13] = _fallback(claimsModule, IClaimIssuer.addClaimTo.selector);
        installs[14] = _fallback(claimsModule, ClaimsModule.addClaimByTrustedIssuer.selector);
    }

    function _fallback(address module, bytes4 selector) private pure returns (Structs.ModuleInstall memory) {
        return Structs.ModuleInstall({
            moduleType: MODULE_TYPE_FALLBACK, module: module, initData: abi.encodePacked(selector), purpose: 0
        });
    }

}

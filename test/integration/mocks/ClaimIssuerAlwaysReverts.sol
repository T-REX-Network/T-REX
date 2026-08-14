// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

/// @notice Claim issuer whose `isClaimValid` reverts for every caller, with no exception for the
///         ERC734Validator on the claim-write path.
/// @dev Distinct from {ClaimIssuerTrick}, which deliberately answers the validator so a claim can be
///      planted and the *read* path exercised. Here the write itself is the subject: the validator
///      calls `isClaimValid` before storing, so a reverting issuer must make `addClaim` revert rather
///      than store an unverifiable claim.
/// @dev The signature must track `IClaimIssuer.isClaimValid`. If it drifts, the call would fail to
///      dispatch instead of reverting inside the function, which is a different code path.
contract ClaimIssuerAlwaysReverts {

    error IssuerDown();

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external pure returns (bool) {
        revert IssuerDown();
    }

}

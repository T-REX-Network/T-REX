// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

/// @notice Claim issuer that reverts on `isClaimValid` for every reader, used to exercise how
///         callers handle a misbehaving issuer.
/// @dev Writing a claim is itself gated on `isClaimValid`: ClaimsModule verifies with the issuer
///      before storing. So the mock has to accept that one caller, otherwise the claim could never be
///      planted and the revert path under test would be unreachable. Everyone else gets the revert.
/// @dev The signature must track `IClaimIssuer.isClaimValid`. If it drifts, callers would miss this
///      selector entirely and fail to dispatch rather than reverting inside the function, which is a
///      different code path from the one under test.
contract ClaimIssuerTrick {

    /// @dev The ClaimsModule singleton, which calls this on the claim-write path.
    address private immutable _claimsModule;

    constructor(address claimsModule) {
        _claimsModule = claimsModule;
    }

    function isClaimValid(IIdentity, uint256, bytes calldata, Structs.ClaimData calldata) external view returns (bool) {
        if (msg.sender == _claimsModule) {
            return true;
        }

        revert("ERROR");
    }

}

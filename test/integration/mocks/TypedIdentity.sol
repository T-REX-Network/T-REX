// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";

/// @dev ONCHAINID v3-style identity for tests: a regular Identity that also reports an identity
///      type through `getIdentityType()`, as introduced by the ONCHAINID v3 `IdentityTypes` library.
///      The type is freely mutable so tests can simulate issuer-side type changes.
contract TypedIdentity is Identity {

    uint256 private _identityType;

    constructor(address initialManagementKey, uint256 identityType_) Identity(initialManagementKey, false) {
        _identityType = identityType_;
    }

    function setIdentityType(uint256 identityType_) external {
        _identityType = identityType_;
    }

    function getIdentityType() external view returns (uint256) {
        return _identityType;
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643ClaimTopicsRegistry } from "contracts/ERC-3643/base/ERC3643ClaimTopicsRegistry.sol";
import { ERC3643Compliance } from "contracts/ERC-3643/base/ERC3643Compliance.sol";
import { ERC3643IdentityRegistry } from "contracts/ERC-3643/base/ERC3643IdentityRegistry.sol";
import { ERC3643IdentityRegistryStorage } from "contracts/ERC-3643/base/ERC3643IdentityRegistryStorage.sol";
import { ERC3643Token } from "contracts/ERC-3643/base/ERC3643Token.sol";
import { ERC3643TrustedIssuersRegistry } from "contracts/ERC-3643/base/ERC3643TrustedIssuersRegistry.sol";

/// @dev Minimal concrete instantiations of the six ERC-3643 standard bases, used only by the
///  standard suite.
///
///  Each mock supplies the one thing its base leaves abstract -- the authorization hook -- and
///  nothing else. Authorization is a permissive `owner`-or-anyone policy rather than T-REX's
///  AccessManager, precisely so the standard tests exercise the *standard* behavior and not T-REX's
///  access model. No mock overrides any other hook.
///
///  This is what makes the suite the regression net the swap needs (issue #65): it runs against layer 2
///  alone, so it must pass unchanged against OpenZeppelin's bases once they replace ours.
contract ClaimTopicsRegistryMock is ERC3643ClaimTopicsRegistry {

    function _authorizeClaimTopicsUpdate() internal override { }

}

contract TrustedIssuersRegistryMock is ERC3643TrustedIssuersRegistry {

    function _authorizeIssuersUpdate() internal override { }

}

contract IdentityRegistryStorageMock is ERC3643IdentityRegistryStorage {

    function _authorizeIdentityWrite() internal override { }

    function _authorizeRegistryBinding(address) internal override { }

}

contract IdentityRegistryMock is ERC3643IdentityRegistry {

    function init(address identityStorage_, address issuersRegistry_, address topicsRegistry_) external {
        _setIdentityRegistryStorage(identityStorage_);
        _setTrustedIssuersRegistry(issuersRegistry_);
        _setClaimTopicsRegistry(topicsRegistry_);
    }

    function _authorizeIdentityUpdate() internal override { }

    function _authorizeRegistryUpdate(address) internal override { }

}

contract ComplianceMock is ERC3643Compliance {

    function _authorizeTokenBinding(address) internal override { }

    function _authorizeTokenUnbinding(address) internal override { }

}

contract TokenMock is ERC3643Token {

    function init(
        string memory name_,
        string memory symbol_,
        address identityRegistry_,
        address compliance_,
        address onchainId_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __Pausable_init();
        _initERC3643(identityRegistry_, compliance_, onchainId_);
    }

    function _checkTokenAdmin() internal override { }

    function _version() internal pure override returns (string memory) {
        return "standard";
    }

}

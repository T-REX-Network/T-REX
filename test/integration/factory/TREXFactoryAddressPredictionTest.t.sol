// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { ITREXFactory, TREXFactory } from "contracts/factory/TREXFactory.sol";
import { TREXGateway } from "contracts/factory/TREXGateway.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";

/// @dev Test-only factory that can force a CREATE3 address-prediction divergence for a chosen contract type.
///      Production code cannot trigger the `AddressPredictionMismatch` guards because the deployed address and
///      `_predictAddress` share the same CREATE3 derivation; this override makes one of them disagree so the
///      defensive `require`s in `deployTREXSuite` / `_deployToken` can be exercised.
contract TREXFactoryPredictionHarness is TREXFactory {

    bytes32 private _corruptTypeHash;

    constructor(address implementationAuthority, address idFactory, address accessManager)
        TREXFactory(implementationAuthority, idFactory, accessManager)
    { }

    /// @param contractType the CREATE3 contractType discriminator whose prediction should be corrupted
    ///        (e.g. "IR", "Token"); pass "" to disable.
    function setCorruptType(string calldata contractType) external {
        _corruptTypeHash = keccak256(bytes(contractType));
    }

    function _predictAddress(string memory salt, string memory contractType) internal view override returns (address) {
        if (_corruptTypeHash != bytes32(0) && keccak256(bytes(contractType)) == _corruptTypeHash) {
            return address(0xdEaD); // deliberately != the real CREATE3 address
        }
        return super._predictAddress(salt, contractType);
    }

}

/// @title TREXFactory address-prediction guard
/// @notice Exercises the `AddressPredictionMismatch` defensive reverts in `deployTREXSuite` (IR check) and
///         `_deployToken` (Token check). These branches are unreachable in production, so the suite is deployed
///         through {TREXFactoryPredictionHarness}, which forces the deployed address and the predicted address
///         to disagree for a chosen contract type.
contract TREXFactoryAddressPredictionTest is TREXSuiteTest {

    TREXFactoryPredictionHarness internal predictionHarness;

    /// @dev Swap the real factory for the prediction harness. Corruption stays OFF here so the parent `setUp`
    ///      (which deploys a working "salt" suite) succeeds; individual tests toggle it on.
    function _deployFactories() internal override {
        trexImplementationAuthority = _deployTREXImplementationAuthority(true);

        vm.startPrank(deployer);
        predictionHarness = new TREXFactoryPredictionHarness(
            address(trexImplementationAuthority), address(idFactory), address(accessManager)
        );
        trexFactory = predictionHarness;
        idFactory.addTokenFactory(address(trexFactory));

        trexGateway = new TREXGateway(address(trexFactory), false, address(accessManager));

        trexImplementationAuthority.setTREXFactory(address(trexFactory));
        vm.stopPrank();
    }

    /// IR check: `require(ir == _predictAddress(salt, "IR"), AddressPredictionMismatch())`.
    function test_deployTREXSuite_RevertWhen_IRAddressMismatch() public {
        predictionHarness.setCorruptType("IR");
        _expectPredictionMismatch("salt-ir-mismatch");
    }

    /// Token check: `require(token == _predictAddress(salt, "Token"), AddressPredictionMismatch())`.
    function test_deployTREXSuite_RevertWhen_TokenAddressMismatch() public {
        predictionHarness.setCorruptType("Token");
        _expectPredictionMismatch("salt-token-mismatch");
    }

    /// Sanity: with corruption off, the very same call deploys a full suite (the guard does not false-positive).
    function test_deployTREXSuite_SucceedsWhenPredictionMatches() public {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.prank(deployer);
        trexFactory.deployTREXSuite("salt-ok", tokenDetails, claimDetails);

        assertTrue(trexFactory.getToken("salt-ok") != address(0));
    }

    function _expectPredictionMismatch(string memory salt) internal {
        ITREXFactory.TokenDetails memory tokenDetails = _createEmptyTokenDetails();
        ITREXFactory.ClaimDetails memory claimDetails = _createEmptyClaimDetails();

        vm.expectRevert(ErrorsLib.AddressPredictionMismatch.selector);
        vm.prank(deployer);
        trexFactory.deployTREXSuite(salt, tokenDetails, claimDetails);
    }

}

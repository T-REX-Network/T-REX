// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";

/**
 * @dev Shared base for the capability routing fixtures.
 *
 * Each fixture declares one capability and overrides the matching dispatch function, so a test can assert
 * it was reached where it declared and — the point — nowhere else. Hooks record invocations in counters;
 * the checks are `view` so they expose a settable verdict instead.
 */
abstract contract RecordingModule is AbstractModuleUpgradeable {

    uint256 public transferHookCalls;
    uint256 public mintHookCalls;
    uint256 public burnHookCalls;

    /// @dev Verdict of whichever check this fixture implements. Set in `initialize`, not through a field
    ///      initializer: those run in the implementation's constructor and never reach proxy storage.
    bool internal _allow;

    function initialize() external initializer {
        __AbstractModule_init();
        _allow = true;
    }

    function setAllow(bool allow) external {
        _allow = allow;
    }

    /// @dev total invocations across the three hooks, for a single "never called" assertion
    function totalHookCalls() external view returns (uint256) {
        return transferHookCalls + mintHookCalls + burnHookCalls;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure virtual returns (string memory);

    function _authorizeUpgrade(address) internal override { }

}

/// @dev Declares the mint hook only.
contract MintOnlyModule is RecordingModule {

    function moduleMintAction(address, uint256) external override onlyComplianceCall {
        mintHookCalls++;
    }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.HOOK_MINT;
    }

    function name() external pure override returns (string memory) {
        return "MintOnlyModule";
    }

}

/// @dev Declares the burn hook only.
contract BurnOnlyModule is RecordingModule {

    function moduleBurnAction(address, uint256) external override onlyComplianceCall {
        burnHookCalls++;
    }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.HOOK_BURN;
    }

    function name() external pure override returns (string memory) {
        return "BurnOnlyModule";
    }

}

/// @dev Declares the transfer hook only.
contract TransferHookOnlyModule is RecordingModule {

    function moduleTransferAction(address, address, uint256) external override onlyComplianceCall {
        transferHookCalls++;
    }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.HOOK_TRANSFER;
    }

    function name() external pure override returns (string memory) {
        return "TransferHookOnlyModule";
    }

}

/// @dev Declares the transfer check only.
contract CheckTransferOnlyModule is RecordingModule {

    function moduleCheck(address, address, uint256, address) external view override returns (bool) {
        return _allow;
    }

    function moduleCapabilities() external pure virtual returns (uint256) {
        return ModuleCapabilitiesLib.CHECK_TRANSFER;
    }

    function name() external pure override returns (string memory) {
        return "CheckTransferOnlyModule";
    }

}

/// @dev Declares the transfer check and the transfer hook, the shape of a module that both vets a
///      transfer and keeps state about it.
contract CheckAndTransferHookModule is RecordingModule {

    function moduleTransferAction(address, address, uint256) external override onlyComplianceCall {
        transferHookCalls++;
    }

    function moduleCheck(address, address, uint256, address) external view override returns (bool) {
        return _allow;
    }

    function moduleCapabilities() external pure virtual returns (uint256) {
        return ModuleCapabilitiesLib.CHECK_TRANSFER | ModuleCapabilitiesLib.HOOK_TRANSFER;
    }

    function name() external pure override returns (string memory) {
        return "CheckAndTransferHookModule";
    }

}

/// @dev Declares the transfer check and the mint hook, the shape of a supply-limit style module.
contract CheckAndMintHookModule is RecordingModule {

    function moduleMintAction(address, uint256) external override onlyComplianceCall {
        mintHookCalls++;
    }

    function moduleCheck(address, address, uint256, address) external view override returns (bool) {
        return _allow;
    }

    function moduleCapabilities() external pure virtual returns (uint256) {
        return ModuleCapabilitiesLib.CHECK_TRANSFER | ModuleCapabilitiesLib.HOOK_MINT;
    }

    function name() external pure override returns (string memory) {
        return "CheckAndMintHookModule";
    }

}

/// @dev Declares the spender check only.
contract SpenderCheckOnlyModule is RecordingModule {

    function moduleCheckSpender(address, address, address, uint256, address) external view override returns (bool) {
        return _allow;
    }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.CHECK_SPENDER;
    }

    function name() external pure override returns (string memory) {
        return "SpenderCheckOnlyModule";
    }

}

/// @dev Implements a rejecting transfer check but declares only the mint hook, so the compliance
///      must never consult it. Covers the desync direction that silently drops a rule.
contract UndeclaredCheckModule is RecordingModule {

    function moduleMintAction(address, uint256) external override onlyComplianceCall {
        mintHookCalls++;
    }

    function moduleCheck(address, address, uint256, address) external pure override returns (bool) {
        return false;
    }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.HOOK_MINT;
    }

    function name() external pure override returns (string memory) {
        return "UndeclaredCheckModule";
    }

}

/// @dev Declares nothing: must be rejected at binding time.
contract ZeroCapabilityModule is RecordingModule {

    function moduleCapabilities() external pure returns (uint256) {
        return 0;
    }

    function name() external pure override returns (string memory) {
        return "ZeroCapabilityModule";
    }

}

/// @dev Declares a bit outside the defined mask: must be rejected at binding time.
contract UndefinedBitModule is RecordingModule {

    function moduleCapabilities() external pure returns (uint256) {
        return 1 << 7;
    }

    function name() external pure override returns (string memory) {
        return "UndefinedBitModule";
    }

}

/// @dev {CheckTransferOnlyModule} declaring every dispatch point instead of the one it implements:
///      the pre-capability behaviour, where a compliance called every module everywhere. Same body as
///      its parent, so a measurement against it isolates the routing from the module's own work.
contract UngatedCheckTransferOnlyModule is CheckTransferOnlyModule {

    function moduleCapabilities() external pure override returns (uint256) {
        return ModuleCapabilitiesLib.ALL;
    }

}

/// @dev {CheckAndTransferHookModule} declaring every dispatch point. See {UngatedCheckTransferOnlyModule}.
contract UngatedCheckAndTransferHookModule is CheckAndTransferHookModule {

    function moduleCapabilities() external pure override returns (uint256) {
        return ModuleCapabilitiesLib.ALL;
    }

}

/// @dev {CheckAndMintHookModule} declaring every dispatch point. See {UngatedCheckTransferOnlyModule}.
contract UngatedCheckAndMintHookModule is CheckAndMintHookModule {

    function moduleCapabilities() external pure override returns (uint256) {
        return ModuleCapabilitiesLib.ALL;
    }

}

/// @dev Implements no dispatch function but claims every capability, so a compliance routes all
///      five points at it. Used to check that a declared-but-unimplemented flag hits the harmless
///      base defaults rather than reverting.
contract AllCapabilitiesModule is RecordingModule {

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.ALL;
    }

    function name() external pure override returns (string memory) {
        return "AllCapabilitiesModule";
    }

}

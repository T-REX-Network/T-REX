// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";

/**
 * @dev A bounds-narrowing fixture: declares `BOUNDS`, narrows the running range to a configured floor and
 *      ceiling, and can be told to revert. The hook is `view`, so it records nothing: a test proves the range
 *      that reached it with `vm.expectCall`. Settings are per compliance, reached through `callModuleFunction`.
 */
contract BoundsModule is AbstractModuleUpgradeable {

    error BoundsModuleRefused();

    struct Settings {
        uint256 floor;
        /// Zero means no ceiling.
        uint256 ceiling;
        bool shouldRevert;
    }

    mapping(address compliance => Settings) internal _settings;

    function initialize() external initializer {
        __AbstractModule_init();
    }

    function setFloor(uint256 floor) external onlyComplianceCall {
        _settings[msg.sender].floor = floor;
    }

    function setCeiling(uint256 ceiling) external onlyComplianceCall {
        _settings[msg.sender].ceiling = ceiling;
    }

    function setRevert(bool shouldRevert) external onlyComplianceCall {
        _settings[msg.sender].shouldRevert = shouldRevert;
    }

    function validationBounds(bytes calldata, bytes calldata, uint256 currentMin, uint256 currentMax, address)
        external
        view
        override
        returns (uint256 min, uint256 max)
    {
        Settings storage s = _settings[msg.sender];
        require(!s.shouldRevert, BoundsModuleRefused());
        min = currentMin > s.floor ? currentMin : s.floor;
        max = s.ceiling != 0 && s.ceiling < currentMax ? s.ceiling : currentMax;
    }

    function moduleCapabilities() external pure virtual returns (uint256) {
        return ModuleCapabilitiesLib.BOUNDS;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure virtual returns (string memory) {
        return "BoundsModule";
    }

    function _authorizeUpgrade(address) internal override { }

}

/// @dev {BoundsModule} that also declares the transfer check, passing, so a test can prove the bounds hook and
///      the check are dispatched independently.
contract BoundsAndCheckModule is BoundsModule {

    function moduleCapabilities() external pure override returns (uint256) {
        return ModuleCapabilitiesLib.BOUNDS | ModuleCapabilitiesLib.CHECK_TRANSFER;
    }

    function name() external pure override returns (string memory) {
        return "BoundsAndCheckModule";
    }

}

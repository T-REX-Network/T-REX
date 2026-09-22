// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";

contract UnbindRevertingModule is IModule {

    error UnbindRefused();

    function bindCompliance(address) external { }

    function unbindCompliance(address) external pure {
        revert UnbindRefused();
    }

    function moduleTransferAction(address, address, uint256) external { }

    function moduleMintAction(address, uint256) external { }

    function moduleBurnAction(address, uint256) external { }

    function moduleCheck(address, address, uint256, address) external pure returns (bool) {
        return true;
    }

    function moduleCheckSpender(address, address, address, uint256, address) external pure returns (bool) {
        return true;
    }

    function validationBounds(
        bytes calldata,
        bytes calldata,
        bytes calldata,
        uint256 currentMin,
        uint256 currentMax,
        address
    ) external pure returns (uint256, uint256) {
        return (currentMin, currentMax);
    }

    function reserveSlot(uint256, bytes calldata, bytes calldata, uint256) external { }

    function commitSlot(uint256, uint256) external pure returns (bool) {
        return false;
    }

    function releaseSlot(uint256) external { }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.ALL;
    }

    function isComplianceBound(address) external pure returns (bool) {
        return true;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "UnbindRevertingModule";
    }

}

contract RevertEverywhereModule is UUPSUpgradeable {

    error ModuleHostage();

    fallback() external {
        revert ModuleHostage();
    }

    function _authorizeUpgrade(address) internal override { }

}

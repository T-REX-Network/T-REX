// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IModule } from "contracts/compliance/modular/modules/IModule.sol";

contract UnbindRevertingModule is IModule {

    error UnbindRefused();

    function bindCompliance(address) external { }

    function unbindCompliance(address) external pure {
        revert UnbindRefused();
    }

    function allowedAmount(IModule.TransferContext calldata) external pure returns (uint256) {
        return type(uint256).max;
    }

    function moduleTransferAction(IModule.TransferContext calldata, uint256) external { }

    function moduleMintAction(IModule.TransferContext calldata, uint256) external { }

    function moduleBurnAction(IModule.TransferContext calldata, uint256) external { }

    function moduleCheckSpender(address, address, address, uint256, address) external pure returns (bool) {
        return true;
    }

    function moduleTypes() external pure returns (IModule.ModuleType[] memory types) {
        types = new IModule.ModuleType[](3);
        types[0] = IModule.ModuleType.RULE;
        types[1] = IModule.ModuleType.SPENDER;
        types[2] = IModule.ModuleType.TRACKER;
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

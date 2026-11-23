// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";

/// @dev Accepts a configured full context, so previews can be compared with the real token's module calls.
contract PreviewContextModule is AbstractModuleUpgradeable {

    error PreviewCheckReverted();
    error PreviewHookReverted();

    bytes32 public expectedContextHash;
    bytes32 public lastContextHash;
    bool public revertOnCheck;
    bool public revertOnTransfer;

    function initialize() external initializer {
        __AbstractModule_init();
    }

    function setExpectedContext(bytes32 contextHash) external {
        expectedContextHash = contextHash;
    }

    function setRevertOnCheck(bool shouldRevert) external {
        revertOnCheck = shouldRevert;
    }

    function setRevertOnTransfer(bool shouldRevert) external {
        revertOnTransfer = shouldRevert;
    }

    function allowedAmount(TransferContext calldata context) external view override returns (uint256) {
        require(!revertOnCheck, PreviewCheckReverted());
        return keccak256(abi.encode(context)) == expectedContextHash ? type(uint256).max : 0;
    }

    function moduleCheckSpender(TransferContext calldata context) external view override returns (bool) {
        require(!revertOnCheck, PreviewCheckReverted());
        return keccak256(abi.encode(context)) == expectedContextHash;
    }

    function afterTransfer(TransferContext calldata context) external override onlyComplianceCall {
        require(!revertOnTransfer, PreviewHookReverted());
        lastContextHash = keccak256(abi.encode(context));
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](3);
        types[0] = ModuleType.RULE;
        types[1] = ModuleType.SPENDER;
        types[2] = ModuleType.TRACKER;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "PreviewContextModule";
    }

    function _authorizeUpgrade(address) internal override { }

}

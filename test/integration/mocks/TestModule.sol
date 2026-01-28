// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";

contract TestModule is AbstractModuleUpgradeable {

    /// state variables
    mapping(address => uint256) private _complianceData;
    mapping(address => bool) private _blockedTransfers;

    /// functions

    /**
     * @dev initializes the contract and sets the initial state.
     * @notice This function should only be called once during the contract deployment.
     */
    function initialize() external initializer {
        __AbstractModule_init();
    }

    function doSomething(uint256 _value) external onlyComplianceCall {
        _complianceData[msg.sender] = _value;
    }

    function blockModule(bool _blocked) external onlyComplianceCall {
        _blockedTransfers[msg.sender] = _blocked;
    }

    function getComplianceData(address _compliance) external view returns (uint256) {
        return _complianceData[_compliance];
    }

    function getBlockedTransfers(address _compliance) external view returns (bool) {
        return _blockedTransfers[_compliance];
    }

    /**
     *  @dev See {IModule-moduleTransferAction}.
     *  no transfer action required in this module
     */
    function moduleTransferAction(address, address, uint256) external override onlyComplianceCall { }

    /**
     *  @dev See {IModule-moduleMintAction}.
     *  no mint action required in this module
     */
    function moduleMintAction(address, uint256) external override onlyComplianceCall { }

    /**
     *  @dev See {IModule-moduleBurnAction}.
     *  no burn action required in this module
     */
    function moduleBurnAction(address, uint256) external override onlyComplianceCall { }

    /**
     *  @dev See {IModule-moduleCheck}.
     *  always returns true (just a test module)
     */
    function moduleCheck(
        address,
        /*_from*/
        address,
        uint256,
        address _compliance
    )
        external
        view
        override
        returns (bool)
    {
        if (_blockedTransfers[_compliance]) {
            return false;
        }
        return true;
    }

    /**
     *  @dev See {IModule-canComplianceBind}.
     */
    function canComplianceBind(
        address /*_compliance*/
    )
        external
        pure
        returns (bool)
    {
        return true;
    }

    /**
     *  @dev See {IModule-isPlugAndPlay}.
     */
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /**
     *  @dev See {IModule-name}.
     */
    function name() public pure returns (string memory _name) {
        return "TestModule";
    }

    /**
     *  @dev Test function to cover onlyBoundCompliance modifier
     */
    function invokeOnlyBoundCompliance(address _compliance) external onlyBoundCompliance(_compliance) { }

    // Fallback function to accept any callData (used for testing _selector with short callData)
    fallback() external { }

}

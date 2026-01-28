// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { IERC173 } from "contracts/roles/IERC173.sol";

// basic test contract showcasing the behavior of a module not plug & play
contract ModuleNotPnP is AbstractModuleUpgradeable {

    /// state variables
    mapping(address => uint256) private _complianceData;
    mapping(address => bool) private _moduleReady;

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

    function setModuleReady(address compliance, bool ready) external {
        require(msg.sender == IERC173(compliance).owner(), "only compliance owner can call");
        _moduleReady[compliance] = ready;
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
        address
    )
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    /**
     *  @dev See {IModule-canComplianceBind}.
     */
    function canComplianceBind(address _compliance) external view returns (bool) {
        return _moduleReady[_compliance];
    }

    /**
     *  @dev See {IModule-isPlugAndPlay}.
     */
    function isPlugAndPlay() external pure returns (bool) {
        return false;
    }

    /**
     *  @dev See {IModule-name}.
     */
    function name() public pure returns (string memory _name) {
        return "ModuleNotPnP";
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";

/// @notice A hostile module that reenters the token from its own post-operation hooks.
/// @dev Models the M-06 threat: a module hook is an unguarded external call, so an early module can call
///  back into the token before a later stateful module has recorded the outer operation. The hooks here
///  reenter exactly once, so a passing test proves the guard stopped the reentry rather than the module
///  simply running out of gas in an unbounded loop.
contract ReentrantModule is AbstractModuleUpgradeable {

    /// @dev The reentrant call the hooks replay against the token.
    enum Attack {
        None,
        Transfer,
        Mint,
        ForcedTransfer
    }

    address private _token;
    Attack private _attack;
    address private _from;
    address private _to;
    uint256 private _value;

    /// @dev Set once the hooks have fired their single reentrant call, so they never recurse further.
    bool private _fired;

    /// @dev The raw result of the reentrant call, for tests that assert on it instead of expecting a revert.
    bool public lastCallSucceeded;
    bytes public lastCallReturnData;

    function initialize() external initializer {
        __AbstractModule_init();
    }

    /// @dev Arms the module. `from`/`to`/`value` describe the nested call, not the outer one.
    function arm(address token_, Attack attack, address from_, address to_, uint256 value_) external {
        _token = token_;
        _attack = attack;
        _from = from_;
        _to = to_;
        _value = value_;
        _fired = false;
    }

    function afterTransfer(TransferContext calldata) external override onlyComplianceCall {
        _reenter();
    }

    /// @dev Named `TRACKER`, so the compliance dispatches to this module on a transfer, a mint and a burn.
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() public pure returns (string memory) {
        return "ReentrantModule";
    }

    /// @dev Replays the armed call against the token. The result is recorded rather than bubbled, so the
    ///  outer operation only reverts when the test wants the revert to propagate.
    function _reenter() private {
        if (_attack == Attack.None || _fired) return;
        _fired = true;

        bytes memory callData;
        if (_attack == Attack.Transfer) {
            callData = abi.encodeWithSignature("transfer(address,uint256)", _to, _value);
        } else if (_attack == Attack.Mint) {
            callData = abi.encodeWithSignature("mint(address,uint256)", _to, _value);
        } else {
            callData = abi.encodeWithSignature("forcedTransfer(address,address,uint256)", _from, _to, _value);
        }

        (bool ok, bytes memory ret) = _token.call(callData);
        lastCallSucceeded = ok;
        lastCallReturnData = ret;
    }

    function _authorizeUpgrade(address) internal override { }

    /// @dev See {IModule-moduleTypes}.
    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.TRACKER;
    }

}

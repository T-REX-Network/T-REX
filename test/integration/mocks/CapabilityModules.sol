// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";

/// @dev Base for the dispatch fixtures: it counts what the compliance called and remembers the last context,
///      so a test asserts on what a module was actually asked rather than on a mock's internals.
abstract contract RecordingModule is AbstractModuleUpgradeable {

    uint256 public transferActionCalls;
    uint256 public mintActionCalls;
    uint256 public burnActionCalls;

    /// @dev What the fixture answers from `allowedAmount`. Set in `initialize`, not through a field
    ///      initializer: those run in the implementation's constructor and never reach proxy storage.
    uint256 internal _allowed;

    /// @dev Whether the fixture allows a spender. Same reason.
    bool internal _spenderAllowed;

    /// @dev The last context and amount that reached one of the action hooks.
    TransferContext public lastContext;
    uint256 public lastAmount;

    function initialize() external initializer {
        __AbstractModule_init();
        _allowed = type(uint256).max;
        _spenderAllowed = true;
    }

    /// @dev `true` allows everything, `false` refuses everything: both the amount a rule answers and the
    ///      verdict a spender policy gives, so one call covers whichever types the fixture names.
    function setAllow(bool allow) external {
        _allowed = allow ? type(uint256).max : 0;
        _spenderAllowed = allow;
    }

    function setAllowedAmount(uint256 allowed) external {
        _allowed = allowed;
    }

    function setSpenderAllowed(bool allowed) external {
        _spenderAllowed = allowed;
    }

    /// @dev Total invocations across the three action hooks, for a single "never called" assertion.
    function totalHookCalls() external view returns (uint256) {
        return transferActionCalls + mintActionCalls + burnActionCalls;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure virtual returns (string memory);

    function _authorizeUpgrade(address) internal override { }

    /// @dev Counts the movement under the hook it would have been before the three merged into one, so the
    ///      suites keep asserting "the mint hook fired" rather than "a hook fired".
    function _countAndRecord(TransferContext calldata ctx) internal {
        if (ctx.fromWallet == bytes32(0)) mintActionCalls++;
        else if (ctx.toWallet == bytes32(0)) burnActionCalls++;
        else transferActionCalls++;
        lastContext = ctx;
        lastAmount = ctx.amountMax;
    }

}

/// @dev A rule and nothing else.
contract RuleOnlyModule is RecordingModule {

    function allowedAmount(TransferContext calldata) external view override returns (uint256) {
        return _allowed;
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.RULE;
    }

    function name() external pure override returns (string memory) {
        return "RuleOnlyModule";
    }

}

/// @dev A spender policy and nothing else.
contract SpenderOnlyModule is RecordingModule {

    function moduleCheckSpender(TransferContext calldata) external view override returns (bool) {
        return _spenderAllowed;
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.SPENDER;
    }

    function name() external pure override returns (string memory) {
        return "SpenderOnlyModule";
    }

}

/// @dev A tracker and nothing else: records each of the three actions separately, so a test can tell a mint
///      from a burn from a transfer.
contract TrackerOnlyModule is RecordingModule {

    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        _countAndRecord(ctx);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.TRACKER;
    }

    function name() external pure override returns (string memory) {
        return "TrackerOnlyModule";
    }

}

/// @dev Both vets a movement and keeps a count of it, the shape of a rule with a counter of its own.
contract RuleAndTrackerModule is RecordingModule {

    function allowedAmount(TransferContext calldata) external view override returns (uint256) {
        return _allowed;
    }

    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        _countAndRecord(ctx);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](2);
        types[0] = ModuleType.RULE;
        types[1] = ModuleType.TRACKER;
    }

    function name() external pure override returns (string memory) {
        return "RuleAndTrackerModule";
    }

}

/// @dev Names all three types, so a compliance routes every question at it.
contract AllTypesModule is RecordingModule {

    function allowedAmount(TransferContext calldata) external view override returns (uint256) {
        return _allowed;
    }

    function moduleCheckSpender(TransferContext calldata) external view override returns (bool) {
        return _spenderAllowed;
    }

    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        _countAndRecord(ctx);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](3);
        types[0] = ModuleType.RULE;
        types[1] = ModuleType.SPENDER;
        types[2] = ModuleType.TRACKER;
    }

    function name() external pure override returns (string memory) {
        return "AllTypesModule";
    }

}

/// @dev Names no type at all: binding it must be refused.
contract NoTypeModule is RecordingModule {

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](0);
    }

    function name() external pure override returns (string memory) {
        return "NoTypeModule";
    }

}

/// @dev Names the same type twice: binding it must be refused.
contract DuplicateTypeModule is RecordingModule {

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](2);
        types[0] = ModuleType.RULE;
        types[1] = ModuleType.RULE;
    }

    function name() external pure override returns (string memory) {
        return "DuplicateTypeModule";
    }

}

/// @dev Writes to its own storage inside `allowedAmount`. It cannot inherit the base, where the function is a
///      view, so it reproduces the plumbing by hand; the compliance calls it under `staticcall`, so every
///      movement it is consulted on must revert.
contract WritingRuleModule {

    uint256 public writes;

    mapping(address => bool) private _bound;

    function bindCompliance(address compliance) external {
        _bound[compliance] = true;
    }

    function unbindCompliance(address compliance) external {
        _bound[compliance] = false;
    }

    function allowedAmount(IModule.TransferContext calldata) external returns (uint256) {
        writes++;
        return type(uint256).max;
    }

    function moduleTypes() external pure returns (IModule.ModuleType[] memory types) {
        types = new IModule.ModuleType[](1);
        types[0] = IModule.ModuleType.RULE;
    }

    function isComplianceBound(address compliance) external view returns (bool) {
        return _bound[compliance];
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "WritingRuleModule";
    }

}

/// @dev Reads the ledger: refuses a recipient whose position plus pending reaches the cap. The shape of a
///      distribution rule with no ledger of its own.
contract CappedRecipientModule is RecordingModule {

    /// Zero means no cap.
    mapping(address compliance => uint256) public capOf;

    function setCap(uint256 cap) external onlyComplianceCall {
        capOf[msg.sender] = cap;
    }

    function allowedAmount(TransferContext calldata ctx) external view override returns (uint256) {
        if (ctx.toIdentity == address(0) || ctx.fromIdentity == ctx.toIdentity) return type(uint256).max;
        uint256 cap = capOf[ctx.compliance];
        if (cap == 0) return type(uint256).max;
        IComplianceLedger ledger = IComplianceLedger(ctx.compliance);
        uint256 held = ledger.positionOf(ctx.toIdentity) + ledger.pendingInOf(ctx.toIdentity);
        return held >= cap ? 0 : cap - held;
    }

    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        _countAndRecord(ctx);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](2);
        types[0] = ModuleType.RULE;
        types[1] = ModuleType.TRACKER;
    }

    function name() external pure override returns (string memory) {
        return "CappedRecipientModule";
    }

}

/// @dev A rule that also keeps a count of mints, the shape of a supply-limit rule. Its transfer and burn
///      actions stay at the base default, so a mint is the only movement it records.
contract RuleAndMintTrackerModule is RecordingModule {

    function allowedAmount(TransferContext calldata) external view override returns (uint256) {
        return _allowed;
    }

    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        _countAndRecord(ctx);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](2);
        types[0] = ModuleType.RULE;
        types[1] = ModuleType.TRACKER;
    }

    function name() external pure override returns (string memory) {
        return "RuleAndMintTrackerModule";
    }

}

/// @dev Implements a refusing `allowedAmount` but names only `TRACKER`, so the compliance must never consult
///      it for an amount. Covers the desync direction that would silently drop a rule.
contract UndeclaredRuleModule is RecordingModule {

    function allowedAmount(TransferContext calldata) external pure override returns (uint256) {
        return 0;
    }

    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        _countAndRecord(ctx);
    }

    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](1);
        types[0] = ModuleType.TRACKER;
    }

    function name() external pure override returns (string memory) {
        return "UndeclaredRuleModule";
    }

}

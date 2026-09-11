// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { AbstractModuleUpgradeable } from "contracts/compliance/modular/modules/AbstractModuleUpgradeable.sol";
import { ModuleCapabilitiesLib } from "contracts/libraries/ModuleCapabilitiesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";

/**
 * @dev A maximum-balance-per-recipient rule over reservations, the reason slots exist: declares `BOUNDS | SLOTS`,
 *      narrows the running range to what the recipient's cap still allows once every pending validation is
 *      counted at its worst case, reserves at `amountMax`, commits at the exact amount, and releases in full.
 *      A commit for an id it never reserved adds the executed amount anyway, as the hook's contract requires.
 *      Everything is keyed by the calling compliance; the counters are global for a single assertion per test.
 */
contract SlotsModule is AbstractModuleUpgradeable {

    struct Reservation {
        bytes32 toKey;
        uint256 amount;
    }

    /// Zero means no cap.
    mapping(address compliance => uint256) internal _cap;
    mapping(address compliance => mapping(bytes32 toKey => uint256)) internal _held;
    mapping(address compliance => mapping(uint256 validationId => Reservation)) internal _reservations;

    uint256 public reserveCalls;
    uint256 public commitCalls;
    uint256 public releaseCalls;
    uint256 public lastReservedId;
    uint256 public lastReservedAmount;
    uint256 public lastCommittedId;
    uint256 public lastCommittedAmount;
    uint256 public lastReleasedId;

    function initialize() external initializer {
        __AbstractModule_init();
    }

    function setCap(uint256 cap) external onlyComplianceCall {
        _cap[msg.sender] = cap;
    }

    function capOf(address compliance) external view returns (uint256) {
        return _cap[compliance];
    }

    function heldOf(address compliance, bytes calldata to) external view returns (uint256) {
        return _held[compliance][WalletKeyLib.canonicalKey(to)];
    }

    /// @dev What was committed with no live reservation lands on the zero key.
    function heldByKey(address compliance, bytes32 key) external view returns (uint256) {
        return _held[compliance][key];
    }

    function reservationOf(address compliance, uint256 validationId) external view returns (Reservation memory) {
        return _reservations[compliance][validationId];
    }

    function validationBounds(bytes calldata, bytes calldata to, uint256 currentMin, uint256 currentMax, address)
        external
        view
        virtual
        override
        returns (uint256 min, uint256 max)
    {
        min = currentMin;
        max = currentMax;
        uint256 cap = _cap[msg.sender];
        if (cap == 0) return (min, max);
        uint256 held = _held[msg.sender][WalletKeyLib.canonicalKey(to)];
        uint256 room = held >= cap ? 0 : cap - held;
        if (room < max) max = room;
    }

    function reserveSlot(uint256 validationId, bytes calldata, bytes calldata to, uint256 amountMax)
        external
        virtual
        override
        onlyComplianceCall
    {
        bytes32 toKey = WalletKeyLib.canonicalKey(to);
        _held[msg.sender][toKey] += amountMax;
        _reservations[msg.sender][validationId] = Reservation({ toKey: toKey, amount: amountMax });
        reserveCalls++;
        lastReservedId = validationId;
        lastReservedAmount = amountMax;
    }

    function commitSlot(uint256 validationId, uint256 executedAmount) external virtual override onlyComplianceCall {
        Reservation memory reservation = _reservations[msg.sender][validationId];
        if (reservation.amount != 0) {
            _held[msg.sender][reservation.toKey] =
                _held[msg.sender][reservation.toKey] - reservation.amount + executedAmount;
            delete _reservations[msg.sender][validationId];
        } else {
            // No live reservation: a module bound after issuance, or a late reconciliation. The delta applies
            // anyway; the recipient is unknown here, so it lands on the committed-without-reservation key.
            _held[msg.sender][bytes32(0)] += executedAmount;
        }
        commitCalls++;
        lastCommittedId = validationId;
        lastCommittedAmount = executedAmount;
    }

    function releaseSlot(uint256 validationId) external virtual override onlyComplianceCall {
        Reservation memory reservation = _reservations[msg.sender][validationId];
        if (reservation.amount != 0) {
            _held[msg.sender][reservation.toKey] -= reservation.amount;
            delete _reservations[msg.sender][validationId];
        }
        releaseCalls++;
        lastReleasedId = validationId;
    }

    function moduleCapabilities() external pure virtual returns (uint256) {
        return ModuleCapabilitiesLib.BOUNDS | ModuleCapabilitiesLib.SLOTS;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure virtual returns (string memory) {
        return "SlotsModule";
    }

    function _authorizeUpgrade(address) internal override { }

}

/// @dev Declares `SLOTS` only and records what reached it, for the dispatch tests.
contract SlotsOnlyModule is AbstractModuleUpgradeable {

    uint256 public reserveCalls;
    uint256 public commitCalls;
    uint256 public releaseCalls;
    uint256 public lastValidationId;
    bytes public lastFrom;
    bytes public lastTo;
    uint256 public lastAmountMax;
    uint256 public lastExecutedAmount;

    function initialize() external initializer {
        __AbstractModule_init();
    }

    function reserveSlot(uint256 validationId, bytes calldata from, bytes calldata to, uint256 amountMax)
        external
        override
        onlyComplianceCall
    {
        reserveCalls++;
        lastValidationId = validationId;
        lastFrom = from;
        lastTo = to;
        lastAmountMax = amountMax;
    }

    function commitSlot(uint256 validationId, uint256 executedAmount) external override onlyComplianceCall {
        commitCalls++;
        lastValidationId = validationId;
        lastExecutedAmount = executedAmount;
    }

    function releaseSlot(uint256 validationId) external override onlyComplianceCall {
        releaseCalls++;
        lastValidationId = validationId;
    }

    function moduleCapabilities() external pure returns (uint256) {
        return ModuleCapabilitiesLib.SLOTS;
    }

    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "SlotsOnlyModule";
    }

    function _authorizeUpgrade(address) internal override { }

}

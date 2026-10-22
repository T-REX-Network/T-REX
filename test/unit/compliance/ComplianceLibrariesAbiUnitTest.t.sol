// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";

import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { IModularCompliance } from "contracts/compliance/modular/IModularCompliance.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

/// @dev Events and errors raised inside `ModuleSetLib`, `ComplianceLedgerLib` and `TransferValidationLib` are
///  redeclared on the compliance's interfaces to stay in its ABI. This pins each redeclaration to the
///  definition the libraries actually use.
contract ComplianceLibrariesAbiUnitTest is Test {

    function test_events_MatchTheLibraryDefinitions() public pure {
        assertEq(IModularCompliance.ModuleInteraction.selector, EventsLib.ModuleInteraction.selector);
        assertEq(IModularCompliance.ModuleAdded.selector, EventsLib.ModuleAdded.selector);
        assertEq(IModularCompliance.ModuleTypesRecorded.selector, EventsLib.ModuleTypesRecorded.selector);
        assertEq(IComplianceLedger.PositionFixed.selector, EventsLib.PositionFixed.selector);
        assertEq(ITransferValidation.TransferValidationIssued.selector, EventsLib.TransferValidationIssued.selector);
    }

    function test_errors_MatchTheLibraryDefinitions() public pure {
        assertEq(
            IModularCompliance.ComplianceNotSuitableForBindingToModule.selector,
            ErrorsLib.ComplianceNotSuitableForBindingToModule.selector
        );
        assertEq(IModularCompliance.MaxModulesReached.selector, ErrorsLib.MaxModulesReached.selector);
        assertEq(IModularCompliance.ModuleAlreadyBound.selector, ErrorsLib.ModuleAlreadyBound.selector);
        assertEq(IModularCompliance.ModuleHasNoType.selector, ErrorsLib.ModuleHasNoType.selector);
        assertEq(IModularCompliance.DuplicateModuleType.selector, ErrorsLib.DuplicateModuleType.selector);
        assertEq(IModularCompliance.ModuleNotBound.selector, ErrorsLib.ModuleNotBound.selector);
        assertEq(IComplianceLedger.InsufficientPosition.selector, ErrorsLib.InsufficientPosition.selector);
        assertEq(IComplianceLedger.FromAndToAreTheSame.selector, ErrorsLib.FromAndToAreTheSame.selector);
    }

}

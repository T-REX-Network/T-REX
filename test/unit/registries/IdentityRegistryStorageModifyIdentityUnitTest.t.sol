// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageModifyIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    address private newIdentity = makeAddr("newIdentity");

    function test_modifyStoredIdentity_EmitsIdentityOverridden_WhenGlobalIdentityDiffers() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.expectEmit(address(irs));
        emit ERC3643EventsLib.IdentityModified(IIdentity(localIdentity), IIdentity(newIdentity));
        vm.expectEmit(address(irs));
        emit EventsLib.InvestorIdentityChanged(wallet);
        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverridden(wallet, IIdentity(globalIdentity), IIdentity(newIdentity));
        irs.modifyStoredIdentity(wallet, IIdentity(newIdentity));

        assertEq(address(irs.storedIdentity(wallet)), newIdentity);
    }

    function test_modifyStoredIdentity_EmitsIdentityOverrideReleased_WhenNewIdentityMatchesGlobal() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.expectEmit(address(irs));
        emit ERC3643EventsLib.IdentityModified(IIdentity(localIdentity), IIdentity(globalIdentity));
        vm.expectEmit(address(irs));
        emit EventsLib.InvestorIdentityChanged(wallet);
        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverrideReleased(wallet, IIdentity(localIdentity), IIdentity(globalIdentity));
        irs.modifyStoredIdentity(wallet, IIdentity(globalIdentity));

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
    }

    function test_modifyStoredIdentity_EmitsNoOverrideSignal_WhenNoRegistryBound() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.recordLogs();
        irs.modifyStoredIdentity(wallet, IIdentity(newIdentity));

        _assertOnlyModificationLogs();
    }

    function test_modifyStoredIdentity_EmitsNoOverrideSignal_WhenGlobalRegistryDoesNotKnowTheWallet() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        vm.recordLogs();
        irs.modifyStoredIdentity(otherWallet, IIdentity(newIdentity));

        _assertOnlyModificationLogs();
    }

    function test_modifyStoredIdentity_EmitsNoOverrideSignal_WhenIdentityIsUnchangedAndMatchesGlobal() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        vm.recordLogs();
        irs.modifyStoredIdentity(wallet, IIdentity(globalIdentity));

        _assertOnlyModificationLogs();
    }

    function test_modifyStoredIdentity_EmitsIdentityOverridden_FromSecondBoundRegistry() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverridden(otherWallet, IIdentity(otherIdentity), IIdentity(newIdentity));
        irs.modifyStoredIdentity(otherWallet, IIdentity(newIdentity));
    }

    function _assertOnlyModificationLogs() private {
        bytes32[] memory selectors = new bytes32[](2);
        selectors[0] = ERC3643EventsLib.IdentityModified.selector;
        selectors[1] = EventsLib.InvestorIdentityChanged.selector;
        _assertLogSelectors(vm.getRecordedLogs(), selectors);
    }

}

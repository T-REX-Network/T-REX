// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageRemoveIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    function test_removeIdentityFromStorage_EmitsIdentityOverrideReleased_WhenGlobalIdentityDiffers() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.expectEmit(address(irs));
        emit IERC3643IdentityRegistryStorage.IdentityUnstored(wallet, IIdentity(localIdentity));
        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverrideReleased(wallet, IIdentity(localIdentity), IIdentity(globalIdentity));
        irs.removeIdentityFromStorage(wallet);

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
        assertFalse(irs.isLocallyRegistered(wallet));
    }

    function test_removeIdentityFromStorage_EmitsOnlyIdentityUnstored_WhenGlobalIdentityMatches() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        vm.recordLogs();
        irs.removeIdentityFromStorage(wallet);

        _assertOnlyIdentityUnstored();
    }

    function test_removeIdentityFromStorage_EmitsOnlyIdentityUnstored_WhenGlobalRegistryDoesNotKnowTheWallet() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        vm.recordLogs();
        irs.removeIdentityFromStorage(otherWallet);

        _assertOnlyIdentityUnstored();
    }

    function test_removeIdentityFromStorage_EmitsOnlyIdentityUnstored_WhenNoRegistryBound() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.recordLogs();
        irs.removeIdentityFromStorage(wallet);

        _assertOnlyIdentityUnstored();
    }

    function test_removeIdentityFromStorage_EmitsIdentityOverrideReleased_FromSecondBoundRegistry() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverrideReleased(otherWallet, IIdentity(localIdentity), IIdentity(otherIdentity));
        irs.removeIdentityFromStorage(otherWallet);
    }

    function _assertOnlyIdentityUnstored() private {
        bytes32[] memory selectors = new bytes32[](1);
        selectors[0] = IERC3643IdentityRegistryStorage.IdentityUnstored.selector;
        _assertLogSelectors(vm.getRecordedLogs(), selectors);
    }

}

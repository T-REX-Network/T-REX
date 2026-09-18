// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageAddIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    function test_addIdentityToStorage_EmitsIdentityOverridden_WhenGlobalIdentityDiffers() public {
        irs.bindIdentityRegistry(registry);

        vm.expectEmit(address(irs));
        emit IERC3643IdentityRegistryStorage.IdentityStored(wallet, IIdentity(localIdentity));
        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverridden(wallet, IIdentity(globalIdentity), IIdentity(localIdentity));
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        assertEq(address(irs.storedIdentity(wallet)), localIdentity);
        assertTrue(irs.isLocallyRegistered(wallet));
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenNoRegistryBound() public {
        vm.recordLogs();
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenGlobalRegistryDoesNotKnowTheWallet() public {
        irs.bindIdentityRegistry(registry);

        vm.recordLogs();
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenGlobalIdentityMatches() public {
        irs.bindIdentityRegistry(registry);

        vm.recordLogs();
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
    }

    function test_addIdentityToStorage_EmitsIdentityOverridden_FromSecondBoundRegistry() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);

        vm.expectEmit(address(irs));
        emit EventsLib.IdentityOverridden(otherWallet, IIdentity(otherIdentity), IIdentity(localIdentity));
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
    }

    function _assertOnlyIdentityStored(Vm.Log[] memory logs) private pure {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC3643IdentityRegistryStorage.IdentityStored.selector);
    }

}

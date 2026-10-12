// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Vm } from "@forge-std/Test.sol";
import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageAddIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    function test_addIdentityToStorage_RevertsWhen_FactoryLinksWalletToAnotherIdentity() public {
        irs.bindIdentityRegistry(registry);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, wallet, globalIdentity));
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        assertEq(uint8(irs.localAccountStatus(wallet)), uint8(IIdentityFactory.AccountStatus.None));
    }

    function test_addIdentityToStorage_RevertsWhen_SecondBoundRegistryLinksWalletToAnotherIdentity() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, otherWallet, otherIdentity)
        );
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenNoRegistryBound() public {
        vm.recordLogs();
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
        assertEq(uint8(irs.localAccountStatus(wallet)), uint8(IIdentityFactory.AccountStatus.Active));
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
        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
    }

    function test_addIdentityToStorage_RevertsWhen_WalletWasRevoked() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
        irs.removeIdentityFromStorage(wallet);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletAlreadyRevoked.selector, wallet));
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
    }

    function _assertOnlyIdentityStored(Vm.Log[] memory logs) private pure {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC3643IdentityRegistryStorage.IdentityStored.selector);
    }

}

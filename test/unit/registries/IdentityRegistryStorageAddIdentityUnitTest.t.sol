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

    /// @dev The storage reads no IdentityFactory; the registry refuses a binding that contradicts its own factory.
    function test_addIdentityToStorage_DoesNotAskTheBoundRegistriesFactories() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);
        vm.expectCall(idFactory, abi.encodeWithSelector(IIdentityFactory.getIdentityIncludingRevoked.selector), 0);
        vm.expectCall(otherIdFactory, abi.encodeWithSelector(IIdentityFactory.getIdentityIncludingRevoked.selector), 0);

        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        assertEq(address(irs.storedIdentity(wallet)), localIdentity);
        assertEq(address(irs.storedIdentity(otherWallet)), localIdentity);
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

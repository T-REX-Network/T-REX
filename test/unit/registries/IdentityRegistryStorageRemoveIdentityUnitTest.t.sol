// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageRemoveIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    function test_removeIdentityFromStorage_RevokesAndKeepsTheOwner() public {
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        vm.recordLogs();
        irs.removeIdentityFromStorage(otherWallet);

        _assertOnlyIdentityRevoked();
        assertEq(address(irs.storedIdentity(otherWallet)), localIdentity);
        assertEq(uint8(irs.localAccountStatus(otherWallet)), uint8(IIdentityFactory.AccountStatus.Revoked));
    }

    function test_removeIdentityFromStorage_KeepsTheLocalOwner_WhenGlobalIdentityMatches() public {
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        vm.expectEmit(address(irs));
        emit EventsLib.IdentityRevoked(wallet, IIdentity(globalIdentity));
        irs.removeIdentityFromStorage(wallet);

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
        assertEq(uint8(irs.localAccountStatus(wallet)), uint8(IIdentityFactory.AccountStatus.Revoked));
    }

    function test_removeIdentityFromStorage_RevertsWhen_AlreadyRevoked() public {
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
        irs.removeIdentityFromStorage(otherWallet);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletNotActive.selector, otherWallet));
        irs.removeIdentityFromStorage(otherWallet);
    }

    function test_removeIdentityFromStorage_RevertsWhen_WalletIsOnlyBoundGlobally() public {
        irs.bindIdentityRegistry(registry);

        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        irs.removeIdentityFromStorage(wallet);
    }

    function _assertOnlyIdentityRevoked() private {
        bytes32[] memory selectors = new bytes32[](1);
        selectors[0] = EventsLib.IdentityRevoked.selector;
        _assertLogSelectors(vm.getRecordedLogs(), selectors);
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageRemoveIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    function test_removeIdentityFromStorage_RevokesAndKeepsTheOwner() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.recordLogs();
        irs.removeIdentityFromStorage(wallet);

        _assertOnlyIdentityUnstored();
        assertEq(address(irs.storedIdentity(wallet)), localIdentity);
        assertEq(uint8(irs.localAccountStatus(wallet)), uint8(IIdentityFactory.AccountStatus.Revoked));
    }

    function test_removeIdentityFromStorage_KeepsTheLocalOwner_WhenGlobalIdentityMatches() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        vm.expectEmit(address(irs));
        emit IERC3643IdentityRegistryStorage.IdentityUnstored(wallet, IIdentity(globalIdentity));
        irs.removeIdentityFromStorage(wallet);

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
        assertEq(uint8(irs.localAccountStatus(wallet)), uint8(IIdentityFactory.AccountStatus.Revoked));
    }

    function test_removeIdentityFromStorage_RevertsWhen_AlreadyRevoked() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
        irs.removeIdentityFromStorage(wallet);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletNotActive.selector, wallet));
        irs.removeIdentityFromStorage(wallet);
    }

    function test_removeIdentityFromStorage_RevertsWhen_WalletIsOnlyBoundGlobally() public {
        irs.bindIdentityRegistry(registry);

        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        irs.removeIdentityFromStorage(wallet);
    }

    function _assertOnlyIdentityUnstored() private {
        bytes32[] memory selectors = new bytes32[](1);
        selectors[0] = IERC3643IdentityRegistryStorage.IdentityUnstored.selector;
        _assertLogSelectors(vm.getRecordedLogs(), selectors);
    }

}

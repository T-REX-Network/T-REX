// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";

import {
    IdentityRegistryStorageBaseUnitTest
} from "test/unit/registries/helpers/IdentityRegistryStorageBaseUnitTest.t.sol";

contract IdentityRegistryStorageModifyIdentityUnitTest is IdentityRegistryStorageBaseUnitTest {

    address private newIdentity = makeAddr("newIdentity");

    function test_modifyStoredIdentity_RevertsWhen_WalletIsBound() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, wallet, localIdentity));
        irs.modifyStoredIdentity(wallet, IIdentity(newIdentity));

        assertEq(address(irs.storedIdentity(wallet)), localIdentity);
    }

    function test_modifyStoredIdentity_RevertsWhen_RebindingToTheSameIdentity() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletAlreadyLinkedToIdentity.selector, wallet));
        irs.modifyStoredIdentity(wallet, IIdentity(localIdentity));
    }

    function test_modifyStoredIdentity_RevertsWhen_WalletWasRevoked() public {
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
        irs.removeIdentityFromStorage(wallet);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletAlreadyRevoked.selector, wallet));
        irs.modifyStoredIdentity(wallet, IIdentity(newIdentity));
    }

    function test_modifyStoredIdentity_RevertsWhen_WalletIsOnlyBoundGlobally() public {
        irs.bindIdentityRegistry(registry);

        vm.expectRevert(ErrorsLib.AddressNotYetStored.selector);
        irs.modifyStoredIdentity(wallet, IIdentity(newIdentity));
    }

}

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

    /// @dev Every write is checked against the storage's IdentityFactory, whoever the writer is.
    function test_addIdentityToStorage_RevertWhen_TheStorageFactoryLinksTheWalletToAnotherIdentity() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, wallet, globalIdentity));
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
    }

    /// @dev Binding the identity the factory already links is allowed, and so is a wallet the factory does not know.
    function test_addIdentityToStorage_Succeeds_WhenTheStorageFactoryAgreesOrDoesNotKnowTheWallet() public {
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
        assertEq(address(irs.storedIdentity(otherWallet)), localIdentity);
    }

    /// @dev Unbinding every registry does not lift the check, since the factory is the storage's own.
    function test_addIdentityToStorage_RevertWhen_EveryRegistryIsUnbound_AndTheFactoryLinksTheWalletElsewhere() public {
        irs.bindIdentityRegistry(registry);
        irs.unbindIdentityRegistry(registry);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, wallet, globalIdentity));
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenTheFactoryDoesNotKnowTheWallet() public {
        vm.recordLogs();
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
        assertEq(uint8(irs.localAccountStatus(otherWallet)), uint8(IIdentityFactory.AccountStatus.Active));
    }

    function test_addIdentityToStorage_EmitsOnlyIdentityStored_WhenGlobalIdentityMatches() public {
        vm.recordLogs();
        irs.addIdentityToStorage(wallet, IIdentity(globalIdentity), 0);

        _assertOnlyIdentityStored(vm.getRecordedLogs());
        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
    }

    function test_addIdentityToStorage_RevertsWhen_WalletWasRevoked() public {
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
        irs.removeIdentityFromStorage(otherWallet);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletAlreadyRevoked.selector, otherWallet));
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
    }

    function _assertOnlyIdentityStored(Vm.Log[] memory logs) private pure {
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC3643IdentityRegistryStorage.IdentityStored.selector);
    }

}

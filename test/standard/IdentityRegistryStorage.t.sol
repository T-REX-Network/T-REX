// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";

import { IdentityRegistryStorageMock } from "./mocks/Mocks.sol";

/// @dev ERC-3643 standard: Identity Registry Storage.
///
///  Runs against the standard base alone (issue #65), so this file must pass unchanged when
///  OpenZeppelin's base replaces ours.
contract IdentityRegistryStorageBaseTest is Test {

    IdentityRegistryStorageMock internal storage_;

    address internal investor = makeAddr("investor");
    IIdentity internal identity = IIdentity(makeAddr("identity"));
    IIdentity internal newIdentity = IIdentity(makeAddr("newIdentity"));
    address internal registry = makeAddr("registry");

    uint16 internal constant COUNTRY = 42;

    function setUp() public {
        storage_ = new IdentityRegistryStorageMock();
    }

    function test_storedIdentity_IsZeroForUnknownInvestor() public view {
        assertEq(address(storage_.storedIdentity(investor)), address(0));
        assertEq(storage_.storedInvestorCountry(investor), 0);
    }

    function test_addIdentityToStorage_StoresIdentityAndCountry() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        assertEq(address(storage_.storedIdentity(investor)), address(identity));
        assertEq(storage_.storedInvestorCountry(investor), COUNTRY);
    }

    function test_addIdentityToStorage_EmitsIdentityStored() public {
        vm.expectEmit(true, true, false, true, address(storage_));
        emit IERC3643IdentityRegistryStorage.IdentityStored(investor, identity);

        storage_.addIdentityToStorage(investor, identity, COUNTRY);
    }

    function test_addIdentityToStorage_RevertWhen_InvestorZeroAddress() public {
        vm.expectRevert(ERC3643ErrorsLib.ZeroAddress.selector);
        storage_.addIdentityToStorage(address(0), identity, COUNTRY);
    }

    function test_addIdentityToStorage_RevertWhen_IdentityZeroAddress() public {
        vm.expectRevert(ERC3643ErrorsLib.ZeroAddress.selector);
        storage_.addIdentityToStorage(investor, IIdentity(address(0)), COUNTRY);
    }

    function test_addIdentityToStorage_RevertWhen_AlreadyStored() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        vm.expectRevert(ERC3643ErrorsLib.AddressAlreadyStored.selector);
        storage_.addIdentityToStorage(investor, newIdentity, COUNTRY);
    }

    function test_modifyStoredIdentity_ReplacesTheIdentity() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        storage_.modifyStoredIdentity(investor, newIdentity);

        assertEq(address(storage_.storedIdentity(investor)), address(newIdentity));
        assertEq(storage_.storedInvestorCountry(investor), COUNTRY, "country must be untouched");
    }

    function test_modifyStoredIdentity_EmitsIdentityModified() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        vm.expectEmit(true, true, false, true, address(storage_));
        emit IERC3643IdentityRegistryStorage.IdentityModified(identity, newIdentity);

        storage_.modifyStoredIdentity(investor, newIdentity);
    }

    function test_modifyStoredIdentity_RevertWhen_NotYetStored() public {
        vm.expectRevert(ERC3643ErrorsLib.AddressNotYetStored.selector);
        storage_.modifyStoredIdentity(investor, newIdentity);
    }

    function test_modifyStoredInvestorCountry_ReplacesTheCountry() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        storage_.modifyStoredInvestorCountry(investor, 99);

        assertEq(storage_.storedInvestorCountry(investor), 99);
        assertEq(address(storage_.storedIdentity(investor)), address(identity), "identity must be untouched");
    }

    function test_modifyStoredInvestorCountry_EmitsCountryModified() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        vm.expectEmit(true, true, false, true, address(storage_));
        emit IERC3643IdentityRegistryStorage.CountryModified(investor, 99);

        storage_.modifyStoredInvestorCountry(investor, 99);
    }

    function test_modifyStoredInvestorCountry_RevertWhen_NotYetStored() public {
        vm.expectRevert(ERC3643ErrorsLib.AddressNotYetStored.selector);
        storage_.modifyStoredInvestorCountry(investor, 99);
    }

    function test_removeIdentityFromStorage_ClearsTheRecord() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        storage_.removeIdentityFromStorage(investor);

        assertEq(address(storage_.storedIdentity(investor)), address(0));
        assertEq(storage_.storedInvestorCountry(investor), 0);
    }

    function test_removeIdentityFromStorage_EmitsIdentityUnstored() public {
        storage_.addIdentityToStorage(investor, identity, COUNTRY);

        vm.expectEmit(true, true, false, true, address(storage_));
        emit IERC3643IdentityRegistryStorage.IdentityUnstored(investor, identity);

        storage_.removeIdentityFromStorage(investor);
    }

    function test_removeIdentityFromStorage_RevertWhen_NotYetStored() public {
        vm.expectRevert(ERC3643ErrorsLib.AddressNotYetStored.selector);
        storage_.removeIdentityFromStorage(investor);
    }

    function test_bindIdentityRegistry_LinksTheRegistry() public {
        storage_.bindIdentityRegistry(registry);

        address[] memory linked = storage_.linkedIdentityRegistries();
        assertEq(linked.length, 1);
        assertEq(linked[0], registry);
    }

    function test_bindIdentityRegistry_EmitsIdentityRegistryBound() public {
        vm.expectEmit(true, false, false, true, address(storage_));
        emit IERC3643IdentityRegistryStorage.IdentityRegistryBound(registry);

        storage_.bindIdentityRegistry(registry);
    }

    function test_unbindIdentityRegistry_UnlinksTheRegistry() public {
        storage_.bindIdentityRegistry(registry);

        storage_.unbindIdentityRegistry(registry);

        assertEq(storage_.linkedIdentityRegistries().length, 0);
    }

    function test_unbindIdentityRegistry_EmitsIdentityRegistryUnbound() public {
        storage_.bindIdentityRegistry(registry);

        vm.expectEmit(true, false, false, true, address(storage_));
        emit IERC3643IdentityRegistryStorage.IdentityRegistryUnbound(registry);

        storage_.unbindIdentityRegistry(registry);
    }

    function test_unbindIdentityRegistry_RevertWhen_NotBound() public {
        vm.expectRevert(ERC3643ErrorsLib.IdentityRegistryNotStored.selector);
        storage_.unbindIdentityRegistry(registry);
    }

}

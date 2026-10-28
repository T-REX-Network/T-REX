// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";

import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @dev The registry and the identity factory are mocked at the ABI level: the storage only asks the
///      storage's factory for the wallet's identity.
contract IdentityRegistryStorageStoredIdentityUnitTest is Test {

    IdentityRegistryStorage private irs;
    AccessManager private accessManager;

    address private registry = makeAddr("registry");
    address private idFactory = makeAddr("idFactory");
    address private wallet = makeAddr("wallet");
    address private globalIdentity = makeAddr("globalIdentity");
    address private localIdentity = makeAddr("localIdentity");

    address private otherWallet = makeAddr("otherWallet");

    function setUp() public {
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.IRS_BINDER), address(this), 0);
        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.IRS_WRITER), address(this), 0);

        address beacon = BeaconProxyDeployer.newBeacon(address(new IdentityRegistryStorage()));
        irs = IdentityRegistryStorage(
            BeaconProxyDeployer.newProxy(
                beacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0), idFactory))
            )
        );
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs), 1);

        vm.mockCall(registry, abi.encodeCall(IAccessManaged.authority, ()), abi.encode(address(accessManager)));
        vm.mockCall(registry, abi.encodeCall(ITREXRegistry.identityFactory, ()), abi.encode(idFactory));
        vm.mockCall(
            idFactory,
            abi.encodeCall(IIdentityFactory.getIdentityIncludingRevoked, (_account(wallet))),
            abi.encode(globalIdentity, IIdentityFactory.AccountStatus.Active)
        );

        vm.mockCall(
            idFactory,
            abi.encodeCall(IIdentityFactory.getIdentityIncludingRevoked, (_account(otherWallet))),
            abi.encode(address(0), IIdentityFactory.AccountStatus.None)
        );
    }

    function test_storedIdentity_ReturnsZero_WhenNoLocalBinding() public view {
        assertEq(address(irs.storedIdentity(wallet)), address(0));
    }

    /// @dev The storage answers its own bindings only, whatever its factory knows.
    function test_storedIdentity_ReturnsZero_WhenOnlyTheFactoryKnowsTheWallet() public {
        irs.bindIdentityRegistry(registry);

        assertEq(address(irs.storedIdentity(wallet)), address(0));
    }

    function test_storedIdentity_ReturnsTheLocalBinding() public {
        irs.addIdentityToStorage(otherWallet, IIdentity(localIdentity), 0);
        irs.bindIdentityRegistry(registry);

        assertEq(address(irs.storedIdentity(otherWallet)), localIdentity);
    }

    function _account(address _wallet) private view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, _wallet);
    }

}

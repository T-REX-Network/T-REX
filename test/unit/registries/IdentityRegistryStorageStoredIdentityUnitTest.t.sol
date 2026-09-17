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
///      bound registry for its factory and that factory for the wallet's identity.
contract IdentityRegistryStorageStoredIdentityUnitTest is Test {

    IdentityRegistryStorage private irs;
    AccessManager private accessManager;

    address private registry = makeAddr("registry");
    address private idFactory = makeAddr("idFactory");
    address private wallet = makeAddr("wallet");
    address private globalIdentity = makeAddr("globalIdentity");
    address private localIdentity = makeAddr("localIdentity");

    address private otherRegistry = makeAddr("otherRegistry");
    address private otherIdFactory = makeAddr("otherIdFactory");
    address private otherWallet = makeAddr("otherWallet");
    address private otherIdentity = makeAddr("otherIdentity");

    function setUp() public {
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.IRS_BINDER, address(this), 0);
        accessManager.grantRole(RolesLib.AGENT, address(this), 0);

        address beacon = BeaconProxyDeployer.newBeacon(address(new IdentityRegistryStorage()));
        irs = IdentityRegistryStorage(
            BeaconProxyDeployer.newProxy(
                beacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0)))
            )
        );
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs));

        vm.mockCall(
            registry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.mockCall(registry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(idFactory));
        vm.mockCall(
            idFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(wallet))), abi.encode(globalIdentity)
        );

        // A second registry built on another factory: it knows `otherWallet`, the first one does not.
        vm.mockCall(
            otherRegistry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.mockCall(
            otherRegistry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(otherIdFactory)
        );
        vm.mockCall(
            idFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(otherWallet))), abi.encode(address(0))
        );
        vm.mockCall(
            otherIdFactory,
            abi.encodeCall(IIdentityFactory.getIdentity, (_account(otherWallet))),
            abi.encode(otherIdentity)
        );
    }

    function test_storedIdentity_ReturnsZero_WhenNoRegistryBound_AndNoLocalBinding() public view {
        assertEq(address(irs.storedIdentity(wallet)), address(0));
    }

    function test_storedIdentity_FallsBackThroughBoundRegistryFactory() public {
        irs.bindIdentityRegistry(registry);

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
    }

    function test_storedIdentity_PrefersLocalBinding() public {
        irs.bindIdentityRegistry(registry);
        irs.addIdentityToStorage(wallet, IIdentity(localIdentity), 0);

        assertEq(address(irs.storedIdentity(wallet)), localIdentity);
    }

    function test_storedIdentity_ScansEveryBoundRegistryFactory() public {
        irs.bindIdentityRegistry(registry);
        irs.bindIdentityRegistry(otherRegistry);

        assertEq(address(irs.storedIdentity(wallet)), globalIdentity);
        assertEq(address(irs.storedIdentity(otherWallet)), otherIdentity);
    }

    function test_storedIdentity_ReturnsZero_WhenNoBoundRegistryFactoryKnowsTheWallet() public {
        irs.bindIdentityRegistry(registry);

        assertEq(address(irs.storedIdentity(otherWallet)), address(0));
    }

    function _account(address _wallet) private view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, _wallet);
    }

}

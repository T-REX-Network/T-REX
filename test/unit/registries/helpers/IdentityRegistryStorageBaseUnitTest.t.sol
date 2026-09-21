// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test, Vm } from "@forge-std/Test.sol";
import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";

import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

/// @dev The registries and their identity factories are mocked at the ABI level: on a write the storage only
///      asks each bound registry for its factory and that factory for the wallet's identity, to tell whether the
///      local binding shadows a global one. `wallet` is known to the first factory as `globalIdentity`,
///      `otherWallet` only to the second one as `otherIdentity`.
abstract contract IdentityRegistryStorageBaseUnitTest is Test {

    IdentityRegistryStorage internal irs;
    AccessManager internal accessManager;

    address internal registry = makeAddr("registry");
    address internal idFactory = makeAddr("idFactory");
    address internal wallet = makeAddr("wallet");
    address internal globalIdentity = makeAddr("globalIdentity");
    address internal localIdentity = makeAddr("localIdentity");

    address internal otherRegistry = makeAddr("otherRegistry");
    address internal otherIdFactory = makeAddr("otherIdFactory");
    address internal otherWallet = makeAddr("otherWallet");
    address internal otherIdentity = makeAddr("otherIdentity");

    function setUp() public virtual {
        accessManager = new AccessManager(address(this));
        accessManager.grantRole(RolesLib.forNamespace(1, RolesLib.Role.IRS_BINDER), address(this), 0);
        accessManager.grantRole(RolesLib.forNamespace(1, RolesLib.Role.AGENT), address(this), 0);

        address beacon = BeaconProxyDeployer.newBeacon(address(new IdentityRegistryStorage()));
        irs = IdentityRegistryStorage(
            BeaconProxyDeployer.newProxy(
                beacon, abi.encodeCall(IdentityRegistryStorage.init, (address(accessManager), address(0)))
            )
        );
        AccessManagerSetupLib.setupIdentityRegistryStorageRoles(accessManager, address(irs), 1);

        vm.mockCall(
            registry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.mockCall(registry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(idFactory));
        vm.mockCall(
            idFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(wallet))), abi.encode(globalIdentity)
        );
        vm.mockCall(
            idFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(otherWallet))), abi.encode(address(0))
        );

        // A second registry built on another factory: it knows `otherWallet`, the first one does not.
        vm.mockCall(
            otherRegistry, abi.encodeWithSelector(IAccessManaged.authority.selector), abi.encode(address(accessManager))
        );
        vm.mockCall(
            otherRegistry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(otherIdFactory)
        );
        vm.mockCall(
            otherIdFactory, abi.encodeCall(IIdentityFactory.getIdentity, (_account(wallet))), abi.encode(address(0))
        );
        vm.mockCall(
            otherIdFactory,
            abi.encodeCall(IIdentityFactory.getIdentity, (_account(otherWallet))),
            abi.encode(otherIdentity)
        );
    }

    /// @dev Asserts the recorded logs are exactly these event selectors, in order.
    function _assertLogSelectors(Vm.Log[] memory logs, bytes32[] memory selectors) internal pure {
        assertEq(logs.length, selectors.length);
        for (uint256 i = 0; i < selectors.length; i++) {
            assertEq(logs[i].topics[0], selectors[i]);
        }
    }

    function _account(address _wallet) internal view returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(block.chainid, _wallet);
    }

}

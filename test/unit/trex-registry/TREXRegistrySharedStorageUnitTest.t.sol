// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";

/// @notice Two registries share one storage, each on its own IdentityFactory. `registry` is on `idFactory`, which
///         binds alice to `aliceIdentity`. `otherRegistry` is on `otherFactory`, which binds alice to
///         `otherIdentity` only where a test says so. No claim topic is required, so any resolved identity is
///         verified: a wrong resolution shows up directly in `isVerified`.
contract TREXRegistrySharedStorageUnitTest is TREXRegistryBaseUnitTest {

    address private otherFactory = makeAddr("otherFactory");
    IIdentity private otherIdentity = IIdentity(makeAddr("otherIdentity"));
    TREXRegistry private otherRegistry;

    function setUp() public override {
        super.setUp();

        vm.mockCall(
            otherFactory,
            abi.encodeWithSelector(IIdentityFactory.getIdentityIncludingRevoked.selector),
            abi.encode(address(0), IIdentityFactory.AccountStatus.None)
        );
        vm.mockCall(otherFactory, abi.encodeWithSelector(IIdentityFactory.identityTypeOf.selector), abi.encode(0));
        otherRegistry = _deployRegistryOn(otherFactory);

        vm.prank(deployer);
        identityRegistryStorage.bindIdentityRegistry(address(otherRegistry));
    }

    /// @notice Unbinding one registry from the storage does not change who a wallet is in another registry.
    function test_identity_StaysTheSame_WhenAnotherRegistryIsUnbound() public {
        _otherFactoryBindsAliceTo(otherIdentity);
        IIdentity before = otherRegistry.identity(alice);

        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(address(registry));

        assertEq(address(before), address(otherIdentity), "resolved through its own factory");
        assertEq(address(otherRegistry.identity(alice)), address(before), "unchanged by the unbind");
    }

    /// @notice A wallet revoked in one registry's factory and unknown to another's is not admitted by the other
    ///         registry: it is never resolved through the factory that revoked it.
    function test_isVerified_False_WhenOnlyAnotherRegistrysFactoryKnowsTheRevokedWallet() public {
        vm.prank(address(aliceIdentity));
        idFactory.revokeAccount(InteroperableAddress.formatEvmV1(block.chainid, alice));

        assertFalse(registry.isVerified(alice), "revoked in its own factory");
        assertFalse(otherRegistry.isVerified(alice), "unknown to its own factory");
        assertEq(address(otherRegistry.identity(alice)), address(0));
    }

    /// @notice A registry never resolves a wallet to an identity of another registry's factory.
    function test_identity_Zero_WhenOnlyAnotherRegistrysFactoryKnowsTheWallet() public view {
        assertEq(address(registry.identity(alice)), address(aliceIdentity));

        assertEq(address(otherRegistry.identity(alice)), address(0));
        assertFalse(otherRegistry.contains(alice));
        assertFalse(otherRegistry.isVerified(alice));
    }

    /// @notice A registry unbound from the storage it reads keeps resolving the wallets its factory knows.
    function test_identity_StillResolvesThroughItsFactory_AfterTheRegistryIsUnbound() public {
        vm.prank(deployer);
        identityRegistryStorage.unbindIdentityRegistry(address(registry));

        assertEq(address(registry.identity(alice)), address(aliceIdentity));
        assertTrue(registry.isVerified(alice));
    }

    function _otherFactoryBindsAliceTo(IIdentity identity) private {
        vm.mockCall(
            otherFactory,
            abi.encodeCall(
                IIdentityFactory.getIdentityIncludingRevoked, (InteroperableAddress.formatEvmV1(block.chainid, alice))
            ),
            abi.encode(address(identity), IIdentityFactory.AccountStatus.Active)
        );
    }

    /// @dev A registry on `factory`, pointed at the shared storage and sharing the suite's AccessManager.
    function _deployRegistryOn(address factory) private returns (TREXRegistry) {
        return TREXRegistry(
            address(
                new ERC1967Proxy(
                    address(new TREXRegistry(factory)),
                    abi.encodeCall(
                        TREXRegistry.init,
                        (
                            address(identityRegistryStorage),
                            address(accessManager),
                            new uint256[](0),
                            new address[](0),
                            new uint256[][](0)
                        )
                    )
                )
            )
        );
    }

}

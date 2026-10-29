// SPDX-License-Identifier: GPL-3.0
//
//                                             :+#####%%%%%%%%%%%%%%+
//                                         .-*@@@%+.:+%@@@@@%%#***%@@%=
//                                     :=*%@@@#=.      :#@@%       *@@@%=
//                       .-+*%@%*-.:+%@@@@@@+.     -*+:  .=#.       :%@@@%-
//                   :=*@@@@%%@@@@@@@@@%@@@-   .=#@@@%@%=             =@@@@#.
//             -=+#%@@%#*=:.  :%@@@@%.   -*@@#*@@@@@@@#=:-              *@@@@+
//            =@@%=:.     :=:   *@@@@@%#-   =%*%@@@@#+-.        =+       :%@@@%-
//           -@@%.     .+@@@     =+=-.         @@#-           +@@@%-       =@@@@%:
//          :@@@.    .+@@#%:                   :    .=*=-::.-%@@@+*@@=       +@@@@#.
//          %@@:    +@%%*                         =%@@@@@@@@@@@#.  .*@%-       +@@@@*.
//         #@@=                                .+@@@@%:=*@@@@@-      :%@%:      .*@@@@+
//        *@@*                                +@@@#-@@%-:%@@*          +@@#.      :%@@@@-
//       -@@%           .:-=++*##%%%@@@@@@@@@@@@*. :@+.@@@%:            .#@@+       =@@@@#:
//      .@@@*-+*#%%%@@@@@@@@@@@@@@@@%%#**@@%@@@.   *@=*@@#                :#@%=      .#@@@@#-
//      -%@@@@@@@@@@@@@@@*+==-:-@@@=    *@# .#@*-=*@@@@%=                 -%@@@*       =@@@@@%-
//         -+%@@@#.   %@%%=   -@@:+@: -@@*    *@@*-::                   -%@@%=.         .*@@@@@#
//            *@@@*  +@* *@@##@@-  #@*@@+    -@@=          .         :+@@@#:           .-+@@@%+-
//             +@@@%*@@:..=@@@@*   .@@@*   .#@#.       .=+-       .=%@@@*.         :+#@@@@*=:
//              =@@@@%@@@@@@@@@@@@@@@@@@@@@@%-      :+#*.       :*@@@%=.       .=#@@@@%+:
//               .%@@=                 .....    .=#@@+.       .#@@@*:       -*%@@@@%+.
//                 +@@#+===---:::...         .=%@@*-         +@@@+.      -*@@@@@%+.
//                  -@@@@@@@@@@@@@@@@@@@@@@%@@@@=          -@@@+      -#@@@@@#=.
//                    ..:::---===+++***###%%%@@@#-       .#@@+     -*@@@@@#=.
//                                           @@@@@@+.   +@@*.   .+@@@@@%=.
//                                          -@@@@@=   =@@%:   -#@@@@%+.
//                                          +@@@@@. =@@@=  .+@@@@@*:
//                                          #@@@@#:%@@#. :*@@@@#-
//                                          @@@@@%@@@= :#@@@@+.
//                                         :@@@@@@@#.:#@@@%-
//                                         +@@@@@@-.*@@@*:
//                                         #@@@@#.=@@@+.
//                                         @@@@+-%@%=
//                                        :@@@#%@%=
//                                        +@@@@%-
//                                        :#%%=
//

pragma solidity ^0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { IdentityRegistryStorage } from "contracts/registry/implementation/IdentityRegistryStorage.sol";

import { TREXRegistryBaseUnitTest } from "./helpers/TREXRegistryBaseUnitTest.t.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";

contract TREXRegistryIdentityUnitTest is TREXRegistryBaseUnitTest {

    function setUp() public override {
        super.setUp();
        _registerBaseIdentities();
    }

    // ============ registerIdentity() ============

    function test_registerIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.registerIdentity(another, aliceIdentity, 1);
    }

    function test_registerIdentity_Success_EmitsEvent() public {
        IIdentity newIdentity = _deployIdentity(another, "another");
        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IERC3643IdentityRegistry.IdentityRegistered(another, newIdentity);
        registry.registerIdentity(another, newIdentity, 1);

        assertTrue(registry.contains(another));
        assertEq(address(registry.identity(another)), address(newIdentity));
        // The country argument is ignored: the registry stores none.
        assertEq(registry.investorCountry(another), 0);
    }

    // ============ updateIdentity() ============

    function test_updateIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.updateIdentity(bob, charlieIdentity);
    }

    /// @dev Bindings are sticky: `updateIdentity` never moves a wallet to another identity.
    function test_updateIdentity_RevertWhen_WalletIsBound() public {
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, bob, address(bobIdentity))
        );
        registry.updateIdentity(bob, charlieIdentity);

        assertEq(address(registry.identity(bob)), address(bobIdentity));
    }

    // ============ updateCountry() — deprecated ============

    function test_updateCountry_RevertWhen_Deprecated_AsAgent() public {
        vm.prank(agent);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.updateCountry(bob, 999);
    }

    function test_updateCountry_RevertWhen_Deprecated_AsOther() public {
        // Deprecation takes precedence — even non-agents get Deprecated, never the access-managed error.
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.updateCountry(bob, 999);
    }

    // ============ deleteIdentity() ============

    function test_deleteIdentity_RevertWhen_NotAgent() public {
        vm.prank(another);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, another));
        registry.deleteIdentity(bob);
    }

    function test_deleteIdentity_Success() public {
        IIdentity old = registry.identity(bob);

        vm.prank(agent);
        vm.expectEmit(true, true, false, false, address(registry));
        emit EventsLib.IdentityRevoked(bob, old);
        registry.deleteIdentity(bob);

        // The binding is revoked, not deleted: bob keeps his identity and only the local status moves.
        assertFalse(registry.isLocallyRegistered(bob));
        assertTrue(registry.contains(bob));
    }

    // ============ batchRegisterIdentity() ============

    /// @notice A batch needs whatever the single call needs: granting `registerIdentity` to AGENT is
    ///         enough, because `batchRegisterIdentity` authorizes against `registerIdentity.selector`.
    function test_batchRegisterIdentity_Success_WhenSingleSelectorGrantedToAgent() public {
        IIdentity i1 = _deployIdentity(another, "another");

        address[] memory addrs = new address[](1);
        addrs[0] = another;
        IIdentity[] memory ids = new IIdentity[](1);
        ids[0] = i1;
        uint16[] memory countries = new uint16[](1);
        countries[0] = 1;

        vm.prank(agent);
        registry.batchRegisterIdentity(addrs, ids, countries);

        assertTrue(registry.contains(another));
    }

    /// @notice The production wiring from `AccessManagerSetupLib` grants AGENT only the single-item
    ///         selectors; an agent can still batch-register.
    function test_batchRegisterIdentity_Success_WithProductionRoleWiring() public {
        // Re-wire with the real library (this contract is the AccessManager admin).
        AccessManagerSetupLib.setupTREXRegistryRoles(accessManager, address(registry), DOMAIN);

        address second = makeAddr("secondBatchUser");

        IIdentity firstIdentity = _deployIdentity(another, "another");
        IIdentity secondIdentity = _deployIdentity(second, "secondBatchUser");

        address[] memory addrs = new address[](2);
        addrs[0] = another;
        addrs[1] = second;
        IIdentity[] memory ids = new IIdentity[](2);
        ids[0] = firstIdentity;
        ids[1] = secondIdentity;
        uint16[] memory countries = new uint16[](2);
        countries[0] = 250;
        countries[1] = 840;

        vm.prank(agent);
        registry.batchRegisterIdentity(addrs, ids, countries);

        assertEq(address(registry.identity(another)), address(firstIdentity));
        assertEq(address(registry.identity(second)), address(secondIdentity));
        assertTrue(registry.isLocallyRegistered(another));
        assertTrue(registry.isLocallyRegistered(second));
        // The countries argument is ignored: the registry stores none.
        assertEq(registry.investorCountry(another), 0);
        assertEq(registry.investorCountry(second), 0);
    }

    // ============ setIdentityRegistryStorage() — fixed at init ============

    /// @notice Even a storage that shares the suite authority and already binds this registry is refused: the
    ///         storage is fixed for the registry's life, so no local binding can be left behind.
    function test_setIdentityRegistryStorage_RevertWhen_Deprecated_AsOwner() public {
        IdentityRegistryStorage replacement = _deployIdentityRegistryStorage(address(registry));
        address before = address(registry.identityStorage());

        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setIdentityRegistryStorage(address(replacement));

        assertEq(address(registry.identityStorage()), before);
    }

    function test_setIdentityRegistryStorage_RevertWhen_Deprecated_AsOther() public {
        // Deprecation takes precedence — even non-owners get Deprecated, never the access-managed error.
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setIdentityRegistryStorage(address(0));
    }

    /// @dev A storage on the suite AccessManager that binds `initialIR` at init.
    function _deployIdentityRegistryStorage(address initialIR) private returns (IdentityRegistryStorage) {
        return IdentityRegistryStorage(
            address(
                new ERC1967Proxy(
                    address(identityRegistryStorageImpl),
                    abi.encodeCall(
                        IdentityRegistryStorage.init, (address(accessManager), initialIR, address(idFactory))
                    )
                )
            )
        );
    }

    // ============ setClaimTopicsRegistry() / setTrustedIssuersRegistry() — deprecated ============

    function test_setClaimTopicsRegistry_RevertWhen_Deprecated_AsOwner() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setClaimTopicsRegistry(address(0xBEEF));
    }

    function test_setClaimTopicsRegistry_RevertWhen_Deprecated_AsOther() public {
        // Deprecation takes precedence — even non-owners get Deprecated, never the access-managed error.
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setClaimTopicsRegistry(address(0xBEEF));
    }

    function test_setTrustedIssuersRegistry_RevertWhen_Deprecated_AsOwner() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setTrustedIssuersRegistry(address(0xBEEF));
    }

    function test_setTrustedIssuersRegistry_RevertWhen_Deprecated_AsOther() public {
        vm.prank(another);
        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setTrustedIssuersRegistry(address(0xBEEF));
    }

    // ============ identityStorage / topicsRegistry / issuersRegistry ============

    function test_subRegistries_ReturnExpectedAddresses() public view {
        assertEq(address(registry.identityStorage()), address(identityRegistryStorage));
        assertEq(address(registry.topicsRegistry()), address(registry));
        assertEq(address(registry.issuersRegistry()), address(registry));
    }

}

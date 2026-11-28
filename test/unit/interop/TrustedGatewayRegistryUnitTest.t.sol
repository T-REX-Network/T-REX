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

pragma solidity 0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { TrustedGatewayRegistry } from "contracts/interop/TrustedGatewayRegistry.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { AccessManagerHelper } from "test/integration/helpers/AccessManagerHelper.sol";

contract TrustedGatewayRegistryUnitTest is AccessManagerHelper {

    TrustedGatewayRegistry registry;

    address interopManager = makeAddr("InteropManager");
    address bridge = makeAddr("Bridge");

    function setUp() public {
        _deployPlatformManager();
        _deploySuiteManager();

        // Network-level, so it answers to the platform manager; the suite manager exists only to show
        // that a suite role grants nothing here.
        registry = new TrustedGatewayRegistry(address(platformManager));
        AccessManagerSetupLib.setupTrustedGatewayRegistryRoles(
            platformManager, address(registry), RolesLib.platform(RolesLib.PlatformRole.INTEROP_MANAGER)
        );

        _grantInteropManagerRole(interopManager);
    }

    function testConstructorRevertsOnZeroAccessManager() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessManagerNotAContract.selector, address(0)));
        new TrustedGatewayRegistry(address(0));
    }

    function testConstructorRevertsOnAnAccessManagerWithNoCode() public {
        address eoa = makeAddr("NotAManager");
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessManagerNotAContract.selector, eoa));
        new TrustedGatewayRegistry(eoa);
    }

    /* ----- Records ----- */

    function test_isTrusted_isFalse_whenTheBridgeWasNeverSet() public view {
        assertFalse(registry.isTrusted(bridge), "an unknown bridge is not trusted");
    }

    function test_setTrustedGateway_trustsTheBridgeAtItsDepth() public {
        uint64 depth = 3;

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(bridge, true, depth);
        vm.prank(interopManager);
        registry.setTrustedGateway(bridge, true, depth);

        assertTrue(registry.isTrusted(bridge), "the bridge is trusted");
        assertEq(registry.depthOf(bridge), depth, "its reviewed depth is kept");
    }

    function test_setTrustedGateway_trustsTheBridgeAtFullFinality() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(bridge, true, 0);
        vm.prank(interopManager);
        registry.setTrustedGateway(bridge, true, 0);

        assertTrue(registry.isTrusted(bridge), "the bridge is trusted");
        assertEq(registry.depthOf(bridge), 0, "at full finality");
    }

    /// @dev A trusted bridge's depth may be set again: the registry is shared, so the new depth applies to every
    ///  token at once.
    function test_setTrustedGateway_setsTheDepthOfATrustedBridgeAgain() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(bridge, true, 3);

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(bridge, true, 0);
        registry.setTrustedGateway(bridge, true, 0);
        assertEq(registry.depthOf(bridge), 0, "the depth set again is read");

        registry.setTrustedGateway(bridge, true, 5);
        vm.stopPrank();

        assertTrue(registry.isTrusted(bridge), "the bridge stays trusted");
        assertEq(registry.depthOf(bridge), 5, "the latest depth is read");
    }

    function test_setTrustedGateway_distrustCutsTheBridgeInTheSameBlock() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(bridge, true, 0);

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(bridge, false, 0);
        registry.setTrustedGateway(bridge, false, 0);
        vm.stopPrank();

        assertFalse(registry.isTrusted(bridge), "no longer trusted");
    }

    function test_setTrustedGateway_distrustsABridgeThatWasNeverTrusted() public {
        vm.prank(interopManager);
        registry.setTrustedGateway(bridge, false, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        vm.prank(interopManager);
        registry.setTrustedGateway(bridge, true, 3);
    }

    /// @dev Only trusting a distrusted bridge is refused: distrusting it again changes nothing and does not revert.
    function test_setTrustedGateway_distrustsADistrustedBridgeAgain() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(bridge, true, 0);
        registry.setTrustedGateway(bridge, false, 0);

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.TrustedGatewaySet(bridge, false, 0);
        registry.setTrustedGateway(bridge, false, 0);
        vm.stopPrank();

        assertFalse(registry.isTrusted(bridge), "still distrusted");
    }

    /* ----- Refusals ----- */

    function test_setTrustedGateway_RevertWhen_TheBridgeWasDistrustedAtFullFinality() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(bridge, true, 0);
        registry.setTrustedGateway(bridge, false, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        registry.setTrustedGateway(bridge, true, 0);
        vm.stopPrank();
    }

    function test_setTrustedGateway_RevertWhen_TheBridgeWasDistrustedAtADepth() public {
        vm.startPrank(interopManager);
        registry.setTrustedGateway(bridge, true, 3);
        registry.setTrustedGateway(bridge, false, 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        registry.setTrustedGateway(bridge, true, 3);
        vm.stopPrank();
    }

    function test_depthOf_returnsTheRecordedDepth_whenTheBridgeIsNotTrusted() public {
        assertEq(registry.depthOf(bridge), 0, "an unknown bridge reads depth zero");

        vm.startPrank(interopManager);
        registry.setTrustedGateway(bridge, true, 3);
        registry.setTrustedGateway(bridge, false, 7);
        vm.stopPrank();

        assertFalse(registry.isTrusted(bridge), "the bridge is distrusted");
        assertEq(registry.depthOf(bridge), 7, "a distrusted bridge still reads its recorded depth");
    }

    function test_setTrustedGateway_RevertWhen_TheBridgeIsZeroAtADepth() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.setTrustedGateway(address(0), true, 3);
    }

    function test_setTrustedGateway_RevertWhen_TheBridgeIsZeroAtFullFinality() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.setTrustedGateway(address(0), true, 0);
    }

    function test_setTrustedGateway_RevertWhen_TheDistrustedBridgeIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.setTrustedGateway(address(0), false, 0);
    }

    /* ----- Who may ----- */

    function test_fuzz_setTrustedGateway_RevertWhen_TheCallerIsNotTheInteropManagerAtFullFinality(address caller)
        public
    {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.setTrustedGateway(bridge, true, 0);
    }

    function test_fuzz_setTrustedGateway_RevertWhen_TheCallerIsNotTheInteropManagerAtADepth(address caller) public {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.setTrustedGateway(bridge, true, 3);
    }

    function test_fuzz_setTrustedGateway_RevertWhen_TheCallerIsNotTheInteropManagerToDistrust(address caller) public {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.setTrustedGateway(bridge, false, 0);
    }

    /// @dev The registry is network-level: no suite role reaches it, only INTEROP_MANAGER.
    function test_setTrustedGateway_RevertWhen_TheCallerHoldsASuiteRole() public {
        address owner = makeAddr("Owner");
        _grantOwnerRole(owner);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        registry.setTrustedGateway(bridge, true, 0);
    }

    function testInteropManagerRoleIdIsUnique() public pure {
        uint64 interopManager = RolesLib.platform(RolesLib.PlatformRole.INTEROP_MANAGER);
        assertTrue(interopManager != RolesLib.platform(RolesLib.PlatformRole.VERSION_MANAGER));
        assertTrue(interopManager != RolesLib.platform(RolesLib.PlatformRole.ASSET_DEPLOYER));
        assertTrue(interopManager != RolesLib.platform(RolesLib.PlatformRole.OWNER));
        assertTrue(interopManager != _role(RolesLib.Role.IRS_BINDER));
        assertTrue(interopManager != _role(RolesLib.Role.OWNER));
        assertTrue(interopManager != _role(RolesLib.Role.SUITE_ADMIN));
        assertTrue(interopManager != _role(RolesLib.Role.AGENT_ADMIN));
    }

}

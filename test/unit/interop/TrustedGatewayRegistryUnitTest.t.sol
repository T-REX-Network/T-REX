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

import { ITrustedGatewayRegistry } from "contracts/interop/ITrustedGatewayRegistry.sol";
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

    function test_isTrusted_isFalse_whenTheBridgeWasNeverRecorded() public view {
        assertFalse(registry.isTrusted(bridge), "an unknown bridge is not trusted");
        assertFalse(registry.isReceiptBridge(bridge), "nor a receipt bridge");
    }

    function test_trustTicketBridge_recordsTheBridgeAndItsDepth() public {
        uint64 depth = 3;

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.BridgeTrusted(bridge, ITrustedGatewayRegistry.BridgeStanding.TicketBridge, depth);
        vm.prank(interopManager);
        registry.trustTicketBridge(bridge, depth);

        assertTrue(registry.isTrusted(bridge), "a ticket bridge is trusted");
        assertFalse(registry.isReceiptBridge(bridge), "but is not a receipt bridge");
        assertEq(registry.depthOf(bridge), depth, "its reviewed depth is kept");
    }

    function test_trustReceiptBridge_recordsTheBridgeAtFullFinality() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.BridgeTrusted(bridge, ITrustedGatewayRegistry.BridgeStanding.ReceiptBridge, 0);
        vm.prank(interopManager);
        registry.trustReceiptBridge(bridge);

        assertTrue(registry.isTrusted(bridge), "a receipt bridge is trusted");
        assertTrue(registry.isReceiptBridge(bridge), "and is a receipt bridge");
        assertEq(registry.depthOf(bridge), 0, "a receipt bridge waits for full finality");
    }

    function test_distrustBridge_cutsTheBridgeInTheSameBlock() public {
        vm.startPrank(interopManager);
        registry.trustReceiptBridge(bridge);

        vm.expectEmit(true, false, false, true, address(registry));
        emit EventsLib.BridgeDistrusted(bridge);
        registry.distrustBridge(bridge);
        vm.stopPrank();

        assertFalse(registry.isTrusted(bridge), "no longer trusted");
        assertFalse(registry.isReceiptBridge(bridge), "no longer a receipt bridge");
    }

    function test_distrustBridge_recordsABridgeThatWasNeverTrusted() public {
        vm.prank(interopManager);
        registry.distrustBridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        vm.prank(interopManager);
        registry.trustTicketBridge(bridge, 3);
    }

    /* ----- Refusals ----- */

    function test_trustReceiptBridge_RevertWhen_TheBridgeWasDistrusted() public {
        vm.startPrank(interopManager);
        registry.trustReceiptBridge(bridge);
        registry.distrustBridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        registry.trustReceiptBridge(bridge);
        vm.stopPrank();
    }

    function test_trustTicketBridge_RevertWhen_TheBridgeWasDistrusted() public {
        vm.startPrank(interopManager);
        registry.trustTicketBridge(bridge, 3);
        registry.distrustBridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        registry.trustTicketBridge(bridge, 3);
        vm.stopPrank();
    }

    /// @dev One bridge, one record: a ticket bridge never becomes a receipt bridge, so it can never carry receipts
    ///  in for one away chain while it carries tickets ahead of finality for another.
    function test_trustReceiptBridge_RevertWhen_TheBridgeIsATicketBridge() public {
        vm.startPrank(interopManager);
        registry.trustTicketBridge(bridge, 3);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeAlreadyRecorded.selector, bridge));
        registry.trustReceiptBridge(bridge);
        vm.stopPrank();
    }

    function test_trustTicketBridge_RevertWhen_TheBridgeIsAReceiptBridge() public {
        vm.startPrank(interopManager);
        registry.trustReceiptBridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeAlreadyRecorded.selector, bridge));
        registry.trustTicketBridge(bridge, 0);
        vm.stopPrank();
    }

    function test_trustTicketBridge_RevertWhen_TheBridgeIsAlreadyATicketBridge() public {
        vm.startPrank(interopManager);
        registry.trustTicketBridge(bridge, 3);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeAlreadyRecorded.selector, bridge));
        registry.trustTicketBridge(bridge, 5);
        vm.stopPrank();

        assertEq(registry.depthOf(bridge), 3, "the first record stands");
    }

    function test_distrustBridge_RevertWhen_TheBridgeIsAlreadyDistrusted() public {
        vm.startPrank(interopManager);
        registry.distrustBridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeDistrusted.selector, bridge));
        registry.distrustBridge(bridge);
        vm.stopPrank();
    }

    function test_depthOf_RevertWhen_TheBridgeIsNotTrusted() public {
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotTrusted.selector, bridge));
        registry.depthOf(bridge);

        vm.prank(interopManager);
        registry.distrustBridge(bridge);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.BridgeNotTrusted.selector, bridge));
        registry.depthOf(bridge);
    }

    function test_trustTicketBridge_RevertWhen_TheBridgeIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.trustTicketBridge(address(0), 3);
    }

    function test_trustReceiptBridge_RevertWhen_TheBridgeIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.trustReceiptBridge(address(0));
    }

    function test_distrustBridge_RevertWhen_TheBridgeIsZero() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(interopManager);
        registry.distrustBridge(address(0));
    }

    /* ----- Who may ----- */

    function test_fuzz_trustReceiptBridge_RevertWhen_TheCallerIsNotTheInteropManager(address caller) public {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.trustReceiptBridge(bridge);
    }

    function test_fuzz_trustTicketBridge_RevertWhen_TheCallerIsNotTheInteropManager(address caller) public {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.trustTicketBridge(bridge, 3);
    }

    function test_fuzz_distrustBridge_RevertWhen_TheCallerIsNotTheInteropManager(address caller) public {
        vm.assume(caller != interopManager);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        registry.distrustBridge(bridge);
    }

    /// @dev The registry is network-level: no suite role reaches it, only INTEROP_MANAGER.
    function test_trustReceiptBridge_RevertWhen_TheCallerHoldsASuiteRole() public {
        address owner = makeAddr("Owner");
        _grantOwnerRole(owner);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        registry.trustReceiptBridge(bridge);
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

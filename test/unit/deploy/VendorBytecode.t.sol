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

import { Test } from "@forge-std/Test.sol";

import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { CreateXAddressLib } from "scripts/deploy/lib/CreateXAddressLib.sol";

/// @notice The vendored third-party bytecode is what it claims to be, with no network: each init code, run at its
///         canonical address, yields exactly the runtime code recorded for that address (immutables like CreateX's
///         and SafeToL2Setup's `_SELF` included), and the Safe contracts land at their canonical addresses through
///         the Safe Singleton Factory.
contract VendorBytecodeTest is Test {

    string internal vendor;

    function setUp() public {
        vendor = vm.readFile("deploy/vendor/vendor.json");
    }

    /// @dev Runs `init` as a constructor at `at` and returns the runtime it produces.
    function _runtimeAt(address at, bytes memory init) internal returns (bytes memory runtime) {
        vm.etch(at, init);
        bool ok;
        (ok, runtime) = at.call("");
        assertTrue(ok, "constructor reverted");
    }

    function test_anchorAndSafeSingletonFactoryRuntime() public view {
        bytes memory runtime = BytecodeStore.create2FactoryRuntime();
        assertEq(keccak256(runtime), BytecodeStore.ANCHOR_CODEHASH);
        assertEq(vm.parseJsonBytes32(vendor, ".anchor.runtimeCodeHash"), BytecodeStore.ANCHOR_CODEHASH);
        assertEq(vm.parseJsonAddress(vendor, ".anchor.address"), BytecodeStore.ANCHOR);
        assertEq(vm.parseJsonAddress(vendor, ".safeSingletonFactory.address"), BytecodeStore.SAFE_SINGLETON_FACTORY);
    }

    function test_createxInitCodeGivesTheCanonicalRuntime() public {
        bytes memory init = BytecodeStore.createxInitCode();
        assertEq(keccak256(init), vm.parseJsonBytes32(vendor, ".createx.initCodeHash"));
        address canonical = vm.parseJsonAddress(vendor, ".createx.canonicalAddress");
        bytes memory runtime = _runtimeAt(canonical, init);
        assertEq(keccak256(runtime), vm.parseJsonBytes32(vendor, ".createx.canonicalRuntimeCodeHash"));
    }

    function test_safeContractsLandAtTheirCanonicalAddresses() public {
        BytecodeStore.VendorContract[] memory list = BytecodeStore.safeContracts();
        for (uint256 i = 0; i < list.length; i++) {
            bytes memory init = BytecodeStore.safeInitCode(list[i].name);
            assertEq(
                CreateXAddressLib.create2(BytecodeStore.SAFE_SINGLETON_FACTORY, bytes32(0), keccak256(init)),
                list[i].canonical,
                list[i].name
            );
            string memory key = string.concat(".safe.contracts.", list[i].name);
            assertEq(vm.parseJsonAddress(vendor, string.concat(key, ".address")), list[i].canonical, list[i].name);
            assertEq(keccak256(init), vm.parseJsonBytes32(vendor, string.concat(key, ".initCodeHash")), list[i].name);
            bytes memory runtime = _runtimeAt(list[i].canonical, init);
            assertEq(keccak256(runtime), BytecodeStore.safeRuntimeCodeHash(list[i].name), list[i].name);
        }
    }

    function test_safeSingletonFactoryDeploysSafeForReal() public {
        vm.etch(BytecodeStore.SAFE_SINGLETON_FACTORY, BytecodeStore.create2FactoryRuntime());
        (bool ok,) = BytecodeStore.SAFE_SINGLETON_FACTORY
            .call(abi.encodePacked(bytes32(0), BytecodeStore.safeInitCode("SafeProxyFactory")));
        assertTrue(ok);
        assertEq(BytecodeStore.SAFE_PROXY_FACTORY.codehash, BytecodeStore.safeRuntimeCodeHash("SafeProxyFactory"));
    }

}

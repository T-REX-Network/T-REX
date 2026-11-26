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
import { ISafe, ISafeProxyFactory, SafeLib } from "scripts/deploy/lib/SafeLib.sol";

contract Counter {

    uint256 public count;

    function bump() external {
        count++;
    }

}

/// @notice Safe v1.4.1 address prediction, setup and pre-approved-hash execution against the vendored contracts.
contract SafeLibTest is Test {

    address[] internal owners;

    function setUp() public {
        vm.etch(BytecodeStore.SAFE_SINGLETON_FACTORY, BytecodeStore.create2FactoryRuntime());
        BytecodeStore.VendorContract[] memory list = BytecodeStore.safeContracts();
        for (uint256 i = 0; i < list.length; i++) {
            (bool ok,) = BytecodeStore.SAFE_SINGLETON_FACTORY
                .call(abi.encodePacked(bytes32(0), BytecodeStore.safeInitCode(list[i].name)));
            assertTrue(ok, list[i].name);
        }
        owners.push(makeAddr("owner c"));
        owners.push(makeAddr("owner a"));
        owners.push(makeAddr("owner b"));
    }

    function _create(uint256 threshold, uint256 saltNonce) internal returns (address safe, bytes memory setup) {
        setup = SafeLib.initializer(
            owners,
            threshold,
            BytecodeStore.SAFE_TO_L2_SETUP,
            BytecodeStore.SAFE_L2,
            BytecodeStore.COMPATIBILITY_FALLBACK_HANDLER
        );
        safe = ISafeProxyFactory(BytecodeStore.SAFE_PROXY_FACTORY)
            .createProxyWithNonce(BytecodeStore.SAFE, setup, saltNonce);
    }

    function test_predictedAddress() public {
        bytes memory setup = SafeLib.initializer(
            owners,
            2,
            BytecodeStore.SAFE_TO_L2_SETUP,
            BytecodeStore.SAFE_L2,
            BytecodeStore.COMPATIBILITY_FALLBACK_HANDLER
        );
        address predicted = SafeLib.proxyAddress(
            BytecodeStore.SAFE_PROXY_FACTORY, BytecodeStore.SAFE, setup, 7, BytecodeStore.safeProxyCreationCode()
        );
        (address safe,) = _create(2, 7);
        assertEq(safe, predicted);
        assertEq(ISafe(safe).getThreshold(), 2);
        assertEq(ISafe(safe).getOwners().length, 3);
    }

    function test_ownerOrderChangesTheAddress() public {
        bytes memory a = SafeLib.initializer(
            owners,
            2,
            BytecodeStore.SAFE_TO_L2_SETUP,
            BytecodeStore.SAFE_L2,
            BytecodeStore.COMPATIBILITY_FALLBACK_HANDLER
        );
        (owners[0], owners[1]) = (owners[1], owners[0]);
        bytes memory b = SafeLib.initializer(
            owners,
            2,
            BytecodeStore.SAFE_TO_L2_SETUP,
            BytecodeStore.SAFE_L2,
            BytecodeStore.COMPATIBILITY_FALLBACK_HANDLER
        );
        bytes memory code = BytecodeStore.safeProxyCreationCode();
        assertTrue(
            SafeLib.proxyAddress(BytecodeStore.SAFE_PROXY_FACTORY, BytecodeStore.SAFE, a, 0, code)
                != SafeLib.proxyAddress(BytecodeStore.SAFE_PROXY_FACTORY, BytecodeStore.SAFE, b, 0, code)
        );
    }

    function test_executesWithApprovedHashes() public {
        (address safe,) = _create(2, 0);
        Counter counter = new Counter();
        bytes memory data = abi.encodeCall(Counter.bump, ());
        bytes32 h = ISafe(safe).getTransactionHash(address(counter), 0, data, 0, 0, 0, 0, address(0), address(0), 0);
        address[] memory signers = new address[](2);
        signers[0] = owners[0];
        signers[1] = owners[2];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(signers[i]);
            ISafe(safe).approveHash(h);
        }
        ISafe(safe)
            .execTransaction(
                address(counter),
                0,
                data,
                0,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                SafeLib.approvedHashSignatures(signers)
            );
        assertEq(counter.count(), 1);
    }

    function test_signaturesAreSortedByOwner() public pure {
        address[] memory unsorted = new address[](3);
        unsorted[0] = address(3);
        unsorted[1] = address(1);
        unsorted[2] = address(2);
        bytes memory sigs = SafeLib.approvedHashSignatures(unsorted);
        assertEq(sigs.length, 65 * 3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 owner;
            assembly ("memory-safe") {
                owner := mload(add(add(sigs, 32), mul(i, 65)))
            }
            assertEq(uint256(owner), i + 1);
            assertEq(uint8(sigs[i * 65 + 64]), 1, "approved-hash signature type");
        }
    }

}

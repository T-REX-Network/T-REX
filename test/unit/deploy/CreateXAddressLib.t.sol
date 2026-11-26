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

import { ICreateX } from "scripts/deploy/PlanBuilder.sol";
import { BytecodeStore } from "scripts/deploy/lib/BytecodeStore.sol";
import { CreateXAddressLib } from "scripts/deploy/lib/CreateXAddressLib.sol";

interface ICreateXCompute {

    function computeCreate3Address(bytes32 salt) external view returns (address);

}

/// @notice The address math against the real CreateX bytecode, deployed through the anchor from the vendored init
///         code, on a local chain.
contract CreateXAddressLibTest is Test {

    address internal createx;
    bytes32 internal constant GENESIS_SALT = keccak256("test genesis");

    function setUp() public {
        vm.etch(BytecodeStore.ANCHOR, BytecodeStore.create2FactoryRuntime());
        bytes memory init = BytecodeStore.createxInitCode();
        (bool ok, bytes memory ret) = BytecodeStore.ANCHOR.call(abi.encodePacked(GENESIS_SALT, init));
        assertTrue(ok, "anchor deploy");
        createx = address(bytes20(ret));
    }

    function test_genesisAddressThroughTheAnchor() public view {
        assertEq(
            createx,
            CreateXAddressLib.create2(BytecodeStore.ANCHOR, GENESIS_SALT, keccak256(BytecodeStore.createxInitCode()))
        );
        assertGt(createx.code.length, 0);
    }

    function test_permissionlessCreate2() public {
        bytes32 salt = bytes32(abi.encodePacked(bytes20(keccak256("random prefix")), bytes12(0)));
        bytes memory init = hex"600a600c600039600a6000f3602a60005260206000f3"; // returns 42
        address expected = CreateXAddressLib.create2ViaCreateX(createx, salt, keccak256(init));
        vm.prank(makeAddr("anyone"));
        address deployed = ICreateX(createx).deployCreate2(salt, init);
        assertEq(deployed, expected);
        // Anyone else gets the same address: the salt is not bound to a sender.
        vm.prank(makeAddr("someone else"));
        vm.expectRevert();
        ICreateX(createx).deployCreate2(salt, init);
    }

    function test_create3BoundToTheSender() public {
        address safe = makeAddr("deployment safe");
        bytes32 salt = CreateXAddressLib.permissionedSalt(safe, keccak256("label"));
        assertEq(address(bytes20(salt)), safe);
        assertEq(uint8(salt[20]), 0, "redeploy protection off: no chain id in the guard");
        address expected = CreateXAddressLib.create3ViaCreateX(createx, safe, salt);
        // CreateX's own view agrees, given the guarded salt (its one-argument form takes the salt as guarded).
        assertEq(
            ICreateXCompute(createx).computeCreate3Address(CreateXAddressLib.guardPermissioned(safe, salt)), expected
        );
        vm.prank(safe);
        address deployed = ICreateX(createx).deployCreate3(salt, hex"600a600c600039600a6000f3602a60005260206000f3");
        assertEq(deployed, expected);
    }

    /// @dev Another sender may submit the Safe's salt, but CreateX guards it differently for them (the prefix is
    ///      not their address), so their contract lands elsewhere and the Safe's address stays free.
    function test_create3SaltOfTheSafeIsUnreachableForOthers() public {
        address safe = makeAddr("deployment safe");
        bytes32 salt = CreateXAddressLib.permissionedSalt(safe, keccak256("label"));
        address expected = CreateXAddressLib.create3ViaCreateX(createx, safe, salt);
        vm.prank(makeAddr("attacker"));
        address squatted = ICreateX(createx).deployCreate3(salt, hex"600a600c600039600a6000f3602a60005260206000f3");
        assertTrue(squatted != expected, "attacker reached the Safe's address");
        assertEq(expected.code.length, 0);
    }

    function test_createAtMatchesForge() public pure {
        address deployer = address(0xBEEF);
        for (uint8 n = 1; n < 6; n++) {
            assertEq(CreateXAddressLib.createAt(deployer, n), vm.computeCreateAddress(deployer, n));
        }
    }

    function test_randomSaltNeedsAPrefix() public {
        vm.expectRevert(abi.encodeWithSelector(CreateXAddressLib.SaltPrefixNotRandom.selector, bytes32(uint256(1))));
        this.guardRandom(bytes32(uint256(1)));
    }

    function guardRandom(bytes32 salt) external pure returns (bytes32) {
        return CreateXAddressLib.guardRandom(salt);
    }

}

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

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";
import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";

contract TokenSetOnchainIDUnitTest is TokenBaseUnitTest {

    address newOnchainId = makeAddr("NewOnchainId");

    function setUp() public override {
        super.setUp();

        accessManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.IDENTITY_MANAGER), address(this), 0);
    }

    function testTokenSetOnchainIDRevertsWhenUnauthorized(address caller) public {
        vm.assume(caller != address(this));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.setOnchainID(newOnchainId);
    }

    function testTokenSetOnchainIDNominal() public {
        mockIdentityBoundToToken(address(token), newOnchainId);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC3643.UpdatedTokenInformation(
            token.name(), token.symbol(), token.decimals(), token.version(), newOnchainId
        );
        token.setOnchainID(newOnchainId);

        assertEq(token.onchainID(), newOnchainId);
    }

    function testTokenSetOnchainIDRevertsWhenTheIdentityIsNotTheOneBoundToTheToken() public {
        address boundIdentity = makeAddr("BoundIdentity");
        mockIdentityBoundToToken(address(token), boundIdentity);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenIdentityNotBound.selector, address(token), newOnchainId));
        token.setOnchainID(newOnchainId);
    }

    function testTokenSetOnchainIDRevertsWhenNoIdentityIsBoundToTheToken() public {
        mockIdentityBoundToToken(address(token), address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenIdentityNotBound.selector, address(token), newOnchainId));
        token.setOnchainID(newOnchainId);
    }

    function testTokenSetOnchainIDToZeroAddressWhenNoIdentityIsBoundToTheToken() public {
        address zeroAddress = address(0);
        mockIdentityBoundToToken(address(token), zeroAddress);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC3643.UpdatedTokenInformation(
            token.name(), token.symbol(), token.decimals(), token.version(), zeroAddress
        );
        token.setOnchainID(zeroAddress);

        assertEq(token.onchainID(), zeroAddress);
    }

    function testTokenSetOnchainIDToZeroAddressRevertsWhileAnIdentityIsBoundToTheToken() public {
        address zeroAddress = address(0);
        mockIdentityBoundToToken(address(token), newOnchainId);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenIdentityNotBound.selector, address(token), zeroAddress));
        token.setOnchainID(zeroAddress);
    }

}

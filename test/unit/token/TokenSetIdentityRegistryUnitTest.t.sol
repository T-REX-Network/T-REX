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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { IERC3643Compliance } from "contracts/ERC-3643/IERC3643Compliance.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ITREXRegistry } from "contracts/registry/interface/ITREXRegistry.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";
import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";

contract TokenSetIdentityRegistryUnitTest is TokenBaseUnitTest {

    address newIdentityRegistry = makeAddr("NewIdentityRegistry");
    address otherIdentityFactory = makeAddr("OtherIdentityFactoryMock");

    function setUp() public override {
        super.setUp();

        suiteManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.IDENTITY_MANAGER), address(this), 0);
    }

    function testTokenSetIdentityRegistryRevertsWhenUnauthorized(address caller) public {
        vm.assume(caller != address(this));

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        token.setIdentityRegistry(newIdentityRegistry);
    }

    function testTokenSetIdentityRegistryRevertsWhenZeroAddress() public {
        // The onlySharedAuthority guard rejects the zero address before the in-body ZeroAddress check,
        // since address(0) cannot share the Token's authority.
        vm.expectRevert(ErrorsLib.AuthorityMismatch.selector);
        token.setIdentityRegistry(address(0));
    }

    /// @notice A target with no ERC-165 support is refused, so a mistyped address cannot halt the token.
    function testTokenSetIdentityRegistryRevertsWhenNoERC165() public {
        address notAContract = makeAddr("NotAContract");
        vm.mockCall(notAContract, abi.encodeCall(IAccessManaged.authority, ()), abi.encode(address(suiteManager)));

        vm.expectRevert(ErrorsLib.InvalidIdentityRegistry.selector);
        token.setIdentityRegistry(notAContract);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    /// @notice A contract that is not an identity registry is refused.
    function testTokenSetIdentityRegistryRevertsWhenWrongInterface() public {
        vm.mockCall(
            newIdentityRegistry, abi.encodeCall(IAccessManaged.authority, ()), abi.encode(address(suiteManager))
        );
        mockSupportsInterface(newIdentityRegistry, type(IERC3643Compliance).interfaceId);

        vm.expectRevert(ErrorsLib.InvalidIdentityRegistry.selector);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    /// @notice A registry with only the standard interface is refused: the spender check on every
    ///  `transferFrom`, recovery and delegation call T-REX methods it does not have.
    function testTokenSetIdentityRegistryRevertsWhenOnlyStandardInterface() public {
        vm.mockCall(
            newIdentityRegistry, abi.encodeCall(IAccessManaged.authority, ()), abi.encode(address(suiteManager))
        );
        mockSupportsInterface(newIdentityRegistry, type(IERC3643IdentityRegistry).interfaceId);

        vm.expectRevert(ErrorsLib.InvalidIdentityRegistry.selector);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    function testTokenSetIdentityRegistryNominal() public {
        _mockNewRegistryOn(identityFactory);
        _setupRegistryRoles(newIdentityRegistry);
        suiteManager.grantRole(RolesLib.forDomain(1, RolesLib.Role.AGENT), address(token), 0);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC3643.IdentityRegistryAdded(newIdentityRegistry);
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), newIdentityRegistry);
    }

    /// @notice A registry built on another IdentityFactory is accepted when that factory binds the token to the
    ///  ONCHAINID the token holds: the rule is the binding, not which factory answers.
    function testTokenSetIdentityRegistryNominalWhenAnotherFactoryBindsTheSameIdentity() public {
        _mockNewRegistryOn(otherIdentityFactory);
        _mockOtherFactoryBindsTheTokenTo(onchainId);

        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), newIdentityRegistry);
        assertEq(token.onchainID(), onchainId, "the ONCHAINID is untouched");
    }

    /// @notice The ONCHAINID was checked against the factory of the registry the token had. A registry whose
    ///  factory binds the token to another identity is refused, so the token cannot end up pointing at an
    ///  identity its registry does not bind to it.
    function testTokenSetIdentityRegistryRevertsWhenItsFactoryBindsTheTokenToAnotherIdentity() public {
        _mockNewRegistryOn(otherIdentityFactory);
        _mockOtherFactoryBindsTheTokenTo(makeAddr("AnotherIdentity"));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenIdentityNotBound.selector, address(token), onchainId));
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    /// @notice A registry whose factory binds no identity to the token is refused too, while the token holds one.
    function testTokenSetIdentityRegistryRevertsWhenItsFactoryBindsNoIdentityToTheToken() public {
        _mockNewRegistryOn(otherIdentityFactory);
        _mockOtherFactoryBindsTheTokenTo(address(0));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.TokenIdentityNotBound.selector, address(token), onchainId));
        token.setIdentityRegistry(newIdentityRegistry);

        assertEq(address(token.identityRegistry()), identityRegistry, "rejected registry must not be recorded");
    }

    /// @dev A valid new registry, sharing the token's authority, built on `factory`.
    function _mockNewRegistryOn(address factory) private {
        vm.mockCall(
            newIdentityRegistry, abi.encodeCall(IAccessManaged.authority, ()), abi.encode(address(suiteManager))
        );
        mockSupportsInterface(newIdentityRegistry, type(IERC3643IdentityRegistry).interfaceId);
        mockSupportsInterface(newIdentityRegistry, type(ITREXRegistry).interfaceId);
        vm.mockCall(
            newIdentityRegistry, abi.encodeWithSelector(ITREXRegistry.identityFactory.selector), abi.encode(factory)
        );
    }

    function _mockOtherFactoryBindsTheTokenTo(address boundIdentity) private {
        bytes memory tokenAccount = InteroperableAddress.formatEvmV1(block.chainid, address(token));
        vm.mockCall(
            otherIdentityFactory,
            abi.encodeWithSelector(IIdentityFactory.getIdentity.selector, tokenAccount),
            abi.encode(boundIdentity)
        );
    }

}

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
/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
pragma solidity ^0.8.30;

import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643IdentityRegistryStorage } from "contracts/ERC-3643/IERC3643IdentityRegistryStorage.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "../helpers/TREXSuiteTest.sol";

/// @title TREXRegistryFactoryDeployTest
/// @notice End-to-end smoke test for the `TREXFactory.deployTREXSuite` path: the factory must
///         deploy a single `TREXRegistry` (acting as IR + TIR + CTR) and a separate
///         `IdentityRegistryStorage`, and the Token must work end-to-end with a verified-identity
///         transfer.
contract TREXRegistryFactoryDeployTest is TREXSuiteTest {

    Token internal suiteToken;
    TREXRegistry internal registry;

    function setUp() public override {
        super.setUp();
        suiteToken = _deployTokenWithClaimTopic("factory-deploy", "Suite Token", "STK");
        registry = TREXRegistry(address(suiteToken.identityRegistry()));

        // Register the identities on this token's registry (the helper only registers on the
        // base token from `super.setUp()`).
        _registerIdentities(suiteToken);

        // Issue alice and bob the required claim so they're verified investors.
        bytes memory claimData = "Some claim public data.";
        _addClaim(aliceIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), alice);
        _addClaim(bobIdentity, CLAIM_TOPIC_1, claimData, claimIssuerSigner.key, address(claimIssuer), bob);
    }

    /// @notice Factory wires the Token to the registry — `identityRegistry()` returns it.
    function test_factoryDeploy_TokenIdentityRegistryIsTREXRegistry() public view {
        IERC3643IdentityRegistry tokenIR = suiteToken.identityRegistry();
        assertEq(address(tokenIR), address(registry), "token.identityRegistry should be the TREXRegistry");
    }

    /// @notice The registry reports itself for both sibling registries.
    function test_factoryDeploy_TopicsAndIssuersRegistriesReturnSelf() public view {
        assertEq(
            address(registry.topicsRegistry()), address(registry), "topicsRegistry should return the registry itself"
        );
        assertEq(
            address(registry.issuersRegistry()), address(registry), "issuersRegistry should return the registry itself"
        );
    }

    /// @notice Identity storage stays a separate contract — the factory deployed an IRS proxy.
    function test_factoryDeploy_IdentityStorageIsSeparateContract() public view {
        IERC3643IdentityRegistryStorage irs = registry.identityStorage();
        assertTrue(address(irs) != address(0), "irs must be deployed");
        assertTrue(address(irs) != address(registry), "irs must be a distinct contract from the registry");
    }

    /// @notice The trusted issuer and the claim topic configured through `ClaimDetails` made it onto the registry.
    function test_factoryDeploy_ClaimTopicsAndIssuersWired() public view {
        uint256[] memory topics = registry.getClaimTopics();
        assertEq(topics.length, 1, "expected the single seeded claim topic");
        assertEq(topics[0], CLAIM_TOPIC_1, "wrong topic seeded");

        assertTrue(
            registry.isTrustedIssuer(address(claimIssuer)), "claim issuer must be trusted on the registry"
        );
        assertTrue(
            registry.hasClaimTopic(address(claimIssuer), CLAIM_TOPIC_1),
            "claim issuer must be authorised for the seeded topic"
        );
    }

    /// @notice Happy-path Token transfer between two verified-identity holders, proving the eligibility and
    ///         compliance layers work end-to-end on top of the registry.
    function test_factoryDeploy_HappyPathTransferBetweenVerifiedHolders() public {
        // Sanity: both holders are verified by the registry.
        assertTrue(registry.isVerified(alice), "alice should be verified");
        assertTrue(registry.isVerified(bob), "bob should be verified");

        // Mint to alice via the token agent (granted AGENT_MINTER role via the suite setup).
        // Token starts paused; unpause for the transfer.
        uint256 amount = 100;
        vm.startPrank(agent);
        suiteToken.mint(alice, amount);
        suiteToken.unpause();
        vm.stopPrank();
        assertEq(suiteToken.balanceOf(alice), amount, "alice should have received the mint");

        // Transfer through the standard ERC-20 surface, which exercises the ERC-3643 verification path.
        vm.prank(alice);
        bool ok = suiteToken.transfer(bob, amount);
        assertTrue(ok, "transfer should succeed for two verified holders");
        assertEq(suiteToken.balanceOf(alice), 0, "alice should be drained");
        assertEq(suiteToken.balanceOf(bob), amount, "bob should receive the full amount");
    }

}

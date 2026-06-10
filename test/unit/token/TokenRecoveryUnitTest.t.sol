// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { TokenRoles } from "contracts/token/TokenStructs.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

contract TokenRecoveryUnitTest is TokenBaseUnitTest {

    address lostWallet = makeAddr("LostWallet");
    address newWallet = makeAddr("NewWallet");
    address investorOnchainId = makeAddr("InvestorOnchainId");
    uint256 mintAmount = 1000;
    uint256 frozenAmount = 300;

    function setUp() public override {
        super.setUp();

        vm.startPrank(agent);
        token.unpause();
        token.mint(lostWallet, mintAmount);
        vm.stopPrank();
    }

    function testTokenRecoveryAddressRevertsWhenNotAgent(address caller) public {
        vm.assume(caller != agent);

        vm.expectRevert(ErrorsLib.CallerDoesNotHaveAgentRole.selector);
        vm.prank(caller);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
    }

    function testTokenRecoveryAddressRevertsWhenNoTokenToRecover() public {
        address emptyWallet = makeAddr("EmptyWallet");

        vm.expectRevert(ErrorsLib.NoTokenToRecover.selector);
        vm.prank(agent);
        token.recoveryAddress(emptyWallet, newWallet, investorOnchainId);
    }

    function testTokenRecoveryAddressRevertsWhenRecoveryNotPossible() public {
        address unregisteredWallet = makeAddr("UnregisteredWallet");

        mockIdentityRegistryContains(lostWallet, false);
        mockIdentityRegistryContains(unregisteredWallet, false);

        vm.expectRevert(ErrorsLib.RecoveryNotPossible.selector);
        vm.prank(agent);
        token.recoveryAddress(lostWallet, unregisteredWallet, investorOnchainId);
    }

    function testTokenRecoveryAddressNominal() public {
        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, false);
        mockIdentityRegistryInvestorCountry(lostWallet, 1);
        mockIdentityRegistryRegisterIdentity(newWallet, IIdentity(investorOnchainId), 1);

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.RecoverySuccess(lostWallet, newWallet, investorOnchainId);
        vm.prank(agent);
        bool success = token.recoveryAddress(lostWallet, newWallet, investorOnchainId);

        assertTrue(success);
        assertEq(token.balanceOf(lostWallet), 0);
        assertEq(token.balanceOf(newWallet), mintAmount);
    }

    function testTokenRecoveryAddressTransfersFrozenTokens() public {
        // Freeze some tokens
        vm.prank(agent);
        token.freezePartialTokens(lostWallet, frozenAmount);

        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, false);
        mockIdentityRegistryInvestorCountry(lostWallet, 1);
        mockIdentityRegistryRegisterIdentity(newWallet, IIdentity(investorOnchainId), 1);

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.TokensUnfrozen(lostWallet, frozenAmount);
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.TokensFrozen(newWallet, frozenAmount);
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);

        assertEq(token.getFrozenTokens(lostWallet), 0);
        assertEq(token.getFrozenTokens(newWallet), frozenAmount);
    }

    function testTokenRecoveryAddressTransfersAddressFreeze() public {
        // Freeze the address
        vm.prank(agent);
        token.setAddressFrozen(lostWallet, true);

        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, false);
        mockIdentityRegistryInvestorCountry(lostWallet, 1);
        mockIdentityRegistryRegisterIdentity(newWallet, IIdentity(investorOnchainId), 1);

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.AddressFrozen(lostWallet, false, address(token));
        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.AddressFrozen(newWallet, true, address(token));
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);

        assertFalse(token.isFrozen(lostWallet));
        assertTrue(token.isFrozen(newWallet));
    }

    function testTokenRecoveryAddressWhenNewWalletAlreadyRegistered() public {
        // Mock identity registry contains - both wallets are registered
        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, true);
        // New wallet's identity must match investorOnchainId, otherwise recovery is rejected
        mockIdentityRegistryIdentity(newWallet, IIdentity(investorOnchainId));

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.RecoverySuccess(lostWallet, newWallet, investorOnchainId);
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);

        assertEq(token.balanceOf(lostWallet), 0);
        assertEq(token.balanceOf(newWallet), mintAmount);
    }

    function testTokenRecoveryAddressRevertsWhenDisableRecoveryRestrictionIsSet() public {
        // Set restriction to disable recovery
        TokenRoles memory restrictions = TokenRoles({
            disableMint: false,
            disableBurn: false,
            disablePartialFreeze: false,
            disableAddressFreeze: false,
            disableRecovery: true,
            disableForceTransfer: false,
            disablePause: false
        });

        token.setAgentRestrictions(agent, restrictions);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AgentNotAuthorized.selector, agent, "recovery disabled"));
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
    }

    /// ----- Helpers ------

    function mockIdentityRegistryContains(address wallet, bool contains) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.contains.selector, wallet),
            abi.encode(contains)
        );
    }

    function mockIdentityRegistryIdentity(address wallet, IIdentity identity) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.identity.selector, wallet),
            abi.encode(identity)
        );
    }

    function mockIdentityRegistryInvestorCountry(address wallet, uint16 country) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.investorCountry.selector, wallet),
            abi.encode(country)
        );
    }

    function mockIdentityRegistryRegisterIdentity(address wallet, IIdentity identity, uint16 country) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.registerIdentity.selector, wallet, identity, country),
            ""
        );
    }

}


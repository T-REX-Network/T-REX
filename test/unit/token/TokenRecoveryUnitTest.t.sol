// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { Vm } from "@forge-std/Vm.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import { ERC3643EventsLib } from "contracts/ERC-3643/ERC3643EventsLib.sol";
import { IERC3643IdentityRegistry } from "contracts/ERC-3643/IERC3643IdentityRegistry.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";

import { TokenBaseUnitTest } from "../helpers/TokenBaseUnitTest.t.sol";

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

        vm.expectPartialRevert(IAccessManaged.AccessManagedUnauthorized.selector);
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

        vm.expectEmit(true, true, true, true, address(token));
        emit ERC3643EventsLib.RecoverySuccess(lostWallet, newWallet, investorOnchainId);
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);

        assertEq(token.balanceOf(lostWallet), 0);
        assertEq(token.balanceOf(newWallet), mintAmount);
    }

    function testTokenRecoveryAddressRevertsWhenDisableRecoveryRestrictionIsSet() public {
        vm.prank(accessManagerAdmin);
        accessManager.revokeRole(RolesLib.AGENT_RECOVERY_ADDRESS, agent);

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, agent));
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
    }

    /// @dev Recovering a wallet with **no** partially-frozen tokens must NOT run the `if (frozenTokens > 0)`
    ///      branch (Token.sol:399): no `TokensFrozen` event for the new wallet and its frozen amount stays 0.
    ///      Kills the `frozenTokens > 0 => true` mutant, which would emit a spurious `TokensFrozen(new, 0)`.
    function testTokenRecoveryDoesNotFreezeNewWalletWhenNothingFrozen() public {
        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, false);
        mockIdentityRegistryInvestorCountry(lostWallet, 1);
        mockIdentityRegistryRegisterIdentity(newWallet, IIdentity(investorOnchainId), 1);

        vm.recordLogs();
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countLogs(logs, ERC3643EventsLib.TokensFrozen.selector, newWallet), 0, "spurious TokensFrozen(newWallet)"
        );
        assertEq(token.getFrozenTokens(newWallet), 0);
    }

    /// @dev Recovering a wallet that is **not** address-frozen must NOT run the `if (lostWallet.addressFrozen)`
    ///      block (Token.sol:404): the new wallet must not become frozen and no `AddressFrozen` events fire.
    ///      Kills the `addressFrozen => true` mutant.
    function testTokenRecoveryDoesNotToggleAddressFreezeWhenLostWalletNotFrozen() public {
        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, false);
        mockIdentityRegistryInvestorCountry(lostWallet, 1);
        mockIdentityRegistryRegisterIdentity(newWallet, IIdentity(investorOnchainId), 1);

        vm.recordLogs();
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(token.isFrozen(newWallet), "newWallet wrongly frozen");
        assertEq(_countLogs(logs, ERC3643EventsLib.AddressFrozen.selector, lostWallet), 0);
        assertEq(_countLogs(logs, ERC3643EventsLib.AddressFrozen.selector, newWallet), 0);
    }

    /// @dev When the new wallet is **already** address-frozen, recovery of a frozen lost wallet must NOT
    ///      re-emit `AddressFrozen(newWallet, true)` — the inner `if (!newWallet.addressFrozen)` guard
    ///      (Token.sol:408) is false. Kills the `!addressFrozen => true` mutant.
    function testTokenRecoveryDoesNotRefreezeAlreadyFrozenNewWallet() public {
        vm.startPrank(agent);
        token.setAddressFrozen(lostWallet, true);
        token.setAddressFrozen(newWallet, true);
        vm.stopPrank();

        mockIdentityRegistryContains(lostWallet, true);
        mockIdentityRegistryContains(newWallet, false);
        mockIdentityRegistryInvestorCountry(lostWallet, 1);
        mockIdentityRegistryRegisterIdentity(newWallet, IIdentity(investorOnchainId), 1);

        vm.recordLogs();
        vm.prank(agent);
        token.recoveryAddress(lostWallet, newWallet, investorOnchainId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // lostWallet is thawed (original behaviour) and newWallet stays frozen, but with no *new* freeze event.
        assertFalse(token.isFrozen(lostWallet));
        assertTrue(token.isFrozen(newWallet));
        assertEq(
            _countLogs(logs, ERC3643EventsLib.AddressFrozen.selector, newWallet), 0, "spurious re-freeze(newWallet)"
        );
    }

    /// ----- Helpers ------

    /// @dev Counts recorded logs matching `sig` (topic0) whose first indexed arg (topic1) is `indexedAddr`.
    function _countLogs(Vm.Log[] memory logs, bytes32 sig, address indexedAddr) internal pure returns (uint256 n) {
        bytes32 wanted = bytes32(uint256(uint160(indexedAddr)));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == sig && logs[i].topics[1] == wanted) {
                n++;
            }
        }
    }

    function mockIdentityRegistryContains(address wallet, bool contains) internal {
        vm.mockCall(
            identityRegistry,
            abi.encodeWithSelector(IERC3643IdentityRegistry.contains.selector, wallet),
            abi.encode(contains)
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


// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { Test } from "@forge-std/Test.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IERC3643 } from "contracts/ERC-3643/IERC3643.sol";

import { ComplianceMock, TokenMock } from "./mocks/Mocks.sol";

/// @dev A registry that verifies whoever it is told to verify, so the token standard tests can state
///  "an unverified recipient is rejected" without dragging ONCHAINID claims into the picture.
contract StubIdentityRegistry {

    mapping(address user => bool) public verified;
    mapping(address user => bool) public known;
    mapping(address user => uint16) public country;
    mapping(address user => IIdentity) public identityOf;

    function setVerified(address user, bool value) external {
        verified[user] = value;
    }

    function setKnown(address user, bool value) external {
        known[user] = value;
    }

    function isVerified(address user) external view returns (bool) {
        return verified[user];
    }

    function contains(address user) external view returns (bool) {
        return known[user];
    }

    function identity(address user) external view returns (IIdentity) {
        return identityOf[user];
    }

    function investorCountry(address user) external view returns (uint16) {
        return country[user];
    }

    function registerIdentity(address user, IIdentity id, uint16 country_) external {
        known[user] = true;
        verified[user] = true;
        identityOf[user] = id;
        country[user] = country_;
    }

    function deleteIdentity(address user) external {
        known[user] = false;
        verified[user] = false;
        delete identityOf[user];
        delete country[user];
    }

}

/// @dev ERC-3643 standard: Token.
///
///  Runs against the standard base alone (issue #65), so this file must pass unchanged when
///  OpenZeppelin's base replaces ours -- with the documented divergences of `ERC3643Token` re-decided at
///  swap time. The three that this suite pins deliberately are: mint and burn work while paused,
///  compliance hears `created` and `destroyed`, and a burn does not verify the zero address.
contract TokenBaseTest is Test {

    TokenMock internal token;
    StubIdentityRegistry internal registry;
    ComplianceMock internal compliance;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal onchainId = makeAddr("onchainId");

    function setUp() public {
        registry = new StubIdentityRegistry();
        compliance = new ComplianceMock();

        token = new TokenMock();
        token.init("Standard Token", "STD", address(registry), address(compliance), onchainId);

        compliance.bindToken(address(token));

        registry.setVerified(alice, true);
        registry.setVerified(bob, true);
    }

    /* ----- Token information ----- */

    function test_metadata_IsReadBack() public view {
        assertEq(token.name(), "Standard Token");
        assertEq(token.symbol(), "STD");
        assertEq(token.decimals(), 18);
        assertEq(token.onchainID(), onchainId);
        assertEq(address(token.identityRegistry()), address(registry));
        assertEq(address(token.compliance()), address(compliance));
    }

    function test_setName_ReplacesTheNameAndEmits() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.UpdatedTokenInformation("Renamed", "STD", 18, token.version(), onchainId);

        token.setName("Renamed");

        assertEq(token.name(), "Renamed");
    }

    function test_setSymbol_ReplacesTheSymbol() public {
        token.setSymbol("NEW");
        assertEq(token.symbol(), "NEW");
    }

    function test_setOnchainID_ReplacesTheOnchainId() public {
        address replacement = makeAddr("replacement");

        token.setOnchainID(replacement);

        assertEq(token.onchainID(), replacement);
    }

    function test_setIdentityRegistry_RepointsAndEmits() public {
        StubIdentityRegistry replacement = new StubIdentityRegistry();

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.IdentityRegistryAdded(address(replacement));

        token.setIdentityRegistry(address(replacement));

        assertEq(address(token.identityRegistry()), address(replacement));
    }

    function test_setCompliance_RepointsAndEmits() public {
        ComplianceMock replacement = new ComplianceMock();

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.ComplianceAdded(address(replacement));

        token.setCompliance(address(replacement));

        assertEq(address(token.compliance()), address(replacement));
    }

    /* ----- Mint and burn ----- */

    function test_mint_CreditsTheRecipient() public {
        token.mint(alice, 100);

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.totalSupply(), 100);
    }

    function test_mint_RevertWhen_RecipientNotVerified() public {
        registry.setVerified(alice, false);

        vm.expectRevert(ERC3643ErrorsLib.UnverifiedIdentity.selector);
        token.mint(alice, 100);
    }

    function test_burn_DebitsTheHolder() public {
        token.mint(alice, 100);

        token.burn(alice, 40);

        assertEq(token.balanceOf(alice), 60);
        assertEq(token.totalSupply(), 60);
    }

    /// @dev A burn auto-unfreezes exactly as much as it needs and no more.
    function test_burn_UnfreezesOnlyWhatItNeeds() public {
        token.mint(alice, 100);
        token.freezePartialTokens(alice, 80);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.TokensUnfrozen(alice, 30);

        token.burn(alice, 50);

        assertEq(token.balanceOf(alice), 50);
        assertEq(token.getFrozenTokens(alice), 50);
    }

    function test_batchMint_CreditsEveryRecipient() public {
        address[] memory tos = new address[](2);
        tos[0] = alice;
        tos[1] = bob;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;

        token.batchMint(tos, amounts);

        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 20);
    }

    /* ----- Pause ----- */

    function test_pause_BlocksTransfers() public {
        token.mint(alice, 100);
        token.pause();

        assertTrue(token.paused());

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
    }

    function test_unpause_RestoresTransfers() public {
        token.mint(alice, 100);
        token.pause();
        token.unpause();

        vm.prank(alice);
        token.transfer(bob, 1);

        assertEq(token.balanceOf(bob), 1);
    }

    /// @dev Divergence from openzeppelin-contracts#5838, deliberate: issuance and redemption are not
    ///  part of circulation, so a pause does not stop them. Re-decide at swap time.
    function test_mintAndBurn_WorkWhilePaused() public {
        token.pause();

        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);

        token.burn(alice, 40);
        assertEq(token.balanceOf(alice), 60);
    }

    /* ----- Freezing ----- */

    function test_setAddressFrozen_FlagsTheWalletAndEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC3643.AddressFrozen(alice, true, address(this));

        token.setAddressFrozen(alice, true);

        assertTrue(token.isFrozen(alice));
    }

    function test_frozenWallet_CannotSend() public {
        token.mint(alice, 100);
        token.setAddressFrozen(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC3643ErrorsLib.FrozenWallet.selector, alice));
        token.transfer(bob, 1);
    }

    function test_frozenWallet_CannotReceive() public {
        token.mint(alice, 100);
        token.setAddressFrozen(bob, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC3643ErrorsLib.FrozenWallet.selector, bob));
        token.transfer(bob, 1);
    }

    function test_freezePartialTokens_ReducesTheFreeBalance() public {
        token.mint(alice, 100);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.TokensFrozen(alice, 60);

        token.freezePartialTokens(alice, 60);

        assertEq(token.getFrozenTokens(alice), 60);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 40, 41));
        token.transfer(bob, 41);
    }

    function test_freezePartialTokens_RevertWhen_AboveBalance() public {
        token.mint(alice, 100);

        vm.expectRevert();
        token.freezePartialTokens(alice, 101);
    }

    function test_unfreezePartialTokens_RestoresTheFreeBalance() public {
        token.mint(alice, 100);
        token.freezePartialTokens(alice, 60);

        vm.expectEmit(true, false, false, true, address(token));
        emit IERC3643.TokensUnfrozen(alice, 60);

        token.unfreezePartialTokens(alice, 60);

        assertEq(token.getFrozenTokens(alice), 0);
    }

    function test_unfreezePartialTokens_RevertWhen_AboveFrozenAmount() public {
        token.mint(alice, 100);
        token.freezePartialTokens(alice, 10);

        vm.expectRevert(abi.encodeWithSelector(ERC3643ErrorsLib.AmountAboveFrozenTokens.selector, 11, 10));
        token.unfreezePartialTokens(alice, 11);
    }

    /* ----- Transfers ----- */

    function test_transfer_MovesTokens() public {
        token.mint(alice, 100);

        vm.prank(alice);
        token.transfer(bob, 30);

        assertEq(token.balanceOf(alice), 70);
        assertEq(token.balanceOf(bob), 30);
    }

    function test_transfer_RevertWhen_RecipientNotVerified() public {
        token.mint(alice, 100);
        registry.setVerified(bob, false);

        vm.prank(alice);
        vm.expectRevert(ERC3643ErrorsLib.UnverifiedIdentity.selector);
        token.transfer(bob, 1);
    }

    function test_batchTransfer_MovesToEveryRecipient() public {
        token.mint(alice, 100);

        address[] memory tos = new address[](2);
        tos[0] = bob;
        tos[1] = bob;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 5;

        vm.prank(alice);
        token.batchTransfer(tos, amounts);

        assertEq(token.balanceOf(bob), 15);
    }

    /// @dev A forced transfer ignores freezes, unfreezing exactly what it needs.
    function test_forcedTransfer_BypassesFreezes() public {
        token.mint(alice, 100);
        token.freezePartialTokens(alice, 100);
        token.setAddressFrozen(alice, true);

        assertTrue(token.forcedTransfer(alice, bob, 40));

        assertEq(token.balanceOf(alice), 60);
        assertEq(token.balanceOf(bob), 40);
        assertEq(token.getFrozenTokens(alice), 60);
    }

    function test_forcedTransfer_RevertWhen_RecipientNotVerified() public {
        token.mint(alice, 100);
        registry.setVerified(bob, false);

        vm.expectRevert(ERC3643ErrorsLib.UnverifiedIdentity.selector);
        token.forcedTransfer(alice, bob, 1);
    }

    /* ----- Recovery ----- */

    function test_recoveryAddress_MovesBalanceFreezesAndIdentity() public {
        registry.registerIdentity(alice, IIdentity(onchainId), 42);
        token.mint(alice, 100);
        token.freezePartialTokens(alice, 40);
        token.setAddressFrozen(alice, true);

        vm.expectEmit(true, true, true, true, address(token));
        emit IERC3643.RecoverySuccess(alice, bob, onchainId);

        assertTrue(token.recoveryAddress(alice, bob, onchainId));

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100);
        assertEq(token.getFrozenTokens(bob), 40);
        assertTrue(token.isFrozen(bob));
        assertFalse(token.isFrozen(alice));
        assertFalse(registry.contains(alice));
        assertTrue(registry.contains(bob));
    }

}

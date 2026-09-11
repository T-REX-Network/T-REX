// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { EventsLib } from "contracts/libraries/EventsLib.sol";
import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";
import { SlotsModule } from "test/integration/mocks/SlotsModule.sol";

/// @dev A cross-chain validation through the real messaging layer: the burn leg from one chain, the mint leg
///      from another, in either order; the first one pins, the second one settles; and everything a stuck or
///      misbehaving Lite can send in between.
contract CrossChainSettlementTest is InteropSuiteTest {

    uint256 internal constant BALANCE = 1000;

    ERC7786GatewayMock internal polygonGateway;
    ERC7786GatewayMock internal optimismGateway;
    SlotsModule internal slots;
    bytes internal aliceSat;
    bytes internal bobOptimism;
    uint256 internal issuedAt;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        polygonGateway = _newTrustedGateway(POLYGON);
        optimismGateway = _newTrustedGateway(OPTIMISM);
        _openEvmChain(token, POLYGON, address(polygonGateway));
        _openEvmChain(token, OPTIMISM, address(optimismGateway));

        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobOptimism = _linkSatelliteWallet(bobIdentity, OPTIMISM, makeAccount("bobOnOptimism"));

        slots = SlotsModule(
            address(new ModuleProxy(address(new SlotsModule()), abi.encodeCall(SlotsModule.initialize, ())))
        );
        vm.prank(deployer);
        boundCompliance.addModule(address(slots));
        vm.prank(agent);
        token.unpause();

        issuedAt = block.timestamp;
        id = _requestValidation(address(aliceIdentity), aliceSat, bobOptimism, 90, 100);
        assertTrue(boundCompliance.validationOf(id).twoLegs);
    }

    // ==== happy path Tests ====

    /// @notice The burn leg pins and moves nothing; the mint leg settles the pair in one bridged transfer.
    function test_handleSettlement_Success_WhenBurnThenMint() public {
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationLegConfirmed(id, polygon, 95);
        polygonGateway.relay(burn);

        assertEq(slots.commitCalls(), 0, "nothing committed on the first leg");
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE, "the burn leg alone moves nothing");
        assertEq(token.bridgedBalanceOf(bobOptimism), 0);
        assertEq(slots.heldOf(address(boundCompliance), bobOptimism), 100, "still reserved at the maximum");

        vm.expectCall(address(slots), abi.encodeCall(IModule.commitSlot, (id, 95)), 1);
        vm.expectEmit(true, true, true, true, address(token));
        emit EventsLib.BridgedTransfer(keccak256(aliceSat), keccak256(bobOptimism), id, aliceSat, bobOptimism, 95);
        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(id, optimism, 95);
        optimismGateway.relay(mint);

        _assertSettledAt(95);
    }

    /// @notice Reordered delivery: the mint leg pins, the burn leg settles, same ledger result.
    function test_handleSettlement_Success_WhenMintThenBurn() public {
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationLegConfirmed(id, optimism, 95);
        optimismGateway.relay(mint);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
        ITransferValidation.ValidationState memory state = boundCompliance.stateOf(id);
        assertFalse(state.fromLegConsumed);
        assertTrue(state.toLegConsumed);
        assertEq(state.legWallet, bobOptimism);
        assertEq(token.bridgedBalanceOf(bobOptimism), 0);

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ValidationSettled(id, polygon, 95);
        polygonGateway.relay(burn);

        _assertSettledAt(95);
    }

    // ==== stuck mint Tests ====

    /// @notice A burn leg with no mint in sight: the validation is pinned, never `Expired`, never discardable.
    function test_discardExpiredValidations_RevertWhen_TheMintIsStuckAfterTheBurn() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        vm.warp(issuedAt + VALIDITY_WINDOW + OPTIMISM_WINDOW + 365 days);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ValidationNotDiscardable.selector,
                id,
                uint8(ITransferValidation.ValidationStatus.BurnConfirmed)
            )
        );
        boundCompliance.discardExpiredValidations(ids);

        assertEq(slots.heldOf(address(boundCompliance), bobOptimism), 100, "the reservation stays");
        assertEq(slots.releaseCalls(), 0);

        // The mint leg, however late, completes the pair.
        optimismGateway.relay(_liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 95)));
        _assertSettledAt(95);
    }

    // ==== refusal Tests ====

    /// @notice A consumed leg delivered again as a fresh message halts the token and moves nothing.
    function test_handleSettlement_Success_WhenAConsumedLegIsReplayed() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        uint256 replay = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95));

        vm.expectEmit(true, true, false, true, address(boundCompliance));
        emit EventsLib.ReplayedSettlement(id, polygon);
        polygonGateway.relay(replay);

        assertTrue(token.paused());
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE);
        assertFalse(boundCompliance.stateOf(id).toLegConsumed);
    }

    /// @notice The two legs must carry one amount.
    function test_handleSettlement_RevertWhen_TheLegsDisagreeOnTheAmount() public {
        polygonGateway.relay(_liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 95)));
        uint256 mint = _liteSettles(optimismGateway, token, _mintLeg(id, token, bobOptimism, 96));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementAmountMismatch.selector, id, 95, 96));
        optimismGateway.relay(mint);

        assertFalse(token.messageReceived(address(optimismGateway), optimismGateway.receiveIdFor(mint)));
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.BurnConfirmed));
        assertEq(token.bridgedBalanceOf(bobOptimism), 0);
    }

    /// @notice A burn leg can only come from the sender's chain, a mint leg only from the recipient's.
    function test_handleSettlement_RevertWhen_ALegComesFromTheWrongChain() public {
        uint256 burnFromOptimism = _liteSettles(optimismGateway, token, _burnLeg(id, token, aliceSat, 95));
        uint256 mintFromPolygon = _liteSettles(polygonGateway, token, _mintLeg(id, token, bobOptimism, 95));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        optimismGateway.relay(burnFromOptimism);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        polygonGateway.relay(mintFromPolygon);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    /// @notice A notification carrying both wallets is no leg of a two-leg validation.
    function test_handleSettlement_RevertWhen_BothWalletsAreFilledOnATwoLegValidation() public {
        uint256 index = _liteSettles(polygonGateway, token, _settlement(id, token, aliceSat, bobOptimism, 95));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementLegMismatch.selector, id));
        polygonGateway.relay(index);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    /// @notice The first leg is bounds-checked like any other.
    function test_handleSettlement_RevertWhen_TheFirstLegIsOutOfBounds() public {
        uint256 burn = _liteSettles(polygonGateway, token, _burnLeg(id, token, aliceSat, 101));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.SettlementOutOfBounds.selector, id, 101));
        polygonGateway.relay(burn);

        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Pending));
    }

    function _assertSettledAt(uint256 amount) private view {
        assertEq(uint8(boundCompliance.statusOf(id)), uint8(ITransferValidation.ValidationStatus.Settled));
        ITransferValidation.ValidationState memory state = boundCompliance.stateOf(id);
        assertTrue(state.fromLegConsumed);
        assertTrue(state.toLegConsumed);
        assertEq(state.executedAmount, amount);
        assertEq(token.bridgedBalanceOf(aliceSat), BALANCE - amount);
        assertEq(token.bridgedBalanceOf(bobOptimism), amount);
        assertEq(token.totalBridged(), BALANCE);
        assertEq(slots.heldOf(address(boundCompliance), bobOptimism), amount);
        assertEq(slots.commitCalls(), 1);
        assertFalse(token.paused());
    }

}

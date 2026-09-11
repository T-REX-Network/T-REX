// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A deployed suite plus the vocabulary the interop tests share: satellite chains, their keys,
///      how a chain is opened, and how a Lite is impersonated when it sends something back.
abstract contract InteropSuiteTest is TREXSuiteTest {

    uint256 constant POLYGON = 137;
    uint256 constant OPTIMISM = 10;

    bytes32 polygon = _evmChainKey(POLYGON);
    bytes32 optimism = _evmChainKey(OPTIMISM);

    uint64 constant VALIDITY_WINDOW = 1 hours;
    uint64 constant POLYGON_WINDOW = 30 minutes;
    uint64 constant OPTIMISM_WINDOW = 45 minutes;

    /// @dev The suite token's compliance, with the validation windows an issuance needs already set.
    ModularCompliance boundCompliance;

    /// @dev Holds VALIDATION_KEEPER and nothing else.
    address public keeper = makeAddr("keeper");

    function setUp() public virtual override {
        super.setUp();
        boundCompliance = ModularCompliance(address(token.compliance()));
        _grantValidationKeeperRole(keeper);
        vm.startPrank(deployer);
        boundCompliance.setDefaultValidityWindow(VALIDITY_WINDOW);
        boundCompliance.setReconciliationWindow(polygon, POLYGON_WINDOW);
        boundCompliance.setReconciliationWindow(optimism, OPTIMISM_WINDOW);
        vm.stopPrank();
    }

    /// @dev The token is the ledger harness, so a test can fund a satellite wallet before any flow does.
    function _deployImplementations() internal virtual override {
        super._deployImplementations();
        tokenImplementation = Token(address(new TokenLedgerHarness()));
    }

    /// @dev Links `signer`'s wallet on `chainId` to `identity` and moves `amount` of `holder`'s tokens onto it.
    function _fundSatelliteWallet(
        IIdentity identity,
        address holder,
        uint256 chainId,
        Account memory signer,
        uint256 amount
    ) internal returns (bytes memory envelope) {
        envelope = _linkSatelliteWallet(identity, chainId, signer);
        vm.startPrank(agent);
        token.mint(holder, amount);
        TokenLedgerHarness(address(token)).delegateOut(holder, envelope, amount);
        vm.stopPrank();
    }

    function _requestValidation(address caller, bytes memory from, bytes memory to, uint256 min, uint256 max)
        internal
        returns (uint256)
    {
        vm.prank(caller);
        return boundCompliance.requestTransferValidation(from, to, min, max, "");
    }

    /// @dev The validation a queued message carries, as the Lite would decode it.
    function _decodeQueuedValidation(ERC7786GatewayMock gateway, uint256 index)
        internal
        view
        returns (MessageTypesLib.ComplianceValidation memory)
    {
        (, bytes memory body) = MessageTypesLib.decode(gateway.queuedMessage(index).payload);
        return MessageTypesLib.decodeValidation(body);
    }

    /// @dev The ERC-7930 prefix of an EVM chain, as a gateway derives it from a canonical sender.
    function _evmChain(uint256 chainId) internal pure returns (bytes2 chainType, bytes memory chainReference) {
        (chainType, chainReference,) = InteroperableAddress.parseV1(InteroperableAddress.formatEvmV1(chainId));
    }

    function _evmChainKey(uint256 chainId) internal pure returns (bytes32) {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(chainId);
        return MessageTypesLib.chainKey(chainType, chainReference);
    }

    /// @dev A trusted gateway standing in for `chainId`'s counterpart gateway.
    function _newTrustedGateway(uint256 chainId) internal returns (ERC7786GatewayMock gateway) {
        gateway = new ERC7786GatewayMock(chainId);
        trustedGatewayRegistry.setTrustedGateway(address(gateway), true);
    }

    /// @dev Routes `_token`'s traffic for the EVM chain `chainId` through `gateway`, as the issuer.
    function _openEvmChain(Token _token, uint256 chainId, address gateway) internal {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(chainId);

        vm.prank(deployer);
        _token.setRoute(chainType, chainReference, gateway);
    }

    /// @dev Queues `payload` for `_token` through `gateway`, authored by `author`, returning its index.
    function _queue(ERC7786GatewayMock gateway, address author, Token _token, bytes memory payload)
        internal
        returns (uint256)
    {
        vm.prank(author);
        gateway.sendMessage(InteroperableAddress.formatEvmV1(block.chainid, address(_token)), payload, new bytes[](0));

        return gateway.queueLength() - 1;
    }

    /// @dev Queues a message authored by `_token`'s own Lite: on an EVM chain that is the token's address.
    function _liteSends(ERC7786GatewayMock gateway, Token _token, bytes memory payload) internal returns (uint256) {
        return _queue(gateway, address(_token), _token, payload);
    }

    function _settlement(uint256 validationId, Token _token, bytes memory from, bytes memory to, uint256 amount)
        internal
        pure
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return MessageTypesLib.SettlementNotification({
            validationId: validationId, token: address(_token), from: from, to: to, amount: amount
        });
    }

    function _sameChainSettlement(uint256 validationId, Token _token, uint256 chainId, uint256 amount)
        internal
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return _settlement(
            validationId,
            _token,
            InteroperableAddress.formatEvmV1(chainId, makeAddr("SatelliteFrom")),
            InteroperableAddress.formatEvmV1(chainId, makeAddr("SatelliteTo")),
            amount
        );
    }

    /// @dev Queues a settlement authored by `_token`'s Lite on `gateway`'s chain, returning its index.
    function _liteSettles(
        ERC7786GatewayMock gateway,
        Token _token,
        MessageTypesLib.SettlementNotification memory notification
    ) internal returns (uint256) {
        return _liteSends(gateway, _token, MessageTypesLib.encodeSettlement(notification));
    }

    /// @dev The burn leg of a cross-chain validation: `to` is empty, by convention.
    function _burnLeg(uint256 validationId, Token _token, bytes memory from, uint256 amount)
        internal
        pure
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return _settlement(validationId, _token, from, "", amount);
    }

    /// @dev The mint leg of a cross-chain validation: `from` is empty, by convention.
    function _mintLeg(uint256 validationId, Token _token, bytes memory to, uint256 amount)
        internal
        pure
        returns (MessageTypesLib.SettlementNotification memory)
    {
        return _settlement(validationId, _token, "", to, amount);
    }

    function _burnProof(uint256 chainId, address burned, uint256 amount, address nativeWallet)
        internal
        pure
        returns (MessageTypesLib.BurnProof memory)
    {
        return MessageTypesLib.BurnProof({
            burnedWallet: InteroperableAddress.formatEvmV1(chainId, burned), amount: amount, nativeWallet: nativeWallet
        });
    }

}

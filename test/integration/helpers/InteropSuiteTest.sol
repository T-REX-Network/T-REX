// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { Token } from "contracts/token/Token.sol";

import { TREXSuiteTest } from "test/integration/helpers/TREXSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev A deployed suite plus the vocabulary the interop tests share: satellite chains, their keys,
///      how a chain is opened, and how a Lite is impersonated when it sends something back.
abstract contract InteropSuiteTest is TREXSuiteTest {

    uint256 constant POLYGON = 137;
    uint256 constant OPTIMISM = 10;

    bytes32 polygon = _evmChainKey(POLYGON);
    bytes32 optimism = _evmChainKey(OPTIMISM);

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

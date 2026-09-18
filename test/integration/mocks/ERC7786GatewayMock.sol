// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { IERC7786GatewaySource, IERC7786Recipient } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

/**
 * @title ERC7786GatewayMock
 * @notice Same-chain loopback ERC-7786 gateway that never delivers on its own.
 *
 * A send only queues. A test then relays an entry explicitly, which is what makes ordering,
 * duplication and loss controllable: relay out of order, relay the same entry twice, or drop one and
 * relay the rest. Production adapters differ in what happens between the two halves, not in this
 * interface, so swapping one in later is configuration rather than code.
 *
 * `receiveId` is derived from the queue index alone, so a redelivery carries the id it carried the
 * first time. That is what lets a test prove the endpoint's own transport dedupe: the pinned
 * OpenZeppelin `ERC7786Recipient` keeps no record of delivered ids and leaves that to the gateway.
 *
 * The mock presents every delivered message as coming from `originChainId`, so one instance stands in
 * for the counterpart gateway of one satellite chain: a test deploys one per chain it needs, and a
 * message from the "satellite" is simply sent through the mock by the address playing the Lite.
 */
contract ERC7786GatewayMock is IERC7786GatewaySource {

    /// @notice The chain every relayed message is attributed to.
    uint256 public immutable originChainId;

    struct QueuedMessage {
        address sender;
        bytes recipient;
        bytes payload;
        bool dropped;
        uint256 deliveries;
    }

    QueuedMessage[] private _queue;

    constructor(uint256 originChainId_) {
        originChainId = originChainId_;
    }

    /// @notice Queues a message. Nothing is delivered until `relay` is called for its index.
    function sendMessage(bytes calldata recipient, bytes calldata payload, bytes[] calldata attributes)
        external
        payable
        returns (bytes32 sendId)
    {
        // Attributes are out of scope in v1: adapters own fees and gas semantics later.
        attributes;

        _queue.push(
            QueuedMessage({ sender: msg.sender, recipient: recipient, payload: payload, dropped: false, deliveries: 0 })
        );

        sendId = _idFor(_queue.length - 1);

        emit MessageSent(
            sendId,
            InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
            recipient,
            payload,
            msg.value,
            attributes
        );
    }

    /// @notice Delivers the queued entry at `index` to its recipient. Callable repeatedly, on purpose.
    function relay(uint256 index) external {
        QueuedMessage storage message = _queue[index];
        require(!message.dropped, "ERC7786GatewayMock: dropped");

        message.deliveries += 1;

        (, address recipient) = InteroperableAddress.parseEvmV1(message.recipient);

        IERC7786Recipient(recipient)
            .receiveMessage(
                _idFor(index), InteroperableAddress.formatEvmV1(originChainId, message.sender), message.payload
            );
    }

    /// @notice Marks a queued entry undeliverable, standing in for a message the transport lost.
    function drop(uint256 index) external {
        _queue[index].dropped = true;
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function queuedMessage(uint256 index) external view returns (QueuedMessage memory) {
        return _queue[index];
    }

    function receiveIdFor(uint256 index) external view returns (bytes32) {
        return _idFor(index);
    }

    /// @dev Every message is queued for an explicit relay, so no attribute is ever honoured.
    function supportsAttribute(bytes4) external pure returns (bool) {
        return false;
    }

    /// @dev Stable across redeliveries: the same entry always carries the same id.
    function _idFor(uint256 index) private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), index));
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

/// @title TokenReservationStub
/// @dev The part of the token the issuance layer talks to about a satellite wallet's room, with real state.
///
///      These unit tests mock the token as a bare address, which cannot accumulate anything. The reservation a
///      validation takes against a wallet now lives on the token, and several of these tests are about
///      reservations adding up and capping the next issuance, so a static mock would assert nothing. This keeps
///      the same arithmetic the token does: reserve adds, release subtracts and floors, available is the
///      balance less what is reserved.
contract TokenReservationStub {

    mapping(bytes32 walletKey => uint256) public reserved;
    mapping(bytes32 walletKey => uint256) public bridged;

    function setBridgedBalance(bytes calldata wallet, uint256 amount) external {
        bridged[keccak256(wallet)] = amount;
    }

    function bridgedBalanceOf(bytes calldata wallet) external view returns (uint256) {
        return bridged[keccak256(wallet)];
    }

    function reservedOf(bytes calldata wallet) external view returns (uint256) {
        return reserved[keccak256(wallet)];
    }

    function availableOf(bytes calldata wallet) external view returns (uint256) {
        uint256 balance = bridged[keccak256(wallet)];
        uint256 held = reserved[keccak256(wallet)];
        return held < balance ? balance - held : 0;
    }

    function reserveForValidation(bytes calldata wallet, uint256 amount) external {
        reserved[keccak256(wallet)] += amount;
    }

    function releaseFromValidation(bytes calldata wallet, uint256 amount) external {
        bytes32 key = keccak256(wallet);
        uint256 held = reserved[key];
        reserved[key] = held < amount ? 0 : held - amount;
    }

    function holdInTransit(bytes calldata wallet, uint256, uint256, uint256 amountReserved) external {
        bytes32 key = keccak256(wallet);
        uint256 held = reserved[key];
        reserved[key] = held < amountReserved ? 0 : held - amountReserved;
    }

}

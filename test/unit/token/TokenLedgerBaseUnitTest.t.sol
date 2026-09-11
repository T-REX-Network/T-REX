// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { Token } from "contracts/token/Token.sol";

import { TokenLedgerHarness } from "test/integration/helpers/TokenLedgerHarness.sol";
import { BeaconProxyDeployer } from "test/unit/helpers/BeaconProxyDeployer.sol";

import { TokenBaseUnitTest } from "./TokenBaseUnitTest.t.sol";

/// @notice Same mocks as {TokenBaseUnitTest}, with the harness as implementation so the ledger transitions are
///         reachable. Two native holders and three satellite wallets on two chains.
abstract contract TokenLedgerBaseUnitTest is TokenBaseUnitTest {

    uint256 internal constant SATELLITE_CHAIN = 8453;
    uint256 internal constant OTHER_SATELLITE_CHAIN = 137;

    TokenLedgerHarness ledger;
    address harnessBeacon;

    bytes satellite1 = satelliteEnvelope(SATELLITE_CHAIN, makeAddr("Satellite1"));
    bytes satellite2 = satelliteEnvelope(SATELLITE_CHAIN, makeAddr("Satellite2"));
    bytes satellite3 = satelliteEnvelope(OTHER_SATELLITE_CHAIN, makeAddr("Satellite3"));

    constructor() {
        harnessBeacon = BeaconProxyDeployer.newBeacon(address(new TokenLedgerHarness()));
    }

    function setUp() public virtual override {
        _deployAccessManager();

        token = Token(
            BeaconProxyDeployer.newProxy(
                harnessBeacon,
                abi.encodeCall(
                    Token.init,
                    ("Token", "TKN", 18, identityRegistry, compliance, address(onchainId), address(accessManager))
                )
            )
        );
        ledger = TokenLedgerHarness(address(token));

        AccessManagerSetupLib.setupTokenRoles(accessManager, address(token));
        _grantAllAgentRoles(agent);

        vm.prank(agent);
        token.unpause();
    }

    function satelliteEnvelope(uint256 chainId, address wallet) internal pure returns (bytes memory) {
        return InteroperableAddress.formatEvmV1(chainId, wallet);
    }

    /// @dev Conservation over every position the suite knows: the native balances and the bridged positions
    ///  partition `totalSupply`, and `totalBridged` is the bridged sum.
    function _assertPartition() internal view {
        uint256 bridgedSum = token.bridgedBalanceOf(satellite1) + token.bridgedBalanceOf(satellite2)
            + token.bridgedBalanceOf(satellite3);
        assertEq(
            token.balanceOf(user1) + token.balanceOf(user2) + bridgedSum,
            token.totalSupply(),
            "buckets do not sum to the supply"
        );
        assertEq(bridgedSum, token.totalBridged(), "bridged positions do not sum to totalBridged");
        assertEq(token.balanceOf(address(token)), 0, "the token holds no escrow");
    }

}

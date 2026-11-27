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

pragma solidity 0.8.30;

import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
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

    /// @dev CCIP's finality value that admits fully finalized messages only.
    bytes4 constant FULL_FINALITY = bytes4(0);

    /// @dev The validity window of a ticket on the ticket route, sent before home's finality.
    uint64 constant TICKET_ROUTE_WINDOW = 15 minutes;
    /// @dev The validity window of a ticket on the receipt route, at full finality: every ticket of a chain with no
    ///  trusted ticket bridge, so the window most tests see.
    uint64 constant VALIDITY_WINDOW = 25 minutes;
    /// @dev The waiting times of the two away chains, above every floor their measured times give.
    uint64 constant POLYGON_WINDOW = 95 minutes;
    uint64 constant OPTIMISM_WINDOW = 100 minutes;

    /// @dev The most one ticket toward an away chain, and the ticket route in one window, may carry: above every
    ///  amount the tests move, so the route is chosen by the bridges a test trusts.
    uint256 constant TICKET_CAP = 1e30;

    /// @dev The suite token's compliance, with the windows, waiting times and limits an ask needs already set.
    ModularCompliance boundCompliance;

    function setUp() public virtual override {
        super.setUp();
        boundCompliance = ModularCompliance(address(token.compliance()));
        vm.startPrank(deployer);
        boundCompliance.setMeasuredTimes(polygon, _measuredTimes());
        boundCompliance.setMeasuredTimes(optimism, _measuredTimes());
        boundCompliance.setValidityWindows(TICKET_ROUTE_WINDOW, VALIDITY_WINDOW);
        boundCompliance.setWaitingTime(polygon, POLYGON_WINDOW);
        boundCompliance.setWaitingTime(optimism, OPTIMISM_WINDOW);
        boundCompliance.setAskLimits(_askLimits());
        boundCompliance.setTicketLimits(polygon, TICKET_CAP, TICKET_CAP);
        boundCompliance.setTicketLimits(optimism, TICKET_CAP, TICKET_CAP);
        vm.stopPrank();
    }

    /// @dev Times measured for an away chain, in seconds: the validity windows and waiting times above clear them.
    function _measuredTimes() internal pure returns (ITickets.MeasuredTimes memory) {
        return ITickets.MeasuredTimes({
            shortestValidityWindow: 10 minutes,
            shortestWaitingTime: 80 minutes,
            clockLead: 30 seconds,
            clockLag: 30 seconds,
            fullFinalityDelivery: 20 minutes,
            reorgSlotShift: 1 minutes
        });
    }

    /// @dev Ask limits no test reaches unless it means to.
    function _askLimits() internal pure returns (ITickets.AskLimits memory) {
        return ITickets.AskLimits({
            openTicketsPerIdentity: 100, asksPerIdentityPerWindow: 1000, askWindow: 1 days, smallestAmount: 1
        });
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
        TokenLedgerHarness(address(token)).ledgerMoveOut(holder, envelope, amount);
        vm.stopPrank();
    }

    function _requestValidation(address caller, bytes memory from, bytes memory to, uint256 min, uint256 max)
        internal
        returns (bytes32)
    {
        vm.prank(caller);
        return boundCompliance.askToMove(from, to, min, max, "", _salt());
    }

    uint256 private _saltNonce;
    /// @dev The salt the last `_salt()` returned, so a test can name the id a refused request would have taken.
    bytes32 internal lastSalt;

    /// @dev A fresh salt per request, as a requester's backend would supply one.
    function _salt() internal returns (bytes32) {
        lastSalt = keccak256(abi.encode(address(this), ++_saltNonce));
        return lastSalt;
    }

    /// @dev The id a request gets, as the compliance builds it: a move, the keys of both wallets and of the
    ///  spender, the asked bounds and the salt.
    function _ticketId(
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 requestedMin,
        uint256 requestedMax,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return TicketLib.ticketIdOf(
            ITickets.TicketKind.MOVE,
            WalletKeyLib.canonicalKey(from),
            WalletKeyLib.canonicalKey(to),
            keccak256(spender),
            requestedMin,
            requestedMax,
            salt
        );
    }

    /// @dev The receipt bridge the ticket `ticketId`, the first half of its move, is pinned to; zero when it never
    ///  left.
    function _pinnedBridgeOf(bytes32 ticketId) internal view returns (address bridge) {
        (bridge,) = token.pinOf(MessageTypesLib.halfKeyOf(ticketId, 0));
    }

    /// @dev Asks for the receipt of the open ticket `ticketId` at its first due time, one waiting time after its valid
    ///  until, then lets one more waiting time pass with no answer: from then on anyone may cancel it.
    function _askAndLetTheAskGoUnanswered(bytes32 ticketId, bytes memory to, bytes memory spender) internal {
        ITickets.Ticket memory ticket = boundCompliance.ticketOf(ticketId);
        uint64 firstAskDueAt = ticket.validUntil + ticket.waitingTime;
        if (block.timestamp < firstAskDueAt) vm.warp(firstAskDueAt);
        boundCompliance.sendTicket(ticketId, ticket.fromChainKey, to, spender);
        vm.warp(block.timestamp + ticket.waitingTime + 1);
    }

    /// @dev Cancels the open ticket `ticketId` the only way a sent ticket is cancelled: an ask for its receipt that
    ///  went unanswered for one waiting time, then a cancel by anyone.
    function _cancelUnanswered(bytes32 ticketId, bytes memory to, bytes memory spender) internal {
        _askAndLetTheAskGoUnanswered(ticketId, to, spender);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ticketId;
        boundCompliance.cancelTickets(ids);
    }

    /// @dev The request sent with the last salt was refused: nothing was recorded under its id.
    function _assertNothingRecorded(
        bytes memory from,
        bytes memory to,
        bytes memory spender,
        uint256 requestedMin,
        uint256 requestedMax
    ) internal view {
        bytes32 refusedId = _ticketId(from, to, spender, requestedMin, requestedMax, lastSalt);
        assertEq(boundCompliance.ticketOf(refusedId).fromIdentity, address(0), "nothing recorded");
    }

    /// @dev The validation a queued message carries, as the Lite would decode it.
    function _decodeQueuedValidation(ERC7786GatewayMock gateway, uint256 index)
        internal
        view
        returns (MessageTypesLib.TicketMessage memory)
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

    /// @dev The CCIP selector the tests give the away chain `chainId`. CCIP selectors are not chain ids.
    function _awayChainSelector(uint256 chainId) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode("away chain selector", chainId))));
    }

    /// @dev The bridge on the away chain `chainId` that sends the receipts, as CCIP reports a sender.
    function _awayReceiptBridge(uint256 chainId) internal pure returns (bytes memory) {
        return abi.encode(address(uint160(uint256(keccak256(abi.encode("away receipt bridge", chainId))))));
    }

    /// @dev A receipt bridge standing in for `chainId`'s counterpart, recorded in the registry, whose receiving
    ///  policy admits that chain's away receipt bridge at full finality only.
    function _newReceiptBridge(uint256 chainId) internal returns (ERC7786GatewayMock bridge) {
        bridge = new ERC7786GatewayMock(chainId);
        bridge.setReceivingPolicy(_awayChainSelector(chainId), _awayReceiptBridge(chainId), FULL_FINALITY);
        trustedGatewayRegistry.trustReceiptBridge(address(bridge));
    }

    /// @dev A ticket bridge toward `chainId`, recorded in the registry with the depth it waits for.
    function _newTicketBridge(uint256 chainId, uint64 depth) internal returns (ERC7786GatewayMock bridge) {
        bridge = new ERC7786GatewayMock(chainId);
        trustedGatewayRegistry.trustTicketBridge(address(bridge), depth);
    }

    /// @dev Sets `_token`'s receipt route for the EVM chain `chainId` to `bridge`, as the issuer.
    function _openEvmChain(Token _token, uint256 chainId, address bridge) internal {
        (bytes2 chainType, bytes memory chainReference) = _evmChain(chainId);

        vm.prank(deployer);
        _token.setReceiptRoute(
            chainType, chainReference, bridge, _awayChainSelector(chainId), _awayReceiptBridge(chainId)
        );
    }

    /// @dev Closes `_token`'s receipt route for the EVM chain `chainId`, as the issuer.
    function _closeEvmChain(Token _token, uint256 chainId) internal {
        vm.prank(deployer);
        _token.closeReceiptRoute(_evmChainKey(chainId));
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

    /// @dev A leg echoing the issued copy, as a Lite that executed it reports it; zero when the id was never
    ///  issued here.
    function _settlement(bytes32 ticketId, bytes memory from, bytes memory to, uint256 amount)
        internal
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _settlementUnder(ticketId, from, to, amount, boundCompliance.ticketOf(ticketId).askBlockHash);
    }

    /// @dev A leg echoing the copy named by `askBlockHash`, with the issued maximum and valid until: what a Lite
    ///  that executed another copy than the issued one reports.
    function _settlementUnder(
        bytes32 ticketId,
        bytes memory from,
        bytes memory to,
        uint256 amount,
        bytes32 askBlockHash
    ) internal view returns (MessageTypesLib.ReceiptMessage memory) {
        ITickets.Ticket memory issued = boundCompliance.ticketOf(ticketId);
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: from,
            to: to,
            amount: amount,
            askBlockHash: askBlockHash,
            seenMax: issued.amountMax,
            seenValidUntil: issued.validUntil,
            half: 0,
            answer: MessageTypesLib.ReceiptAnswer.Executed
        });
    }

    function _sameChainSettlement(bytes32 ticketId, uint256 chainId, uint256 amount)
        internal
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _settlement(
            ticketId,
            InteroperableAddress.formatEvmV1(chainId, makeAddr("SatelliteFrom")),
            InteroperableAddress.formatEvmV1(chainId, makeAddr("SatelliteTo")),
            amount
        );
    }

    /// @dev Queues a settlement authored by `_token`'s Lite on `gateway`'s chain, returning its index.
    function _liteSettles(ERC7786GatewayMock gateway, Token _token, MessageTypesLib.ReceiptMessage memory notification)
        internal
        returns (uint256)
    {
        return _liteSends(gateway, _token, MessageTypesLib.encodeSettlement(notification));
    }

}

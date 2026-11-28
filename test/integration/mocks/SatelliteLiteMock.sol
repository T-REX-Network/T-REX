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

import { IERC7786Recipient } from "@openzeppelin/contracts/interfaces/draft-IERC7786.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ITickets } from "contracts/compliance/modular/ITickets.sol";
import { TicketLib } from "contracts/compliance/modular/TicketLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { MessageTypesLib } from "contracts/libraries/MessageTypesLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";

import { ERC7786GatewayMock } from "./ERC7786GatewayMock.sol";

/**
 * @title SatelliteLiteMock
 * @notice An away token that follows every rule in `docs/satellite-lite.md`, so home can be run against the
 *  counterpart it assumes.
 *
 * One instance stands in for the away token of one away chain. It receives home's messages through that chain's
 * `ERC7786GatewayMock`, which the test registers as the token's peer for the chain, and answers through the same
 * gateway. It never talks to another away token: a move to another chain only burns here, and home sends the second
 * half.
 *
 * What it enforces: only its own gateway delivers (`msg.sender`), and only the home token is an author; the first copy
 * of a ticket is kept, and a copy whose valid until is further ahead of this chain's clock than `validUntilBound` is
 * ignored; a ticket is executed at most once, strictly before its valid until, inside its range, for its wallets, by
 * its sender or by its named spender within the allowance the sender gave; a later copy of a ticket is an ask for the
 * receipt, answered with the stored receipt, a stored zero receipt (`Expired`) once valid until passed, or a still
 * open answer before; a first copy that arrives at or after its valid until is answered with a stored zero receipt;
 * a move out mints and a bring home burns `min(amount, balance)` once per half, strictly before the half's valid
 * until, and a half that arrives later is answered with a stored zero receipt; a repeated half is answered with its
 * stored receipt. Every receipt is kept under the type of the message it answers and its half key, and can be sent
 * again byte for byte. A ticket whose id is not the id of its own terms, its kind included, is refused. Answers that
 * send a stored receipt again are limited per half to a count in each answer window, and the resends anyone asks for,
 * apart from them, to a quota spaced by one fixed wait; a still open answer is not counted.
 */
contract SatelliteLiteMock is IERC7786Recipient {

    error NotTheGateway(address caller);
    error NotTheReferenceToken(bytes sender);
    error AlreadyDelivered(bytes32 receiveId);
    error UnknownTicket(bytes32 ticketId);
    error ValidationConsumed(bytes32 ticketId);
    error ValidationExpired(bytes32 ticketId);
    error AmountOutOfRange(bytes32 ticketId, uint256 amount);
    error NotTheExecutor(bytes32 ticketId, address caller);
    error AllowanceTooLow(bytes32 ticketId, uint256 allowance, uint256 amount);
    error InsufficientBalance(bytes wallet, uint256 balance, uint256 amount);
    error NoStoredReceipt(uint8 messageType, bytes32 halfKey);
    error UnexpectedMessage(uint8 messageType);
    error TicketIdMismatch(bytes32 ticketId, bytes32 idOfTheTerms);
    error ReceiptResendTooSoon(uint8 messageType, bytes32 halfKey, uint64 resendAllowedAt);
    error NoReceiptResendLeft(uint8 messageType, bytes32 halfKey);

    /// @notice An ask for a half's receipt came after the half used its answers of the current answer window: nothing
    ///  was sent.
    event AnswerNotSent(uint8 messageType, bytes32 indexed halfKey);

    /// @notice The most answers per half in one answer window that send its stored receipt again, to later copies of a
    ///  ticket or repeats of a half: home sends at most three asks for a ticket's receipt and three sends of a half, so
    ///  six cover home and a redelivery of each. The first send of a receipt and a still open answer are not counted.
    uint8 public constant MAX_ANSWERS_PER_WINDOW = 6;
    /// @notice The most resends per half anyone may ask for with {resendReceipt}, counted apart from the answers.
    uint8 public constant MAX_RECEIPT_RESENDS = 3;

    /// @dev When a half's receipt was last sent, and what was sent for it beyond its first send: the answers of the
    ///  answer window that started at `answerWindowStartedAt`, and the resends.
    struct ReceiptSends {
        uint64 lastSentAt;
        uint64 answerWindowStartedAt;
        uint8 answersInWindow;
        uint8 resendsSent;
    }

    uint256 public immutable chainId;
    address public immutable referenceToken;
    ERC7786GatewayMock public immutable gateway;

    /// @notice How far ahead of this chain's clock a ticket's valid until may be and still be held, in seconds: the
    ///  validity window plus the lag budget. A copy further ahead is ignored, so a forged far valid until is never held.
    uint64 public validUntilBound;
    /// @notice The wait between two sends of one half's receipt before {resendReceipt} sends it again, in seconds.
    ///  Never set back to zero; a deployment sets it.
    uint64 public receiptResendWait;
    /// @notice The window, in seconds, over which a half's answers are counted against `MAX_ANSWERS_PER_WINDOW`.
    ///  Never set back to zero; a deployment sets it.
    uint64 public answerWindow;

    mapping(bytes32 receiveId => bool isDelivered) public delivered;
    /// @dev The first copy of each ticket, the only one ever executed.
    mapping(bytes32 ticketId => MessageTypesLib.TicketMessage firstCopy) internal _tickets;
    mapping(bytes32 ticketId => bool isHeld) public known;
    /// @dev A half is answered once: its receipt is kept under the type of the message it answers and its half key,
    ///  and its bytes are what a repeat gets. A ticket's own receipt is kept under `TICKET` and the ticket id.
    mapping(uint8 messageType => mapping(bytes32 halfKey => MessageTypesLib.ReceiptMessage receipt)) internal _receipts;
    mapping(uint8 messageType => mapping(bytes32 halfKey => bool isAnswered)) public answered;
    mapping(uint8 messageType => mapping(bytes32 halfKey => ReceiptSends sends)) public receiptSends;
    mapping(bytes32 walletKey => uint256 balance) internal _balances;
    mapping(bytes32 walletKey => mapping(address spender => uint256 allowance)) public allowances;

    uint256 public mints;
    uint256 public burns;

    constructor(uint256 chainId_, address referenceToken_, ERC7786GatewayMock gateway_) {
        chainId = chainId_;
        referenceToken = referenceToken_;
        gateway = gateway_;
        validUntilBound = type(uint64).max;
    }

    /// @notice Sets how far ahead of this chain's clock a held ticket's valid until may be.
    function setValidUntilBound(uint64 bound) external {
        validUntilBound = bound;
    }

    /// @notice Sets the wait between two sends of a receipt before a resend; zero is refused, so the rate stays.
    function setReceiptResendWait(uint64 wait) external {
        require(wait != 0, ErrorsLib.ZeroValue());
        receiptResendWait = wait;
    }

    /// @notice Sets the window over which a half's answers are counted; zero is refused, so the rate stays.
    function setAnswerWindow(uint64 window) external {
        require(window != 0, ErrorsLib.ZeroValue());
        answerWindow = window;
    }

    /// @notice The caller, a wallet on this chain, lets `spender` execute its tickets up to `amount`.
    function approve(address spender, uint256 amount) external {
        allowances[_walletKeyOf(msg.sender)][spender] = amount;
    }

    function balanceOf(bytes memory wallet) external view returns (uint256) {
        return _balances[keccak256(wallet)];
    }

    /// @notice The copy of the ticket this away token holds: the first one it received.
    function ticketOf(bytes32 ticketId) external view returns (MessageTypesLib.TicketMessage memory) {
        return _tickets[ticketId];
    }

    /// @notice The valid until of the ticket copy held, zero when none is held: what a reader of a closed chain sees.
    function storedTicketValidUntil(bytes32 ticketId) external view returns (uint64) {
        return _tickets[ticketId].validUntil;
    }

    /// @notice The receipt stored for one half of one message type, all zero when that half was never answered.
    function storedReceipt(uint8 messageType, bytes32 halfKey)
        external
        view
        returns (MessageTypesLib.ReceiptMessage memory)
    {
        return _receipts[messageType][halfKey];
    }

    /// @notice Whether the ticket was executed.
    function consumed(bytes32 ticketId) external view returns (bool) {
        uint8 ticketType = uint8(MessageTypesLib.Message.TICKET);
        MessageTypesLib.ReceiptMessage storage receipt = _receipts[ticketType][ticketId];
        return answered[ticketType][ticketId] && receipt.answer == MessageTypesLib.ReceiptAnswer.Executed;
    }

    /// @inheritdoc IERC7786Recipient
    function receiveMessage(bytes32 receiveId, bytes calldata sender, bytes calldata payload)
        external
        payable
        returns (bytes4)
    {
        require(msg.sender == address(gateway), NotTheGateway(msg.sender));
        if (receiveId != bytes32(0)) {
            require(!delivered[receiveId], AlreadyDelivered(receiveId));
            delivered[receiveId] = true;
        }
        bytes memory homeToken = InteroperableAddress.formatEvmV1(gateway.originChainId(), referenceToken);
        require(keccak256(sender) == keccak256(homeToken), NotTheReferenceToken(sender));

        (uint8 messageType, uint8 messageVersion, bytes memory body) = abi.decode(payload, (uint8, uint8, bytes));
        require(messageVersion == MessageTypesLib.VERSION, ErrorsLib.UnsupportedMessageVersion(messageVersion));
        if (messageType == uint8(MessageTypesLib.Message.TICKET)) {
            _receiveTicket(MessageTypesLib.decodeValidation(body));
        } else if (messageType == uint8(MessageTypesLib.Message.MOVE_OUT)) {
            _moveOut(MessageTypesLib.decodeMintInstruction(body));
        } else if (messageType == uint8(MessageTypesLib.Message.BRING_HOME)) {
            _bringHome(MessageTypesLib.decodeBringHome(body));
        } else {
            revert UnexpectedMessage(messageType);
        }
        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice The holder executes `ticketId` for `amount`: the sender, or the named spender within its allowance.
    function execute(bytes32 ticketId, uint256 amount) external {
        require(known[ticketId], UnknownTicket(ticketId));
        MessageTypesLib.TicketMessage storage ticket = _tickets[ticketId];
        require(block.timestamp < ticket.validUntil, ValidationExpired(ticketId));
        require(!answered[uint8(MessageTypesLib.Message.TICKET)][ticketId], ValidationConsumed(ticketId));
        require(ticket.amountMin <= amount && amount <= ticket.amountMax, AmountOutOfRange(ticketId, amount));
        _spendAsExecutor(ticket, ticketId, amount);

        _debit(ticket.from, amount);
        bool receiverOnThisChain = _isOnThisChain(ticket.to);
        if (receiverOnThisChain) _balances[keccak256(ticket.to)] += amount;
        if (!receiverOnThisChain) burns += amount;

        _answer(
            uint8(MessageTypesLib.Message.TICKET),
            ticketId,
            _ticketReceipt(ticket, amount, MessageTypesLib.ReceiptAnswer.Executed)
        );
    }

    /// @notice Sends the stored receipt of one half of one message type again, byte for byte, for anyone: at most
    ///  `MAX_RECEIPT_RESENDS` times, each one `receiptResendWait` after the half's last send.
    function resendReceipt(uint8 messageType, bytes32 halfKey) external {
        require(answered[messageType][halfKey], NoStoredReceipt(messageType, halfKey));
        ReceiptSends storage sends = receiptSends[messageType][halfKey];
        require(sends.resendsSent < MAX_RECEIPT_RESENDS, NoReceiptResendLeft(messageType, halfKey));
        uint64 resendAllowedAt = sends.lastSentAt + receiptResendWait;
        require(block.timestamp >= resendAllowedAt, ReceiptResendTooSoon(messageType, halfKey, resendAllowedAt));

        sends.resendsSent += 1;
        _send(messageType, halfKey, _receipts[messageType][halfKey]);
    }

    /// @notice The id of a ticket's terms, as home builds it, see {TicketLib-ticketIdOf}, under the copy's own kind.
    function idOfTheTerms(MessageTypesLib.TicketMessage memory copy) public pure returns (bytes32) {
        return TicketLib.ticketIdOf(
            ITickets.TicketKind(copy.kind),
            WalletKeyLib.canonicalKey(copy.from),
            WalletKeyLib.canonicalKey(copy.to),
            TicketLib.spenderKeyOf(copy.spender),
            copy.amountMin,
            copy.requestedMax,
            copy.salt
        );
    }

    /* ----- Private ----- */

    /// @dev Rule 3. A copy too far ahead is ignored. The first copy is held and never answered before its valid
    ///  until; one that arrives at or after it is answered with a stored zero receipt. A later copy is an ask for the
    ///  receipt: the stored receipt, a stored zero receipt once valid until passed, or a still open answer before.
    function _receiveTicket(MessageTypesLib.TicketMessage memory copy) private {
        bytes32 ticketId = copy.ticketId;
        uint8 ticketType = uint8(MessageTypesLib.Message.TICKET);
        bool tooFarAhead = copy.validUntil > block.timestamp && copy.validUntil - block.timestamp > validUntilBound;
        if (tooFarAhead) return;
        bytes32 termsId = idOfTheTerms(copy);
        require(ticketId == termsId, TicketIdMismatch(ticketId, termsId));

        if (!known[ticketId]) {
            _tickets[ticketId] = copy;
            known[ticketId] = true;
            if (block.timestamp >= copy.validUntil) _answerExpired(ticketId);
            return;
        }

        if (answered[ticketType][ticketId]) {
            if (_mayAnswer(ticketType, ticketId)) _send(ticketType, ticketId, _receipts[ticketType][ticketId]);
            return;
        }
        MessageTypesLib.TicketMessage storage firstCopy = _tickets[ticketId];
        if (block.timestamp >= firstCopy.validUntil) {
            _answerExpired(ticketId);
            return;
        }
        // Not counted: home gives its ask back on each still open answer, so it must hear every one.
        _send(ticketType, ticketId, _ticketReceipt(firstCopy, 0, MessageTypesLib.ReceiptAnswer.StillOpen));
    }

    /// @dev Rule 9: mints once per `(MOVE_OUT, halfKey)`, strictly before the half's valid until.
    function _moveOut(MessageTypesLib.MoveOutMessage memory moveOut) private {
        uint8 moveOutType = uint8(MessageTypesLib.Message.MOVE_OUT);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(moveOut.ticketId, moveOut.half);
        if (answered[moveOutType][halfKey]) {
            if (_mayAnswer(moveOutType, halfKey)) _send(moveOutType, halfKey, _receipts[moveOutType][halfKey]);
            return;
        }
        uint256 minted;
        MessageTypesLib.ReceiptAnswer answer = MessageTypesLib.ReceiptAnswer.Expired;
        if (block.timestamp < moveOut.validUntil) {
            minted = moveOut.amount;
            answer = MessageTypesLib.ReceiptAnswer.Executed;
            _balances[keccak256(moveOut.toWallet)] += minted;
            mints += minted;
        }
        _answer(
            moveOutType, halfKey, _halfReceipt(moveOut.ticketId, moveOut.half, "", moveOut.toWallet, minted, answer)
        );
    }

    /// @dev Rule 10: burns `min(amount, balance)` once per `(BRING_HOME, halfKey)`, strictly before the half's valid
    ///  until.
    function _bringHome(MessageTypesLib.BringHomeMessage memory bringHome) private {
        uint8 bringHomeType = uint8(MessageTypesLib.Message.BRING_HOME);
        bytes32 halfKey = MessageTypesLib.halfKeyOf(bringHome.ticketId, bringHome.half);
        if (answered[bringHomeType][halfKey]) {
            if (_mayAnswer(bringHomeType, halfKey)) _send(bringHomeType, halfKey, _receipts[bringHomeType][halfKey]);
            return;
        }
        uint256 burned;
        MessageTypesLib.ReceiptAnswer answer = MessageTypesLib.ReceiptAnswer.Expired;
        if (block.timestamp < bringHome.validUntil) {
            answer = MessageTypesLib.ReceiptAnswer.Executed;
            bytes32 walletKey = keccak256(bringHome.wallet);
            burned = bringHome.amount;
            if (_balances[walletKey] < burned) burned = _balances[walletKey];
            _balances[walletKey] -= burned;
            burns += burned;
        }
        _answer(
            bringHomeType,
            halfKey,
            _halfReceipt(bringHome.ticketId, bringHome.half, bringHome.wallet, "", burned, answer)
        );
    }

    function _answerExpired(bytes32 ticketId) private {
        _answer(
            uint8(MessageTypesLib.Message.TICKET),
            ticketId,
            _ticketReceipt(_tickets[ticketId], 0, MessageTypesLib.ReceiptAnswer.Expired)
        );
    }

    /// @dev Rule 7: stores the receipt under its message type and half key, and sends it.
    function _answer(uint8 messageType, bytes32 halfKey, MessageTypesLib.ReceiptMessage memory receipt) private {
        _receipts[messageType][halfKey] = receipt;
        answered[messageType][halfKey] = true;
        _send(messageType, halfKey, receipt);
    }

    /// @dev Counts an answer that sends a stored receipt again, to a later copy or a repeated half, in the half's
    ///  current answer window; a window that ended starts a new one at this answer. Past `MAX_ANSWERS_PER_WINDOW`
    ///  nothing is sent, and the delivery is consumed.
    function _mayAnswer(uint8 messageType, bytes32 halfKey) private returns (bool) {
        ReceiptSends storage sends = receiptSends[messageType][halfKey];
        bool windowEnded = block.timestamp >= sends.answerWindowStartedAt + answerWindow;
        if (windowEnded) {
            sends.answerWindowStartedAt = uint64(block.timestamp);
            sends.answersInWindow = 0;
        }
        if (sends.answersInWindow >= MAX_ANSWERS_PER_WINDOW) {
            emit AnswerNotSent(messageType, halfKey);
            return false;
        }
        sends.answersInWindow += 1;
        return true;
    }

    /// @dev A first-half receipt names both wallets and echoes the copy held.
    function _ticketReceipt(
        MessageTypesLib.TicketMessage storage heldCopy,
        uint256 amount,
        MessageTypesLib.ReceiptAnswer answer
    ) private view returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.ReceiptMessage({
            ticketId: heldCopy.ticketId,
            from: heldCopy.from,
            to: heldCopy.to,
            amount: amount,
            askBlockHash: heldCopy.askBlockHash,
            seenMax: heldCopy.amountMax,
            seenValidUntil: heldCopy.validUntil,
            half: 0,
            answer: answer
        });
    }

    /// @dev A second-half receipt carries no ticket fields: a move out names only the minted wallet, a bring home
    ///  only the burned one.
    function _halfReceipt(
        bytes32 ticketId,
        uint8 half,
        bytes memory from,
        bytes memory to,
        uint256 amount,
        MessageTypesLib.ReceiptAnswer answer
    ) private pure returns (MessageTypesLib.ReceiptMessage memory) {
        return MessageTypesLib.ReceiptMessage({
            ticketId: ticketId,
            from: from,
            to: to,
            amount: amount,
            askBlockHash: bytes32(0),
            seenMax: 0,
            seenValidUntil: 0,
            half: half,
            answer: answer
        });
    }

    /// @dev Sends a receipt for `(messageType, halfKey)` and notes when, for the wait of {resendReceipt}.
    function _send(uint8 messageType, bytes32 halfKey, MessageTypesLib.ReceiptMessage memory receipt) private {
        receiptSends[messageType][halfKey].lastSentAt = uint64(block.timestamp);
        gateway.sendMessage(
            InteroperableAddress.formatEvmV1(block.chainid, referenceToken),
            MessageTypesLib.encodeSettlement(receipt),
            new bytes[](0)
        );
    }

    function _debit(bytes memory wallet, uint256 amount) private {
        bytes32 walletKey = keccak256(wallet);
        require(amount <= _balances[walletKey], InsufficientBalance(wallet, _balances[walletKey], amount));
        _balances[walletKey] -= amount;
    }

    /// @dev Rule 6: the sender itself, or the named spender, which spends the sender's allowance.
    function _spendAsExecutor(MessageTypesLib.TicketMessage storage ticket, bytes32 ticketId, uint256 amount) private {
        (,, bytes memory fromAddress) = InteroperableAddress.parseV1(ticket.from);
        if (address(bytes20(fromAddress)) == msg.sender) return;
        require(ticket.spender.length != 0, NotTheExecutor(ticketId, msg.sender));
        (,, bytes memory spenderAddress) = InteroperableAddress.parseV1(ticket.spender);
        require(address(bytes20(spenderAddress)) == msg.sender, NotTheExecutor(ticketId, msg.sender));
        bytes32 fromKey = keccak256(ticket.from);
        uint256 allowance = allowances[fromKey][msg.sender];
        require(amount <= allowance, AllowanceTooLow(ticketId, allowance, amount));
        allowances[fromKey][msg.sender] = allowance - amount;
    }

    function _isOnThisChain(bytes memory wallet) private view returns (bool) {
        (bool isEvm, uint256 walletChainId,) = InteroperableAddress.tryParseEvmV1(wallet);
        return isEvm && walletChainId == chainId;
    }

    function _walletKeyOf(address wallet) private view returns (bytes32) {
        return keccak256(InteroperableAddress.formatEvmV1(chainId, wallet));
    }

}

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
    /// @dev The token's pause, which refuses issuance and resends. Running unless a test pauses it.
    bool public paused;

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBridgedBalance(bytes calldata wallet, uint256 amount) external {
        bridged[keccak256(wallet)] = amount;
    }

    function awayBalanceOf(bytes calldata wallet) external view returns (uint256) {
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

    function reserveForTicket(bytes calldata wallet, uint256 amount) external {
        reserved[keccak256(wallet)] += amount;
    }

    function releaseFromTicket(bytes calldata wallet, uint256 amount) external {
        bytes32 key = keccak256(wallet);
        uint256 held = reserved[key];
        reserved[key] = held < amount ? 0 : held - amount;
    }

    /// @dev Money on hold per ticket: what left the wallet between two halves of a move.
    mapping(bytes32 ticketId => uint256) public onHoldOf;
    /// @dev When a hostile change of each away chain's peer ends; zero for a chain never replaced.
    mapping(bytes32 chainKey => uint64) public hostileChangeEndsAt;
    /// @dev The ticket bridge each away chain's tickets go out on; zero when it has none.
    mapping(bytes32 chainKey => address) public ticketRouteFor;
    /// @dev How many messages went out on the receipt route, and the last one, so a test can tell where a ticket went.
    uint256 public receiptRouteSends;
    bytes32 public lastReceiptRouteChainKey;
    bytes32 public lastReceiptRouteHalfKey;

    function setHostileChangeEndsAt(bytes32 chainKey, uint64 endsAt) external {
        hostileChangeEndsAt[chainKey] = endsAt;
    }

    function setTicketRoute(bytes32 chainKey, address bridge) external {
        ticketRouteFor[chainKey] = bridge;
    }

    /// @dev The first half landed: the wallet no longer holds the amount, the ticket does.
    function putOnHold(bytes calldata wallet, uint256 amount, bytes32 ticketId) external {
        bridged[keccak256(wallet)] -= amount;
        onHoldOf[ticketId] += amount;
    }

    /// @dev What each ticket's applied receipt moved, as the token's `finishMove` would record it.
    mapping(bytes32 ticketId => uint256) public finishedOf;

    /// @dev A receipt applied: what left `from`, or its money on hold, reaches `to`; only the amount is recorded,
    ///  since the unit tests check the compliance's side and read the call's arguments with `expectCall`.
    function finishMove(bytes calldata, bytes calldata, uint256 amount, bytes32 ticketId) external {
        finishedOf[ticketId] += amount;
    }

    /// @dev A message on the receipt route, recorded; nothing is delivered.
    function sendOnReceiptRoute(bytes32 chainKey, bytes32 halfKey, uint8, bytes calldata) external returns (bytes32) {
        receiptRouteSends += 1;
        lastReceiptRouteChainKey = chainKey;
        lastReceiptRouteHalfKey = halfKey;
        return bytes32(receiptRouteSends);
    }

}

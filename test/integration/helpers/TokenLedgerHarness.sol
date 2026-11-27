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

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { WalletKeyLib } from "contracts/libraries/WalletKeyLib.sol";
import { Token } from "contracts/token/Token.sol";
import { TokenLedgerLib } from "contracts/token/TokenLedgerLib.sol";

/// @title TokenLedgerHarness
/// @notice Exposes the token's internal ledger transitions so tests can drive them before any flow references
///         them. Every entry point authorizes against the mint role, so the existing agent drives them all.
///         Settlements go through `Token._settle`, the same path `finishMove` takes in production, with
///         only the bound-compliance and pause checks skipped.
contract TokenLedgerHarness is Token {

    /// @dev The batch-authorization shape the ERC-3643 base reaches through `_checkTokenAdmin`, restated
    ///  here as a modifier so each entry point authorizes against the mint role rather than its own selector.
    modifier restrictedFor(bytes4 selector) {
        _checkCanCallSelector(selector);
        _;
    }

    /// @dev The ledger of a home wallet's move out, its receipt landed: `holder`'s native tokens are burned onto
    ///  hold, then the hold lands on `toWallet`, as `burnOntoHold` and `finishMove` do, with none of the checks the
    ///  compliance adds (ask, rules, linked wallets, the away chain's receipt). The hold is drained in this call, so
    ///  its id may be reused.
    function ledgerMoveOut(address holder, bytes calldata toWallet, uint256 amount)
        external
        restrictedFor(this.mint.selector)
    {
        require(holder != address(0), ErrorsLib.ZeroAddress());
        WalletKeyLib.satelliteKey(toWallet);
        uint256 freeBalance = freeBalanceOf(holder);
        require(amount <= freeBalance, IERC20Errors.ERC20InsufficientBalance(holder, freeBalance, amount));
        bytes memory homeWallet = InteroperableAddress.formatEvmV1(block.chainid, holder);
        bytes32 holdId = keccak256(abi.encode("ledger move out", holder, toWallet));
        this.moveOutSelf(homeWallet, toWallet, amount, holdId);
    }

    /// @dev The ledger of a bring home, its receipt landed: `fromWallet`'s away tokens are put on hold, then the hold
    ///  is minted to `holder`, as `putOnHold` and `finishMove` do, with none of the checks the compliance adds.
    function ledgerBringHome(bytes calldata fromWallet, address holder, uint256 amount)
        external
        restrictedFor(this.mint.selector)
    {
        require(holder != address(0), ErrorsLib.ZeroAddress());
        bytes32 holdId = keccak256(abi.encode("ledger bring home", fromWallet, holder));
        TokenLedgerLib.putOnHold(fromWallet, amount, holdId);
        this.settleSelf(fromWallet, InteroperableAddress.formatEvmV1(block.chainid, holder), amount, holdId);
    }

    /// @dev The second hop of {ledgerMoveOut}, so the home envelope reaches the ledger as calldata. Reachable from
    ///  this contract only.
    function moveOutSelf(bytes calldata homeWallet, bytes calldata toWallet, uint256 amount, bytes32 holdId) external {
        require(msg.sender == address(this), "TokenLedgerHarness: self-call only");
        address holder = TokenLedgerLib.holdFromHome(homeWallet, amount, holdId);
        ERC20Upgradeable._update(holder, address(0), amount);
        _settle(homeWallet, toWallet, amount, holdId);
    }

    function bridgedTransfer(bytes calldata from, bytes calldata to, uint256 amount, bytes32 ticketId)
        external
        restrictedFor(this.mint.selector)
    {
        _settle(from, to, amount, ticketId);
    }

    function settleToNative(bytes calldata fromWallet, address to, uint256 amount, bytes32 ticketId)
        external
        restrictedFor(this.mint.selector)
    {
        // Self-call so the freshly built native envelope reaches `_settle` as calldata, like every other one.
        this.settleSelf(fromWallet, InteroperableAddress.formatEvmV1(block.chainid, to), amount, ticketId);
    }

    /// @dev The second hop of {settleToNative}. Reachable from this contract only.
    function settleSelf(bytes calldata from, bytes calldata to, uint256 amount, bytes32 ticketId) external {
        require(msg.sender == address(this), "TokenLedgerHarness: self-call only");
        _settle(from, to, amount, ticketId);
    }

}

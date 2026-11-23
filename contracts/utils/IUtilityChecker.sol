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

// T-REX Smart Contracts
// The ERC-3643 token suite of the T-REX ecosystem.
//
// Copyright (C) 2023, Tokeny sàrl.
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite. It derives from the
// T-REX v4 smart contracts developed by Tokeny sàrl and released under the
// GNU General Public License v3. All modifications made since then are the
// work of Digital Asset Operational Services ISAC Ltd. ("T-REX Network").
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.30;

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";

interface IUtilityChecker {

    struct ComplianceCheckDetails {
        string moduleName;
        /// The largest amount the module allows for this movement, `type(uint256).max` for no limit.
        uint256 allowedAmount;
        /// Whether the requested amount is within it.
        bool pass;
    }

    struct EligibilityCheckDetails {
        IClaimIssuer issuer;
        uint256 topic;
        bool pass;
    }

    /// @dev Independent conditions for a native `transferFrom`; all must pass before execution is attempted.
    struct TransferFromStatus {
        /// The sender, recipient and spender are nonzero. A zero amount is supported.
        bool inputsValid;
        /// The token is unpaused, neither wallet is address-frozen, and the sender has enough free balance.
        bool freezeStatus;
        /// The recipient passes the token's identity registry.
        bool eligibilityStatus;
        /// Every RULE module permits the amount, with the actual spender in its context.
        bool complianceStatus;
        /// Every SPENDER module permits the spender.
        bool spenderStatus;
        /// The holder's allowance covers the amount, including unlimited allowance.
        bool allowanceStatus;
    }

    /// @dev Conditions checked before an authorized mint; pause and wallet freezes do not constrain a mint.
    struct MintStatus {
        /// The recipient is nonzero. A zero amount is supported.
        bool inputsValid;
        /// The recipient passes the token's identity registry.
        bool eligibilityStatus;
        /// Every RULE module permits this MINT context and amount.
        bool complianceStatus;
    }

    /// @dev Balance conditions and the automatic release of frozen tokens for an authorized burn.
    struct BurnStatus {
        /// The holder is nonzero. A zero amount is supported.
        bool inputsValid;
        /// The holder's total balance covers the amount, including its frozen tokens.
        bool balanceStatus;
        /// Frozen tokens the burn would release; zero for invalid inputs or insufficient total balance.
        uint256 unfreezeAmount;
    }

    /// @dev Checks freeze and free-balance conditions for ordinary transfers with nonzero sender and recipient.
    ///      Zero-side mint/burn inputs are outside this endpoint's scope; use `getMintStatus` or `getBurnStatus`.
    /// @param _token The address of the token contract.
    /// @param _from The address of the sender.
    /// @param _to The address of the recipient.
    /// @param _amount The amount of tokens to be transferred.
    /// @return _frozen bool Returns true if the transfer is affected by freeze conditions, false otherwise.
    /// @return _availableBalance uint256 Available unfreezed balance.
    function getFreezeStatus(address _token, address _from, address _to, uint256 _amount)
        external
        view
        returns (bool _frozen, uint256 _availableBalance);

    /// @dev Previews the listed conditions for an ordinary direct transfer:
    ///     - check if token is paused,
    ///     - check freeze conditions,
    ///     - check eligibilty,
    ///     - check compliance.
    ///      Spender policy and allowance are excluded; use `getTransferFromStatus` for delegated transfers.
    ///      Sender and recipient must be nonzero for this preview's ordinary-transfer interpretation; use
    ///      `getMintStatus` and `getBurnStatus` for issuance and redemption. This does not change legacy input handling.
    ///      Module and registry reverts propagate. Post-movement hooks and later state changes are not simulated,
    ///      so passing flags do not guarantee transaction success.
    /// @param _token The address of the token contract.
    /// @param _from The address of the sender.
    /// @param _to The address of the recipient.
    /// @param _amount The amount of tokens to be transferred.
    /// @return _freezeStatus bool
    ///      Returns true if the transfer would be successful according to pause/freeze conditions, false otherwise.
    /// @return _eligibilityStatus bool
    ///      Returns true if the transfer would be successful according to eligibilty conditions, false otherwise.
    /// @return _complianceStatus bool
    ///     Returns true if the transfer would be successful according to compliance conditions, false otherwise.
    function getTransferStatus(address _token, address _from, address _to, uint256 _amount)
        external
        view
        returns (bool _freezeStatus, bool _eligibilityStatus, bool _complianceStatus);

    /// @notice Previews the conditions for a native transfer made by an approved spender.
    /// @dev Uses the same resolved movement context for RULE and SPENDER modules as `Token.transferFrom`.
    ///      The token-only, state-changing `canSpenderCall` is not invoked. Module and registry reverts propagate.
    ///      These are independent condition flags, not an execution simulation: post-movement hooks and state
    ///      changes before execution can still reject the transaction. All flags are false for invalid inputs.
    /// @param _token The token whose current state is read.
    /// @param _spender The caller that will execute `transferFrom`.
    /// @param _from The holder whose tokens and allowance will be used.
    /// @param _to The recipient of the tokens.
    /// @param _amount The amount to transfer; zero follows the token's normal checks.
    /// @return _status Input, freeze, eligibility, rule, spender-policy and allowance results.
    function getTransferFromStatus(address _token, address _spender, address _from, address _to, uint256 _amount)
        external
        view
        returns (TransferFromStatus memory _status);

    /// @notice Previews recipient admission and compliance rules for an authorized mint.
    /// @dev Mints have no source balance and ignore pause and wallet freezes. Caller authorization, supply/balance
    ///      overflow and post-movement hooks are not simulated; passing flags do not guarantee execution. Registry
    ///      and module reverts propagate, and later state changes may alter the result. Invalid inputs return false flags.
    /// @param _token The token whose current state is read.
    /// @param _to The recipient of the newly issued tokens.
    /// @param _amount The amount to mint; zero follows the token's normal admission and rule checks.
    /// @return _status Nonzero-recipient, eligibility and MINT rule results.
    function getMintStatus(address _token, address _to, uint256 _amount)
        external
        view
        returns (MintStatus memory _status);

    /// @notice Previews a holder's total burnable balance and the frozen amount the burn would release.
    /// @dev Burns ignore pause, address freezes, recipient admission and RULE modules. Caller authorization and
    ///      post-movement hooks are not simulated; passing flags do not guarantee execution, and later state changes
    ///      may alter the result. Token-view reverts propagate. Invalid inputs return false flags and zero unfreeze.
    /// @param _token The token whose current state is read.
    /// @param _from The holder whose tokens will be destroyed.
    /// @param _amount The amount to burn; zero is supported.
    /// @return _status Nonzero-holder and total-balance results, with the automatic unfreeze amount when covered.
    function getBurnStatus(address _token, address _from, uint256 _amount)
        external
        view
        returns (BurnStatus memory _status);

    /// @dev Returns each RULE module's result for a direct transfer. While rules are bound, a sender that resolves
    ///      to no identity is refused before any rule is asked, so every row then fails and allows zero. Recipient
    ///      admission is checked separately by the token's identity registry, not by these rule rows.
    /// @param _token The address of the token contract.
    /// @param _from Address of the sender.
    /// @param _to Address of the receiver.
    /// @param _value Amount of tokens to transfer.
    /// @return _details Array of struct with module name, the amount it allows and whether the value fits.
    function getTransferDetails(address _token, address _from, address _to, uint256 _value)
        external
        view
        returns (ComplianceCheckDetails[] memory _details);

    /// @dev This functions checks whether an identity contract corresponding to the provided user address has the required
    ///      claims or not based on the data fetched from trusted issuers registry and from the claim topics registry. It
    ///      returns the details of each (issuer, topic).
    /// @param _token Address of the token contract.
    /// @param _userAddress Address of the user to be verified.
    /// @return _details Array of struct with issuer, topic, and the verified status.
    function getVerifiedDetails(address _token, address _userAddress)
        external
        view
        returns (EligibilityCheckDetails[] memory _details, IIdentityFactory.AccountStatus _walletStatus);

}

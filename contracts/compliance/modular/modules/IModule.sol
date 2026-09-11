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
/**
 *     NOTICE
 *
 *     The T-REX software is licensed under a proprietary license or the GPL v.3.
 *     If you choose to receive it under the GPL v.3 license, the following applies:
 *     T-REX is a suite of smart contracts implementing the ERC-3643 standard and
 *     developed by Tokeny to manage and transfer financial assets on EVM blockchains
 *
 *     Copyright (C) 2025, Tokeny sàrl.
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma solidity 0.8.30;

interface IModule {

    /// functions
    /**
     *  @dev binds the module to a compliance contract
     *  once the module is bound, the compliance contract can interact with the module
     *  this function can be called ONLY by the compliance contract itself (_compliance), through the
     *  addModule function, which calls bindCompliance
     *  the module cannot be already bound to the compliance
     *  @param _compliance address of the compliance contract
     *  Emits a ComplianceBound event
     */
    function bindCompliance(address _compliance) external;

    /**
     *  @dev unbinds the module from a compliance contract
     *  once the module is unbound, the compliance contract cannot interact with the module anymore
     *  this function can be called ONLY by the compliance contract itself (_compliance), through the
     *  removeModule function, which calls unbindCompliance
     *  @param _compliance address of the compliance contract
     *  Emits a ComplianceUnbound event
     */
    function unbindCompliance(address _compliance) external;

    /**
     *  @dev action performed on the module during a transfer action
     *  this function is used to update variables of the module upon transfer if it is required
     *  if the module does not require state updates in case of transfer, this function remains empty
     *  This function can be called ONLY by the compliance contract itself (_compliance)
     *  This function can be called only on a compliance contract that is bound to the module
     *  @param _from address of the transfer sender
     *  @param _to address of the transfer receiver
     *  @param _value amount of tokens sent
     */
    function moduleTransferAction(address _from, address _to, uint256 _value) external;

    /**
     *  @dev action performed on the module during a mint action
     *  this function is used to update variables of the module upon minting if it is required
     *  if the module does not require state updates in case of mint, this function remains empty
     *  This function can be called ONLY by the compliance contract itself (_compliance)
     *  This function can be called only on a compliance contract that is bound to the module
     *  @param _to address used for minting
     *  @param _value amount of tokens minted
     */
    function moduleMintAction(address _to, uint256 _value) external;

    /**
     *  @dev action performed on the module during a burn action
     *  this function is used to update variables of the module upon burning if it is required
     *  if the module does not require state updates in case of burn, this function remains empty
     *  This function can be called ONLY by the compliance contract itself (_compliance)
     *  This function can be called only on a compliance contract that is bound to the module
     *  @param _from address on which tokens are burnt
     *  @param _value amount of tokens burnt
     */
    function moduleBurnAction(address _from, uint256 _value) external;

    /**
     *  @dev compliance check on the module for a specific transaction on a specific compliance contract
     *  this function is used to check if the transfer is allowed by the module
     *  This function can be called only on a compliance contract that is bound to the module
     *  @param _from address of the transfer sender
     *  @param _to address of the transfer receiver
     *  @param _value amount of tokens sent
     *  @param _compliance address of the compliance contract concerned by the transfer action
     *  the function returns TRUE if the module allows the transfer, FALSE otherwise
     */
    function moduleCheck(address _from, address _to, uint256 _value, address _compliance) external view returns (bool);

    /**
     *  @dev spender side compliance check on the module for a specific transaction
     *  this function is used to check if the spender is allowed to move the tokens of another party
     *  This function can be called only on a compliance contract that is bound to the module
     *  modules with no rule to enforce on the spender leave the default implementation in place
     *  @param _spender address initiating the transfer on behalf of `_from`
     *  @param _from address of the transfer sender
     *  @param _to address of the transfer receiver
     *  @param _value amount of tokens sent
     *  @param _compliance address of the compliance contract concerned by the transfer action
     *  the function returns TRUE if the module allows the spender to call, FALSE otherwise
     */
    function moduleCheckSpender(address _spender, address _from, address _to, uint256 _value, address _compliance)
        external
        view
        returns (bool);

    /**
     *  @dev narrows the amount range of a compliance validation for a satellite movement
     *  called only when the module declares `BOUNDS`; receives the running range, already capped at `_from`'s
     *  balance and narrowed by the modules before it, and must answer a range inside it (the compliance intersects
     *  the answer anyway). Additive rules evaluate at `_currentMax`, retention rules at `_currentMin`; a module may
     *  narrow to a point or revert to refuse
     *  This function can be called only on a compliance contract that is bound to the module
     *  @param _from ERC-7930 interoperable address of the sender
     *  @param _to ERC-7930 interoperable address of the recipient
     *  @param _currentMin inclusive lower bound of the running range
     *  @param _currentMax inclusive upper bound of the running range
     *  @param _compliance address of the compliance contract issuing the validation
     *  @return min the narrowed inclusive lower bound
     *  @return max the narrowed inclusive upper bound
     */
    function validationBounds(
        bytes calldata _from,
        bytes calldata _to,
        uint256 _currentMin,
        uint256 _currentMax,
        address _compliance
    ) external view returns (uint256 min, uint256 max);

    /**
     *  @dev reserves the compliance slot of a validation being issued
     *  called only when the module declares `SLOTS`, right after the validation is recorded; the module counts
     *  the movement as executed at `_amountMax`, the worst case for any additive rule, so that a concurrent
     *  validation is narrowed by `validationBounds` as if this one had already settled. A module that cannot
     *  express its worst case at `_amountMax` pins the bounds in `validationBounds` so that min equals max
     *  This function can be called ONLY by the compliance contract itself (_compliance)
     *  @param _validationId id of the validation being issued
     *  @param _from ERC-7930 interoperable address of the sender
     *  @param _to ERC-7930 interoperable address of the recipient
     *  @param _amountMax inclusive upper bound of the issued range
     */
    function reserveSlot(uint256 _validationId, bytes calldata _from, bytes calldata _to, uint256 _amountMax) external;

    /**
     *  @dev reconciles the module's counters to the exact amount a validation executed
     *  called only when the module declares `SLOTS`, when the validation settles; the reservation taken at
     *  `_amountMax`, if any, is replaced by `_executedAmount`. MUST tolerate an id it never reserved (a module
     *  bound after issuance, or a late reconciliation after `releaseSlot`) by applying the delta anyway, so every
     *  subsequent compliance decision sees the true state; a resulting breach stands, it is never hidden
     *  This function can be called ONLY by the compliance contract itself (_compliance)
     *  @param _validationId id of the settled validation
     *  @param _executedAmount exact amount transferred, inside the issued range
     */
    function commitSlot(uint256 _validationId, uint256 _executedAmount) external;

    /**
     *  @dev undoes the reservation of a validation entirely
     *  called only when the module declares `SLOTS`, when the keeper discards an expired validation. MUST
     *  tolerate an id it never reserved
     *  This function can be called ONLY by the compliance contract itself (_compliance)
     *  @param _validationId id of the discarded validation
     */
    function releaseSlot(uint256 _validationId) external;

    /**
     *  @dev getter for the dispatch points this module implements
     *  the returned value is a bitmask built from the flags of `ModuleCapabilitiesLib`
     *  the compliance reads it once, at binding time, and never calls a dispatch point whose flag is absent
     *  MUST be pure: a value read from storage would let the recorded routing drift from the real behaviour
     *  a module returning zero, or a value carrying an undefined bit, cannot be bound
     *  @return the bitmask of the dispatch points the module implements
     */
    function moduleCapabilities() external pure returns (uint256);

    /**
     *  @dev getter for compliance binding status on module
     *  @param _compliance address of the compliance contract
     */
    function isComplianceBound(address _compliance) external view returns (bool);

    /**
     *  @dev checks whether compliance is suitable to bind to the module.
     *  @param _compliance address of the compliance contract
     */
    function canComplianceBind(address _compliance) external view returns (bool);

    /**
     *  @dev getter for module plug & play status
     */
    function isPlugAndPlay() external pure returns (bool);

    /**
     *  @dev getter for the name of the module
     *  @return _name the name of the module
     */
    function name() external pure returns (string memory _name);

}

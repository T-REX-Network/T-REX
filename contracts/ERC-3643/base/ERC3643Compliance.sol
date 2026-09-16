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

import { IERC3643Compliance } from "../IERC3643Compliance.sol";

/// @title ERC3643Compliance
/// @notice Standard-only base implementing the ERC-3643 Compliance surface.
/// @dev Layer 2 of the ERC-3643 / T-REX split (see issue #65). Implements exactly the functions
///  `IERC3643Compliance` declares, over state held in its own ERC-7201 namespace.
///
///  The base owns the token binding and the four dispatch points, and nothing else. It has no notion of
///  modules: `canTransfer` returns true and the three notification hooks do nothing, because a compliance
///  with no rules is compliant. Extensions supply the rules by overriding the internal `_canTransfer`,
///  `_transferred`, `_created` and `_destroyed` hooks, which is where T-REX plugs its module dispatch in.
///
///  `onlyBoundToken` guards the three notification entry points: they mutate rule state, so only the bound
///  token may call them. `canTransfer` is a view and stays open.
abstract contract ERC3643Compliance is IERC3643Compliance {

    /// @custom:storage-location erc7201:erc3643.storage.Compliance
    struct ERC3643ComplianceStorage {
        address tokenBound;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.Compliance")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant COMPLIANCE_STORAGE_LOCATION =
        0x9a630f7fb5b68c9ca32ffeadfd0de30d50c23b603074e205ad3eb7046278f900;

    /// @dev Thrown when a required address argument is the zero address.
    error ComplianceZeroAddress();

    /// @dev Thrown when a notification hook is called by anything other than the bound token.
    error AddressNotATokenBoundToComplianceContract();

    /// @dev Thrown when unbinding a token that is not the bound one.
    error TokenNotBound();

    /// @dev Thrown when a notification hook is called with a zero amount.
    error ComplianceZeroValue();

    /// @dev Restricts a function to the token currently bound to this compliance.
    modifier onlyBoundToken() {
        require(msg.sender == _erc3643ComplianceStorage().tokenBound, AddressNotATokenBoundToComplianceContract());
        _;
    }

    /// @inheritdoc IERC3643Compliance
    function bindToken(address _token) external virtual {
        _authorizeTokenBinding(_token);
        _bindToken(_token);
    }

    /// @inheritdoc IERC3643Compliance
    function unbindToken(address _token) external virtual {
        _authorizeTokenBinding(_token);
        _unbindToken(_token);
    }

    /// @inheritdoc IERC3643Compliance
    function transferred(address _from, address _to, uint256 _amount) external virtual onlyBoundToken {
        require(_from != address(0) && _to != address(0), ComplianceZeroAddress());
        require(_amount > 0, ComplianceZeroValue());
        _transferred(_from, _to, _amount);
    }

    /// @inheritdoc IERC3643Compliance
    function created(address _to, uint256 _amount) external virtual onlyBoundToken {
        require(_to != address(0), ComplianceZeroAddress());
        require(_amount > 0, ComplianceZeroValue());
        _created(_to, _amount);
    }

    /// @inheritdoc IERC3643Compliance
    function destroyed(address _from, uint256 _amount) external virtual onlyBoundToken {
        require(_from != address(0), ComplianceZeroAddress());
        require(_amount > 0, ComplianceZeroValue());
        _destroyed(_from, _amount);
    }

    /// @inheritdoc IERC3643Compliance
    function canTransfer(address _from, address _to, uint256 _amount) external view virtual returns (bool) {
        return _canTransfer(_from, _to, _amount);
    }

    /// @inheritdoc IERC3643Compliance
    function isTokenBound(address _token) external view virtual returns (bool) {
        return _token == _erc3643ComplianceStorage().tokenBound;
    }

    /// @inheritdoc IERC3643Compliance
    function getTokenBound() external view virtual returns (address) {
        return _getTokenBound();
    }

    /// @dev Authorization hook for binding and unbinding. Receives the token address so derived
    ///  contracts can apply the "the token may bind itself once, the owner may always bind" policy.
    ///  Left abstract on purpose: the standard specifies no access model.
    function _authorizeTokenBinding(address token) internal virtual;

    /// @dev Records the bound token. No caller check; `_authorizeTokenBinding` covers the public path.
    function _bindToken(address token) internal virtual {
        require(token != address(0), ComplianceZeroAddress());
        _erc3643ComplianceStorage().tokenBound = token;
        emit TokenBound(token);
    }

    /// @dev Clears the bound token.
    function _unbindToken(address token) internal virtual {
        require(token != address(0), ComplianceZeroAddress());
        ERC3643ComplianceStorage storage s = _erc3643ComplianceStorage();
        require(token == s.tokenBound, TokenNotBound());
        delete s.tokenBound;
        emit TokenUnbound(token);
    }

    /// @dev Rule state update after a transfer. A compliance with no rules has nothing to record.
    // solhint-disable-next-line no-empty-blocks
    function _transferred(
        address,
        /* from */
        address,
        /* to */
        uint256 /* amount */
    )
        internal
        virtual { }

    /// @dev Rule state update after a mint.
    // solhint-disable-next-line no-empty-blocks
    function _created(
        address,
        /* to */
        uint256 /* amount */
    )
        internal
        virtual { }

    /// @dev Rule state update after a burn.
    // solhint-disable-next-line no-empty-blocks
    function _destroyed(
        address,
        /* from */
        uint256 /* amount */
    )
        internal
        virtual { }

    /// @dev Whether a transfer is allowed. A compliance with no rules allows everything; extensions
    ///  override this to consult their rules.
    function _canTransfer(
        address,
        /* from */
        address,
        /* to */
        uint256 /* amount */
    )
        internal
        view
        virtual
        returns (bool)
    {
        return true;
    }

    /// @dev The token bound to this compliance, if any.
    function _getTokenBound() internal view virtual returns (address) {
        return _erc3643ComplianceStorage().tokenBound;
    }

    function _erc3643ComplianceStorage() internal pure returns (ERC3643ComplianceStorage storage s) {
        assembly ("memory-safe") {
            s.slot := COMPLIANCE_STORAGE_LOCATION
        }
    }

}

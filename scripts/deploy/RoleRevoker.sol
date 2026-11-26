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

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title RoleRevoker
/// @notice Deployment tooling (unaudited): holds ROLE_MANAGER on the Platform AccessManager with no execution delay
///         and can only revoke. Whoever holds Platform ADMIN calls it to cut off a compromised operator at once,
///         while the Protocol Admin Safe's own ROLE_MANAGER sits behind the power delay. A grant (for example the
///         Safe granting itself INTEROP_MANAGER) is then scheduled in plain view, as OpenZeppelin's review asks.
/// @dev Authorisation reads Platform ADMIN live, whatever its execution delay, so revocation follows ADMIN to a new
///      Safe without redeploying. The manager itself limits what can be revoked: only roles whose admin is
///      ROLE_MANAGER (the operational roles), never ADMIN, ROLE_MANAGER, GUARDIAN or VERSION_MANAGER. No state,
///      no grant, no upgrade.
contract RoleRevoker {

    uint64 internal constant ADMIN_ROLE = 0;

    IAccessManager public immutable manager;

    error RoleRevokerUnauthorized(address caller);

    constructor(IAccessManager manager_) {
        manager = manager_;
    }

    /// @notice Revokes `role` from `account`, effective in this transaction.
    function revokeRole(uint64 role, address account) external {
        _requireAdmin();
        manager.revokeRole(role, account);
    }

    /// @notice Revokes every role in `roles` from `account` in one transaction.
    function revokeRoles(uint64[] calldata roles, address account) external {
        _requireAdmin();
        for (uint256 i = 0; i < roles.length; i++) {
            manager.revokeRole(roles[i], account);
        }
    }

    function _requireAdmin() internal view {
        (bool isAdmin,) = manager.hasRole(ADMIN_ROLE, msg.sender);
        if (!isAdmin) revert RoleRevokerUnauthorized(msg.sender);
    }

}

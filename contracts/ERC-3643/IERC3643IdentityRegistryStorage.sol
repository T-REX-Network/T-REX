// SPDX-License-Identifier: CC0-1.0
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

interface IERC3643IdentityRegistryStorage {

    /// @dev Emitted when an identity is registered into the storage contract.
    /// @param _investorAddress The address of the investor's wallet.
    /// @param _identity The address of the investor's ONCHAINID.
    event IdentityStored(address indexed _investorAddress, IIdentity indexed _identity);

    /// @dev Emitted when an identity is removed from the storage contract.
    /// @param _investorAddress The address of the investor's wallet.
    /// @param _identity The address of the investor's ONCHAINID.
    event IdentityUnstored(address indexed _investorAddress, IIdentity indexed _identity);

    /// @dev Emitted when an identity contract is replaced in the storage contract.
    /// @param _oldIdentity The old ONCHAINID address.
    /// @param _newIdentity The new ONCHAINID address.
    event IdentityModified(IIdentity indexed _oldIdentity, IIdentity indexed _newIdentity);

    /// @dev Emitted when an investor's country is updated in the storage contract.
    /// @param _investorAddress The address of the investor's wallet.
    /// @param _country The investor's new country code (ISO-3166).
    event CountryModified(address indexed _investorAddress, uint16 indexed _country);

    /// @dev Emitted when an Identity Registry is bound to the storage contract.
    /// @param _identityRegistry The address of the bound Identity Registry.
    event IdentityRegistryBound(address indexed _identityRegistry);

    /// @dev Emitted when an Identity Registry is unbound from the storage contract.
    /// @param _identityRegistry The address of the unbound Identity Registry.
    event IdentityRegistryUnbound(address indexed _identityRegistry);

    /// functions
    /**
     *  @dev adds an identity contract corresponding to a user address in the storage.
     *  Requires that the user doesn't have an identity contract already registered.
     *  This function can only be called by an address set as agent of the smart contract
     *  @param _userAddress The address of the user
     *  @param _identity The address of the user's identity contract
     *  @param _country The country of the investor
     *  emits `IdentityStored` event
     */
    function addIdentityToStorage(address _userAddress, IIdentity _identity, uint16 _country) external;

    /**
     *  @dev Removes an user from the storage.
     *  Requires that the user have an identity contract already deployed that will be deleted.
     *  This function can only be called by an address set as agent of the smart contract
     *  @param _userAddress The address of the user to be removed
     *  emits `IdentityUnstored` event
     */
    function removeIdentityFromStorage(address _userAddress) external;

    /**
     *  @dev Updates the country corresponding to a user address.
     *  Requires that the user should have an identity contract already deployed that will be replaced.
     *  This function can only be called by an address set as agent of the smart contract
     *  @param _userAddress The address of the user
     *  @param _country The new country of the user
     *  emits `CountryModified` event
     */
    function modifyStoredInvestorCountry(address _userAddress, uint16 _country) external;

    /**
     *  @dev Updates an identity contract corresponding to a user address.
     *  Requires that the user address should be the owner of the identity contract.
     *  Requires that the user should have an identity contract already deployed that will be replaced.
     *  This function can only be called by an address set as agent of the smart contract
     *  @param _userAddress The address of the user
     *  @param _identity The address of the user's new identity contract
     *  emits `IdentityModified` event
     */
    function modifyStoredIdentity(address _userAddress, IIdentity _identity) external;

    /**
     *  @notice Adds an identity registry to the list of identityRegistries linked to the storage contract.
     *  Gated by the IRS_BINDER role (see AccessManagerSetupLib): a transient role the TREXFactory
     *  self-grants for the bind window when attaching an IR onto a reused IRS, and revokes immediately.
     *  The number of bound registries is capped (see `MAX_BOUND_REGISTRIES` on the implementation).
     *
     *  @dev The bound set (`linkedIdentityRegistries`) is enumeration only, NOT authorization. Write
     *  access to the IRS (addIdentityToStorage / modify* / remove*) is gated solely by the AGENT role
     *  on the AccessManager and is never checked against this set. Consequently an IR holding AGENT may
     *  write to the IRS without being bound, and an unbound IR keeps AGENT until the AccessManager
     *  revokes it. Bind/unbind deliberately carry no grantRole/revokeRole of AGENT.
     *  @param _identityRegistry The identity registry address to add.
     */
    function bindIdentityRegistry(address _identityRegistry) external;

    /**
     *  @notice Removes an identity registry from the list of identityRegistries linked to the storage contract.
     *  Gated by the OWNER role: unbinding is a governance operation, not a deploy-time action.
     *  @dev See {bindIdentityRegistry} — the bound set is enumeration only; unbinding does not revoke any
     *  AGENT authorization the IR may hold on the AccessManager.
     *  @param _identityRegistry The identity registry address to remove.
     */
    function unbindIdentityRegistry(address _identityRegistry) external;

    /**
     *  @dev Returns the identity registries linked to the storage contract
     */
    function linkedIdentityRegistries() external view returns (address[] memory);

    /**
     *  @notice Returns whether an identity registry is in the bound set.
     *  @dev See {bindIdentityRegistry} — the bound set is enumeration only, NOT authorization. A true
     *  result does not mean the registry may write to the storage, and a false result does not mean it
     *  may not: write access is gated solely by the AGENT role on the AccessManager. Do not use this as
     *  an access check.
     *  @param _identityRegistry The identity registry address to test.
     */
    function isLinkedIdentityRegistry(address _identityRegistry) external view returns (bool);

    /**
     *  @dev Returns the number of identity registries linked to the storage contract, without copying
     *  the set. Equivalent to `linkedIdentityRegistries().length`.
     */
    function linkedIdentityRegistryCount() external view returns (uint256);

    /**
     *  @notice Returns a slice of the bound set, for reading it in pages instead of in one copy.
     *  @dev Both bounds are clamped to the set size and `_start` is clamped to `_end`, so an out-of-range
     *  page returns an empty array rather than reverting. Paginate against `linkedIdentityRegistryCount`.
     *
     *  Set order is NOT stable: removing a registry moves the last element into the freed slot. A caller
     *  paging across several calls may therefore miss or repeat an entry if a bind or unbind lands between
     *  them. Read the whole set in one call where a consistent snapshot matters.
     *  @param _start Index of the first entry to return, inclusive.
     *  @param _end Index to stop at, exclusive.
     */
    function linkedIdentityRegistries(uint256 _start, uint256 _end) external view returns (address[] memory);

    /**
     *  @dev Returns the onchainID of an investor.
     *  @param _userAddress The wallet of the investor
     */
    function storedIdentity(address _userAddress) external view returns (IIdentity);

    /**
     *  @dev Returns the country code of an investor.
     *  @param _userAddress The wallet of the investor
     */
    function storedInvestorCountry(address _userAddress) external view returns (uint16);

}

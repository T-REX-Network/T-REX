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

interface ITREXFactory {

    /// Types
    struct TokenDetails {
        // name of the token
        string name;
        // symbol / ticker of the token
        string symbol;
        // decimals of the token (can be between 0 and 18)
        uint8 decimals;
        // identity registry storage address
        // set it to ZERO address if you want to deploy a new storage
        // if an address is provided, its authority must be the suite's access manager; the factory never
        // binds the new identity registry to it, the issuer does
        address irs;
        // ONCHAINID of the token
        address ONCHAINID;
        // modules to bind to the compliance, indexes are corresponding to the settings callData indexes
        // if a module doesn't require settings, it can be added at the end of the array, at index > settings.length
        address[] complianceModules;
        // settings calls for compliance modules
        bytes[] complianceSettings;
        // access manager address
        // set it to ZERO address to have the factory deploy a TREXAccessManager for the suite
        address accessManager;
        // account receiving ADMIN_ROLE on the deployed access manager, ignored when one is supplied
        address accessManagerAdmin;
    }

    struct ClaimDetails {
        // claim topics required
        uint256[] claimTopics;
        // trusted issuers addresses
        address[] issuers;
        // claims that issuers are allowed to emit, by index, index corresponds to the `issuers` indexes
        uint256[][] issuerClaims;
    }

    /// functions

    /**
     *  @dev setter for implementation authority contract address
     *  the implementation authority contract contains the addresses of all implementation contracts
     *  the proxies created by the factory will use the different implementations available
     *  in the implementation authority contract
     *  Restricted to the configured AccessManager role (OWNER).
     *  emits `ImplementationAuthoritySet` event
     *  @param _implementationAuthority The address of the implementation authority smart contract
     */
    function setImplementationAuthority(address _implementationAuthority) external;

    /**
     *  @dev setter for identity factory contract address
     *  the identity factory contract is used by the TREX Factory to deploy the ONCHAINID
     *  of the token in case the ONCHAINID is not specified
     *  Restricted to the configured AccessManager role (OWNER).
     *  emits `IdFactorySet` event
     *  @param _idFactory The address of the identity factory contract
     */
    function setIdFactory(address _idFactory) external;

    /**
     *  @dev function used to deploy a new TREX token and set all the parameters as required by the issuer paperwork
     *  this function will deploy and set the contracts as follow :
     *  Token : deploy the token contract (proxy) and set the name, symbol, ONCHAINID, decimals, owner,
     *  IR address , Compliance address
     *  Identity Registry : deploy the IR contract (proxy) and set the owner,
     *  IRS address, TIR address, CTR address
     *  IRS : deploy IRS contract (proxy) if required (address set as 0 in the TokenDetails, bind IRS to IR, set owner
     *  CTR : deploy CTR contract (proxy), set required claims, set owner
     *  TIR : deploy TIR contract (proxy), set trusted issuers, set owner
     *  Compliance: deploy modular compliance, bind with token, add modules, set modules parameters, set owner
     *  AccessManager : when `_tokenDetails.accessManager` is zero, deploy a `TREXAccessManager` (proxy),
     *  create a domain named after the token, assign the token and its storage to it, commission the
     *  suite and hand `ADMIN_ROLE` to `_tokenDetails.accessManagerAdmin`. When a manager is supplied the
     *  factory never calls it: the suite deploys with no role wiring and is not operable until the
     *  issuer commissions it (`AccessManagerSetupLib.commissionSuite`).
     *  All contracts are deployed using CREATE3, and therefore are deployed at a predetermined address
     *  The address can be the same on all EVM blockchains as long as this factory is deployed at the
     *  same address on each chain
     *  Restricted to the configured AccessManager role (OWNER).
     *  emits `TREXSuiteDeployed` event
     *  @param _salt the salt used to make the contracts deployments with CREATE2
     *  @param _tokenDetails The details of the token to deploy (see struct TokenDetails for more details)
     *  @param _claimDetails The details of the claims and claim issuers (see struct ClaimDetails for more details)
     *  cannot add more than 5 claim topics required and more than 5 trusted issuers
     *  cannot bind more than 25 compliance modules
     */
    function deployTREXSuite(
        string memory _salt,
        TokenDetails calldata _tokenDetails,
        ClaimDetails calldata _claimDetails
    ) external;

    /**
     *  @dev deploys a suite that does not follow the shared implementation authority.
     *  Clones fresh `UpgradeableBeacon`s from the authority's active implementations, one per suite contract
     *  plus one for the access manager when the factory deploys it, and points the
     *  suite at those clones instead of the shared beacons, so later `publish` / `upgrade` calls on the
     *  authority never reach this suite. The suite-contract clones are owned by the suite's access
     *  manager, supplied or factory-deployed; the access-manager clone, when the factory deploys the
     *  manager, is owned by `_tokenDetails.accessManagerAdmin`. Rotating that administrator is two steps:
     *  the `ADMIN_ROLE` rotation inside the manager and `transferOwnership` on the access-manager clone,
     *  which the manager's roles do not govern.
     *  `_tokenDetails.irs` must be zero: a reused IRS keeps the beacon that deployed it, so the suite always
     *  deploys its own identity storage through the cloned IRS beacon.
     *  When `_tokenDetails.accessManager` is zero the factory deploys a `TREXAccessManager` behind the cloned
     *  beacon, creates a domain named after the token, assigns the token and its storage, commissions the
     *  suite and hands `ADMIN_ROLE` to `_tokenDetails.accessManagerAdmin`. When a manager is supplied the
     *  factory never calls it: the suite deploys with no role wiring and is not operable until the issuer
     *  commissions it (`AccessManagerSetupLib.commissionSuite`).
     *  Restricted to the configured AccessManager role (OWNER).
     *  emits `TREXSuiteDeployed` and `IsolatedSuiteDeployed` events
     *  @param _salt the salt used to make the contracts deployments with CREATE3
     *  @param _tokenDetails The details of the token to deploy (see struct TokenDetails for more details)
     *  @param _claimDetails The details of the claims and claim issuers (see struct ClaimDetails for more details)
     */
    function deployTREXSuiteIsolated(
        string memory _salt,
        TokenDetails calldata _tokenDetails,
        ClaimDetails calldata _claimDetails
    ) external;

    /**
     *  @dev getter for implementation authority address
     */
    function getImplementationAuthority() external view returns (address);

    /**
     *  @dev getter for identity factory address
     */
    function getIdFactory() external view returns (address);

    /**
     *  @dev getter for token address corresponding to salt string
     *  @param _salt The salt string that was used to deploy the token
     */
    function getToken(string calldata _salt) external view returns (address);

}

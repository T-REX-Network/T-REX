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

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IClaimIssuer, IIdentity } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import { Structs } from "@onchain-id/solidity/contracts/storage/Structs.sol";

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IERC3643 } from "../ERC-3643/IERC3643.sol";
import { IERC3643ClaimTopicsRegistry } from "../ERC-3643/IERC3643ClaimTopicsRegistry.sol";
import { IERC3643IdentityRegistry } from "../ERC-3643/IERC3643IdentityRegistry.sol";
import { IERC3643TrustedIssuersRegistry } from "../ERC-3643/IERC3643TrustedIssuersRegistry.sol";
import { IModularCompliance } from "../compliance/modular/IModularCompliance.sol";
import { IModule } from "../compliance/modular/modules/IModule.sol";
import { ModuleCapabilitiesLib } from "../libraries/ModuleCapabilitiesLib.sol";
import { ITREXRegistry } from "../registry/interface/ITREXRegistry.sol";
import { IUtilityChecker } from "./IUtilityChecker.sol";

contract UtilityChecker is IUtilityChecker, OwnableUpgradeable, UUPSUpgradeable {

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init(msg.sender);
    }

    /// @inheritdoc IUtilityChecker
    /// @dev This function is not gas optimized and should be called only OFF chain.
    function getTransferStatus(address _token, address _from, address _to, uint256 _amount)
        external
        view
        returns (bool _freezeStatus, bool _eligibilityStatus, bool _complianceStatus)
    {
        IERC3643 token = IERC3643(_token);

        _freezeStatus = !token.paused();

        (bool frozen,) = getFreezeStatus(_token, _from, _to, _amount);
        _freezeStatus = _freezeStatus && !frozen;

        IERC3643IdentityRegistry ir = token.identityRegistry();
        _eligibilityStatus = ir.isVerified(_to);

        ComplianceCheckDetails[] memory details = getTransferDetails(_token, _from, _to, _amount);
        _complianceStatus = true;
        for (uint256 i; i < details.length; i++) {
            if (!details[i].pass) {
                _complianceStatus = false;
                break;
            }
        }
    }

    /// @inheritdoc IUtilityChecker
    function getVerifiedDetails(address _token, address _userAddress)
        public
        view
        returns (EligibilityCheckDetails[] memory _details)
    {
        IERC3643IdentityRegistry identityRegistry = IERC3643(_token).identityRegistry();
        IERC3643TrustedIssuersRegistry tokenIssuersRegistry = identityRegistry.issuersRegistry();
        IIdentity identity = identityRegistry.identity(_userAddress);

        uint256[] memory requiredClaimTopics = _requiredClaimTopics(identityRegistry, identity);
        uint256 topicsCount = requiredClaimTopics.length;
        _details = new EligibilityCheckDetails[](topicsCount);
        for (uint256 claimTopic; claimTopic < topicsCount; claimTopic++) {
            uint256 topic = requiredClaimTopics[claimTopic];
            address[] memory trustedIssuers = tokenIssuersRegistry.getTrustedIssuersForClaimTopic(topic);

            for (uint256 i; i < trustedIssuers.length; i++) {
                (bool topicMatch, bool pass) = _getEligibility(trustedIssuers[i], topic, identity);
                if (topicMatch) {
                    _details[claimTopic] =
                        EligibilityCheckDetails({ issuer: IClaimIssuer(trustedIssuers[i]), topic: topic, pass: pass });
                }
            }
        }
    }

    /// @dev Mirrors the type-aware topic resolution of `TREXRegistry.isVerified`: the identity type is
    ///  read from the IdentityFactory's creation-time record, and a non-empty override set for that
    ///  type replaces the default topics. The registry lookup is done through a try/catch so the
    ///  checker still works against registries without per-type overrides.
    function _requiredClaimTopics(IERC3643IdentityRegistry identityRegistry, IIdentity identity)
        internal
        view
        returns (uint256[] memory)
    {
        IERC3643ClaimTopicsRegistry topicsRegistry = identityRegistry.topicsRegistry();
        if (address(identity) != address(0)) {
            try ITREXRegistry(address(topicsRegistry)).identityFactory() returns (IIdentityFactory factory) {
                uint256 identityType = factory.identityTypeOf(address(identity));
                if (identityType != 0) {
                    uint256[] memory typeTopics =
                        ITREXRegistry(address(topicsRegistry)).getClaimTopicsForIdentityType(identityType);
                    if (typeTopics.length > 0) {
                        return typeTopics;
                    }
                }
            } catch { }
        }
        return topicsRegistry.getClaimTopics();
    }

    /// @dev Function splitted to avoid stack too deep error
    function _getEligibility(address trustedIssuer, uint256 topic, IIdentity identity)
        internal
        view
        returns (bool topicMatch, bool pass)
    {
        /// forge-lint: disable-next-line(asm-keccak256)
        bytes32 claimId = keccak256(abi.encode(trustedIssuer, topic));
        (uint256 foundClaimTopic,, address issuer, bytes memory sig, Structs.ClaimData memory data,) =
            identity.getClaim(claimId);
        if (foundClaimTopic != topic) return (false, false);
        topicMatch = true;

        try IClaimIssuer(issuer).isClaimValid(identity, topic, sig, data) returns (bool validity) {
            pass = validity;
        } catch {
            pass = false;
        }
    }

    /// @inheritdoc IUtilityChecker
    function getFreezeStatus(address _token, address _from, address _to, uint256 _amount)
        public
        view
        returns (bool _frozen, uint256 _availableBalance)
    {
        IERC3643 token = IERC3643(_token);

        if (token.isFrozen(_from) || token.isFrozen(_to)) {
            _availableBalance = 0;
            _frozen = true;
        } else {
            _availableBalance = token.balanceOf(_from) - token.getFrozenTokens(_from);
            _frozen = _amount > _availableBalance;
        }
    }

    /// @inheritdoc IUtilityChecker
    function getTransferDetails(address _token, address _from, address _to, uint256 _value)
        public
        view
        returns (ComplianceCheckDetails[] memory _details)
    {
        IModularCompliance compliance = IModularCompliance(address(IERC3643(_token).compliance()));
        // Only the modules that declared the transfer check are consulted, matching what the
        // compliance actually calls. Listing the others would report a pass they never gave.
        address[] memory modules = compliance.getModulesByCapability(ModuleCapabilitiesLib.CHECK_TRANSFER);
        uint256 length = modules.length;
        _details = new ComplianceCheckDetails[](length);
        for (uint256 i; i < length; i++) {
            IModule module = IModule(modules[i]);
            _details[i] = ComplianceCheckDetails({
                moduleName: module.name(), pass: module.moduleCheck(_from, _to, _value, address(compliance))
            });
        }
    }

    function _authorizeUpgrade(
        address /*newImplementation*/
    )
        internal
        view
        override
        onlyOwner
    { }

}

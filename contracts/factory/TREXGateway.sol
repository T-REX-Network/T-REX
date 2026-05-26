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

import { ErrorsLib } from "../libraries/ErrorsLib.sol";
import { EventsLib } from "../libraries/EventsLib.sol";
import { AgentRole } from "../roles/AgentRole.sol";
import { IERC173 } from "../roles/IERC173.sol";
import { ITREXFactory } from "./ITREXFactory.sol";
import { ITREXGateway } from "./ITREXGateway.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract TREXGateway is ITREXGateway, AgentRole, IERC165 {

    using SafeERC20 for IERC20;

    /// address of the TREX Factory that is managed by the Gateway
    address private _factory;

    /// public deployment status variable
    bool private _publicDeploymentStatus;

    /// deployment fee details
    Fee private _deploymentFee;

    /// deployment fees enabling variable
    bool private _deploymentFeeEnabled;

    /// mapping containing all deployer addresses
    mapping(address => bool) private _deployers;

    /// mapping for deployment discounts on fees
    mapping(address => uint16) private _feeDiscount;

    /// constructor of the contract, setting up the factory address and
    /// the public deployment status
    constructor(address factory, bool publicDeploymentStatus) {
        _factory = factory;
        _publicDeploymentStatus = publicDeploymentStatus;
        emit EventsLib.FactorySet(factory);
        emit EventsLib.PublicDeploymentStatusSet(publicDeploymentStatus);
    }

    /**
     *  @dev See {ITREXGateway-setFactory}.
     */
    function setFactory(address factory) external override onlyOwner {
        require(factory != address(0), ErrorsLib.ZeroAddress());

        _factory = factory;
        emit EventsLib.FactorySet(factory);
    }

    /**
     *  @dev See {ITREXGateway-setPublicDeploymentStatus}.
     */
    function setPublicDeploymentStatus(bool _isEnabled) external override onlyOwner {
        if (_isEnabled == _publicDeploymentStatus) {
            if (_isEnabled) {
                revert ErrorsLib.PublicDeploymentAlreadyEnabled();
            }
            revert ErrorsLib.PublicDeploymentAlreadyDisabled();
        }

        _publicDeploymentStatus = _isEnabled;
        emit EventsLib.PublicDeploymentStatusSet(_isEnabled);
    }

    /**
     *  @dev See {ITREXGateway-transferFactoryOwnership}.
     */
    function transferFactoryOwnership(address _newOwner) external override onlyOwner {
        Ownable(_factory).transferOwnership(_newOwner);
    }

    /**
     *  @dev See {ITREXGateway-enableDeploymentFee}.
     */
    function enableDeploymentFee(bool _isEnabled) external override onlyOwner {
        if (_isEnabled == _deploymentFeeEnabled) {
            if (_isEnabled) {
                revert ErrorsLib.DeploymentFeesAlreadyEnabled();
            }
            revert ErrorsLib.DeploymentFeesAlreadyDisabled();
        }

        _deploymentFeeEnabled = _isEnabled;
        emit EventsLib.DeploymentFeeEnabled(_isEnabled);
    }

    /**
     *  @dev See {ITREXGateway-setDeploymentFee}.
     */
    function setDeploymentFee(uint256 _fee, address _feeToken, address _feeCollector) external override onlyOwner {
        require(_feeToken != address(0) && _feeCollector != address(0), ErrorsLib.ZeroAddress());

        _deploymentFee.fee = _fee;
        _deploymentFee.feeToken = _feeToken;
        _deploymentFee.feeCollector = _feeCollector;
        emit EventsLib.DeploymentFeeSet(_fee, _feeToken, _feeCollector);
    }

    /**
     *  @dev See {ITREXGateway-batchAddDeployer}.
     */
    function batchAddDeployer(address[] calldata deployers) external override {
        require(isAgent(msg.sender) || msg.sender == owner(), ErrorsLib.SenderIsNotAdmin());
        require(deployers.length <= 500, ErrorsLib.BatchMaxLengthExceeded(500));

        for (uint256 i = 0; i < deployers.length; i++) {
            require(!isDeployer(deployers[i]), ErrorsLib.DeployerAlreadyExists(deployers[i]));

            _deployers[deployers[i]] = true;
            emit EventsLib.DeployerAdded(deployers[i]);
        }
    }

    /**
     *  @dev See {ITREXGateway-addDeployer}.
     */
    function addDeployer(address deployer) external override {
        require(isAgent(msg.sender) || msg.sender == owner(), ErrorsLib.SenderIsNotAdmin());
        require(!isDeployer(deployer), ErrorsLib.DeployerAlreadyExists(deployer));

        _deployers[deployer] = true;
        emit EventsLib.DeployerAdded(deployer);
    }

    /**
     *  @dev See {ITREXGateway-batchRemoveDeployer}.
     */
    function batchRemoveDeployer(address[] calldata deployers) external override {
        require(isAgent(msg.sender) || msg.sender == owner(), ErrorsLib.SenderIsNotAdmin());
        require(deployers.length <= 500, ErrorsLib.BatchMaxLengthExceeded(500));

        for (uint256 i = 0; i < deployers.length; i++) {
            require(isDeployer(deployers[i]), ErrorsLib.DeployerDoesNotExist(deployers[i]));

            delete _deployers[deployers[i]];
            emit EventsLib.DeployerRemoved(deployers[i]);
        }
    }

    /**
     *  @dev See {ITREXGateway-removeDeployer}.
     */
    function removeDeployer(address deployer) external override {
        require(isAgent(msg.sender) || msg.sender == owner(), ErrorsLib.SenderIsNotAdmin());
        require(isDeployer(deployer), ErrorsLib.DeployerDoesNotExist(deployer));

        delete _deployers[deployer];
        emit EventsLib.DeployerRemoved(deployer);
    }

    /**
     *  @dev See {ITREXGateway-batchApplyFeeDiscount}.
     */
    function batchApplyFeeDiscount(address[] calldata deployers, uint16[] calldata discounts) external override {
        require(isAgent(msg.sender) || msg.sender == owner(), ErrorsLib.SenderIsNotAdmin());
        require(deployers.length <= 500, ErrorsLib.BatchMaxLengthExceeded(500));

        for (uint256 i = 0; i < deployers.length; i++) {
            require(discounts[i] <= 10000, ErrorsLib.DiscountOutOfRange());

            _feeDiscount[deployers[i]] = discounts[i];
            emit EventsLib.FeeDiscountApplied(deployers[i], discounts[i]);
        }
    }

    /**
     *  @dev See {ITREXGateway-applyFeeDiscount}.
     */
    function applyFeeDiscount(address deployer, uint16 discount) external override {
        require(isAgent(msg.sender) || msg.sender == owner(), ErrorsLib.SenderIsNotAdmin());
        require(discount <= 10000, ErrorsLib.DiscountOutOfRange());

        _feeDiscount[deployer] = discount;
        emit EventsLib.FeeDiscountApplied(deployer, discount);
    }

    /**
     *  @dev See {ITREXGateway-batchDeployTREXSuite}.
     */
    function batchDeployTREXSuite(
        ITREXFactory.TokenDetails[] memory _tokenDetails,
        ITREXFactory.ClaimDetails[] memory _claimDetails
    ) external override {
        require(_tokenDetails.length <= 5, ErrorsLib.BatchMaxLengthExceeded(5));

        for (uint256 i = 0; i < _tokenDetails.length; i++) {
            deployTREXSuite(_tokenDetails[i], _claimDetails[i]);
        }
    }

    /**
     *  @dev See {ITREXGateway-getPublicDeploymentStatus}.
     */
    function getPublicDeploymentStatus() external view override returns (bool) {
        return _publicDeploymentStatus;
    }

    /**
     *  @dev See {ITREXGateway-getFactory}.
     */
    function getFactory() external view override returns (address) {
        return _factory;
    }

    /**
     *  @dev See {ITREXGateway-getDeploymentFee}.
     */
    function getDeploymentFee() external view override returns (Fee memory) {
        return _deploymentFee;
    }

    /**
     *  @dev See {ITREXGateway-isDeploymentFeeEnabled}.
     */
    function isDeploymentFeeEnabled() external view override returns (bool) {
        return _deploymentFeeEnabled;
    }

    /**
     *  @dev See {ITREXGateway-deployTREXSuite}.
     */
    function deployTREXSuite(
        ITREXFactory.TokenDetails memory _tokenDetails,
        ITREXFactory.ClaimDetails memory _claimDetails
    ) public override {
        require(_publicDeploymentStatus || isDeployer(msg.sender), ErrorsLib.PublicDeploymentsNotAllowed());
        require(
            !_publicDeploymentStatus || msg.sender == _tokenDetails.owner || isDeployer(msg.sender),
            ErrorsLib.PublicCannotDeployOnBehalf()
        );

        uint256 feeApplied = 0;
        if (_deploymentFeeEnabled) {
            if (_deploymentFee.fee > 0 && _feeDiscount[msg.sender] < 10000) {
                feeApplied = calculateFee(msg.sender);
                IERC20(_deploymentFee.feeToken).safeTransferFrom(msg.sender, _deploymentFee.feeCollector, feeApplied);
            }
        }
        string memory _salt = string(abi.encodePacked(Strings.toHexString(_tokenDetails.owner), _tokenDetails.name));
        ITREXFactory(_factory).deployTREXSuite(_salt, _tokenDetails, _claimDetails);
        emit EventsLib.GatewaySuiteDeploymentProcessed(msg.sender, _tokenDetails.owner, feeApplied);
    }

    /**
     *  @dev See {ITREXGateway-isDeployer}.
     */
    function isDeployer(address deployer) public view override returns (bool) {
        return _deployers[deployer];
    }

    /**
     *  @dev See {ITREXGateway-calculateFee}.
     */
    function calculateFee(address deployer) public view override returns (uint256) {
        return _deploymentFee.fee - ((_feeDiscount[deployer] * _deploymentFee.fee) / 10000);
    }

    /**
     *  @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(ITREXGateway).interfaceId || interfaceId == type(IERC173).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

}

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
// Copyright (C) 2026 Digital Asset Operational Services ISAC Ltd. ("T-REX Network")
//
// This file is part of the T-REX smart contract suite.
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

import { ErrorsLib } from "../../../libraries/ErrorsLib.sol";
import {
    AccessManagedOwnableBase,
    AccessManagedOwnableUpgradeable
} from "../../../utils/AccessManagedOwnableUpgradeable.sol";
import { AbstractModuleUpgradeable } from "./AbstractModuleUpgradeable.sol";
import { IModule } from "./IModule.sol";

/// @title AwayChainVolumeModule
/// @dev Caps how much may leave one away chain in a window, per compliance.
///
/// The caps of the compliance bound what a home reorg can cost. They do not bound a hostile away token, which can
/// still report a move of a home block that was dropped. This rule bounds what one away chain can make leave in a
/// window: an ask, or home's decision for a second half, is narrowed to the room left on the chain the money leaves,
/// and refused once nothing is left. The next window opens it again.
///
/// The chain comes from the context's `data`, see {IModule-TransferContext}. A move is counted once, when the
/// compliance tells it done; tickets still open are not counted, so asks open at the same time each see the same
/// room. A chain with no limit set is not limited and not counted. Settings and counts are keyed by the bind
/// nonce, so an unbind discards them.
contract AwayChainVolumeModule is AbstractModuleUpgradeable, AccessManagedOwnableUpgradeable {

    /// @dev The limit on one away chain.
    struct VolumeLimit {
        /// The most that may leave the chain in one window.
        uint256 limitPerWindow;
        /// The length of a window, in seconds. Zero: no limit was set for the chain.
        uint64 window;
    }

    /// @dev What left one away chain in its current window.
    struct Volume {
        /// When the current window started, in seconds. It starts at the first move counted after the last one ended.
        uint64 windowStart;
        uint256 amount;
    }

    /// @custom:storage-location erc7201:erc3643.storage.AwayChainVolumeModule
    struct AwayChainVolumeStorage {
        mapping(address compliance => mapping(uint256 nonce => mapping(bytes32 chainKey => VolumeLimit limit)))
            volumeLimits;
        mapping(address compliance => mapping(uint256 nonce => mapping(bytes32 chainKey => Volume volume))) volumes;
    }

    // keccak256(abi.encode(uint256(keccak256("erc3643.storage.AwayChainVolumeModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _AWAY_CHAIN_VOLUME_STORAGE_LOCATION =
        0xb91230f40bfbf5e88d4161ddd9c599e4be5ec7192a71e0a5199f484e731ea200;

    /// @dev Emitted when a compliance sets the limit on one away chain.
    /// @param compliance the compliance the limit belongs to
    /// @param chainKey the away chain, keyed as `MessageTypesLib.chainKey` computes it
    /// @param limitPerWindow the most that may leave the chain in one window
    /// @param window the length of a window, in seconds
    event VolumeLimitSet(address indexed compliance, bytes32 indexed chainKey, uint256 limitPerWindow, uint64 window);

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the module behind its proxy.
    /// @param accessManagerAddress authority gating the implementation upgrade
    function initialize(address accessManagerAddress) external initializer {
        require(accessManagerAddress != address(0), ErrorsLib.ZeroAddress());

        __AbstractModule_init();
        __AccessManaged_init(accessManagerAddress);
    }

    /// @dev Sets the limit on one away chain for the calling compliance, driven by its owner through
    ///  `addAndSetModule` or `callModuleFunction`. A new window length also moves the end of the window running now.
    ///  To lift a limit, set `type(uint256).max`. Emits `VolumeLimitSet`.
    /// @param _chainKey the away chain, keyed as `MessageTypesLib.chainKey` computes it
    /// @param _limitPerWindow the most that may leave the chain in one window
    /// @param _window the length of a window, in seconds; must be positive
    function setVolumeLimit(bytes32 _chainKey, uint256 _limitPerWindow, uint64 _window) external onlyComplianceCall {
        require(_window != 0, ErrorsLib.ZeroDuration());

        VolumeLimit storage limit =
            _getAwayChainVolumeStorage().volumeLimits[msg.sender][getNonce(msg.sender)][_chainKey];
        limit.limitPerWindow = _limitPerWindow;
        limit.window = _window;
        emit VolumeLimitSet(msg.sender, _chainKey, _limitPerWindow, _window);
    }

    /// @dev The limit `_compliance` set on one away chain; a zero `window` means none was set.
    /// @param _compliance the compliance the limit belongs to
    /// @param _chainKey the away chain
    function volumeLimitOf(address _compliance, bytes32 _chainKey) external view returns (VolumeLimit memory) {
        return _getAwayChainVolumeStorage().volumeLimits[_compliance][getNonce(_compliance)][_chainKey];
    }

    /// @inheritdoc IModule
    /// @dev The room left on the chain the money leaves in its current window. No limit on a native movement, which
    ///  carries no chain, nor on a chain with no limit set.
    function checkTransfer(TransferContext calldata ctx) external view override returns (uint256) {
        if (ctx.data.length == 0) return type(uint256).max;
        bytes32 fromChainKey = abi.decode(ctx.data, (bytes32));

        AwayChainVolumeStorage storage store = _getAwayChainVolumeStorage();
        uint256 nonce = getNonce(ctx.compliance);
        VolumeLimit storage limit = store.volumeLimits[ctx.compliance][nonce][fromChainKey];
        if (limit.window == 0) return type(uint256).max;

        Volume storage volume = store.volumes[ctx.compliance][nonce][fromChainKey];
        uint256 carried = volume.amount;
        if (_windowIsOver(volume, limit.window)) carried = 0;
        if (carried >= limit.limitPerWindow) return 0;
        return limit.limitPerWindow - carried;
    }

    /// @inheritdoc IModule
    /// @dev Counts a move that is done on the chain the money left, in the current window or in a new one from now
    ///  once the last one is over. Every kind is counted, a relocation between one identity's wallets too: the rules
    ///  are not asked about it, but it left the chain all the same. Counted under the caller, the bound compliance,
    ///  so one compliance never writes another's counts.
    function afterTransfer(TransferContext calldata ctx) external override onlyComplianceCall {
        if (ctx.data.length == 0) return;
        bytes32 fromChainKey = abi.decode(ctx.data, (bytes32));

        AwayChainVolumeStorage storage store = _getAwayChainVolumeStorage();
        uint256 nonce = getNonce(msg.sender);
        VolumeLimit storage limit = store.volumeLimits[msg.sender][nonce][fromChainKey];
        if (limit.window == 0) return;

        Volume storage volume = store.volumes[msg.sender][nonce][fromChainKey];
        if (_windowIsOver(volume, limit.window)) {
            volume.windowStart = uint64(block.timestamp);
            volume.amount = 0;
        }
        volume.amount += ctx.amountMax;
    }

    /// @inheritdoc IModule
    function moduleTypes() external pure returns (ModuleType[] memory types) {
        types = new ModuleType[](2);
        types[0] = ModuleType.TRANSFER_CHECK;
        types[1] = ModuleType.AFTER;
    }

    /// @inheritdoc IModule
    /// @dev Binds anywhere: a chain is limited only once a limit is set for it, and counted from then on.
    function isPlugAndPlay() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    function canComplianceBind(address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    function name() external pure returns (string memory) {
        return "AwayChainVolumeModule";
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AbstractModuleUpgradeable, AccessManagedOwnableBase)
        returns (bool)
    {
        return AbstractModuleUpgradeable.supportsInterface(interfaceId)
            || AccessManagedOwnableBase.supportsInterface(interfaceId);
    }

    /// @dev Only the configured AccessManager role may upgrade the implementation.
    function _authorizeUpgrade(address) internal override restricted { }

    /// @dev Whether the window of `volume` is over: `window` seconds passed since it started. A chain never counted
    ///  has a window from zero, long over.
    function _windowIsOver(Volume storage volume, uint64 window) private view returns (bool) {
        uint256 windowEnd = uint256(volume.windowStart) + window;
        return block.timestamp >= windowEnd;
    }

    function _getAwayChainVolumeStorage() private pure returns (AwayChainVolumeStorage storage store) {
        assembly ("memory-safe") {
            store.slot := _AWAY_CHAIN_VOLUME_STORAGE_LOCATION
        }
    }

}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { ICreateX } from "@createx/ICreateX.sol";
import { Script } from "@forge-std/Script.sol";

abstract contract BaseDeployScript is Script {

    string public VERSION = "2026-04-14";
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    string internal constant DEPLOYMENTS_DIR = "deployments/";

    function _deployCreate3(bytes32 salt, bytes memory initCode) internal returns (address) {
        return CREATEX.deployCreate3(salt, initCode);
    }

    function _salt(string memory name) internal view returns (bytes32) {
        // CreateX salt format: [20 bytes: msg.sender][1 byte: redeploy protection flag][11 bytes: entropy]
        // Setting first 20 bytes to msg.sender enables permissioned deploy protection.
        // Setting byte 21 to 0x00 disables cross-chain redeploy protection (same address on all chains).
        bytes11 entropy = bytes11(keccak256(abi.encodePacked(string.concat(name, VERSION))));
        return bytes32(abi.encodePacked(msg.sender, bytes1(0x00), entropy));
    }

    function _writeDeployment(string memory filename, string memory json) internal {
        string memory dir = string.concat(vm.projectRoot(), "/", DEPLOYMENTS_DIR);
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, filename), json);
    }

    function _readDeployment(string memory filename) internal view returns (string memory) {
        string memory path = string.concat(vm.projectRoot(), "/", DEPLOYMENTS_DIR, filename);
        return vm.readFile(path);
    }

    function _readAddress(string memory filename, string memory key) internal view returns (address) {
        string memory json = _readDeployment(filename);
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

}

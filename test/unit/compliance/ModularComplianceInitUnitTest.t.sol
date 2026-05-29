// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { ModularCompliance } from "contracts/compliance/modular/ModularCompliance.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { AccessManagerSetupLib } from "contracts/libraries/AccessManagerSetupLib.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { RolesLib } from "contracts/libraries/RolesLib.sol";
import { ModularComplianceProxy } from "contracts/proxy/ModularComplianceProxy.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/authority/ITREXImplementationAuthority.sol";

import { AccessManagerHelper } from "../../helpers/AccessManagerHelper.sol";
import { TestModule } from "test/integration/mocks/TestModule.sol";

contract ModularComplianceInitUnitTest is AccessManagerHelper {

    ModularCompliance private mcImplementation;
    address private implementationAuthority = makeAddr("ImplementationAuthorityMock");

    address private owner = makeAddr("Owner");
    address private notOwner = makeAddr("NotOwner");
    address private token = makeAddr("Token");

    function setUp() public {
        mcImplementation = new ModularCompliance();
        vm.mockCall(
            implementationAuthority,
            abi.encodeWithSelector(ITREXImplementationAuthority.getMCImplementation.selector),
            abi.encode(address(mcImplementation))
        );
    }

    function test_init_SetsOwnerToAccessManager() public {
        ModularCompliance mc = _deployProxy(token, _emptyModules(), _emptySettings());

        assertEq(mc.owner(), address(accessManager));
        assertNotEq(mc.owner(), address(this));
    }

    function test_init_BindsTokenFromArgument() public {
        ModularCompliance mc = _deployProxy(token, _emptyModules(), _emptySettings());

        assertEq(mc.getTokenBound(), token);
        assertTrue(mc.isTokenBound(token));
    }

    function test_init_BindsEveryModuleAndAppliesSettings() public {
        address moduleA = _deployTestModuleWithProxy();
        address moduleB = _deployTestModuleWithProxy();

        address[] memory modules = new address[](2);
        modules[0] = moduleA;
        modules[1] = moduleB;

        bytes[] memory settings = new bytes[](2);
        settings[0] = abi.encodeWithSignature("doSomething(uint256)", 42);
        settings[1] = abi.encodeWithSignature("blockModule(bool)", true);

        ModularCompliance mc = _deployProxy(token, modules, settings);

        assertTrue(mc.isModuleBound(moduleA));
        assertTrue(mc.isModuleBound(moduleB));
        assertEq(TestModule(moduleA).getComplianceData(address(mc)), 42);
        assertTrue(TestModule(moduleB).getBlockedTransfers(address(mc)));
    }

    function test_init_AppliesFewerSettingsThanModules() public {
        address moduleA = _deployTestModuleWithProxy();
        address moduleB = _deployTestModuleWithProxy();

        address[] memory modules = new address[](2);
        modules[0] = moduleA;
        modules[1] = moduleB;

        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeWithSignature("blockModule(bool)", true);

        ModularCompliance mc = _deployProxy(token, modules, settings);

        assertTrue(mc.isModuleBound(moduleA));
        assertTrue(mc.isModuleBound(moduleB));
        assertTrue(TestModule(moduleA).getBlockedTransfers(address(mc)));
        assertFalse(TestModule(moduleB).getBlockedTransfers(address(mc)));
    }

    function test_init_OwnerCanStillAddModuleAfterInit() public {
        ModularCompliance mc = _deployProxy(token, _emptyModules(), _emptySettings());
        address moduleA = _deployTestModuleWithProxy();

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(mc));
        accessManager.grantRole(RolesLib.OWNER, owner, NO_DELAY);
        vm.stopPrank();

        vm.prank(owner);
        mc.addModule(moduleA);

        assertTrue(mc.isModuleBound(moduleA));
    }

    function test_addModule_RevertWhen_NotOwner() public {
        ModularCompliance mc = _deployProxy(token, _emptyModules(), _emptySettings());
        address moduleA = _deployTestModuleWithProxy();

        vm.startPrank(accessManagerAdmin);
        AccessManagerSetupLib.setupModularComplianceRoles(accessManager, address(mc));
        vm.stopPrank();

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, notOwner));
        mc.addModule(moduleA);
    }

    function test_init_RevertWhen_TokenIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ModularComplianceProxy(
            implementationAuthority, address(accessManager), address(0), _emptyModules(), _emptySettings()
        );
    }

    function test_init_RevertWhen_AccessManagerIsZeroAddress() public {
        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ModularComplianceProxy(implementationAuthority, address(0), token, _emptyModules(), _emptySettings());
    }

    function test_init_RevertWhen_MoreSettingsThanModules() public {
        address[] memory modules = new address[](1);
        modules[0] = _deployTestModuleWithProxy();

        bytes[] memory settings = new bytes[](2);
        settings[0] = abi.encodeWithSignature("blockModule(bool)", true);
        settings[1] = abi.encodeWithSignature("blockModule(bool)", false);

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ModularComplianceProxy(implementationAuthority, address(accessManager), token, modules, settings);
    }

    function test_init_RevertWhen_MoreThan25Modules() public {
        address[] memory modules = new address[](26);
        for (uint256 i = 0; i < 26; i++) {
            modules[i] = _deployTestModuleWithProxy();
        }

        vm.expectRevert(ErrorsLib.InitializationFailed.selector);
        new ModularComplianceProxy(implementationAuthority, address(accessManager), token, modules, _emptySettings());
    }

    function test_bindToken_RevertWhen_DifferentTokenTriesToBindOverExistingBinding() public {
        ModularCompliance mc = _deployProxy(token, _emptyModules(), _emptySettings());
        address otherToken = makeAddr("OtherToken");

        vm.prank(otherToken);
        vm.expectRevert(ErrorsLib.OnlyOwnerOrTokenCanCall.selector);
        mc.bindToken(otherToken);
    }

    function test_init_RevertWhen_AlreadyInitialized() public {
        ModularCompliance mc = _deployProxy(token, _emptyModules(), _emptySettings());

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        mc.init(address(accessManager), token, _emptyModules(), _emptySettings());
    }

    function _deployProxy(address _token, address[] memory _modules, bytes[] memory _moduleSettings)
        private
        returns (ModularCompliance)
    {
        return ModularCompliance(
            address(
                new ModularComplianceProxy(
                    implementationAuthority, address(accessManager), _token, _modules, _moduleSettings
                )
            )
        );
    }

    function _deployTestModuleWithProxy() private returns (address) {
        TestModule moduleImplementation = new TestModule();
        bytes memory initData = abi.encodeWithSelector(TestModule.initialize.selector);
        ModuleProxy moduleProxy = new ModuleProxy(address(moduleImplementation), initData);
        return address(moduleProxy);
    }

    function _emptyModules() private pure returns (address[] memory) {
        return new address[](0);
    }

    function _emptySettings() private pure returns (bytes[] memory) {
        return new bytes[](0);
    }

}

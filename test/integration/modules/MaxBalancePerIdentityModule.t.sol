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

import { ERC3643ErrorsLib } from "contracts/ERC-3643/ERC3643ErrorsLib.sol";
import { IComplianceLedger } from "contracts/compliance/modular/IComplianceLedger.sol";
import { ITransferValidation } from "contracts/compliance/modular/ITransferValidation.sol";
import { IModule } from "contracts/compliance/modular/modules/IModule.sol";
import { MaxBalancePerIdentityModule } from "contracts/compliance/modular/modules/MaxBalancePerIdentityModule.sol";
import { ModuleProxy } from "contracts/compliance/modular/modules/ModuleProxy.sol";
import { ErrorsLib } from "contracts/libraries/ErrorsLib.sol";
import { Version, VersionLib } from "contracts/libraries/VersionLib.sol";
import { ITREXImplementationAuthority } from "contracts/proxy/beacon/ITREXImplementationAuthority.sol";
import { TREXRegistry } from "contracts/registry/implementation/TREXRegistry.sol";

import { IIdentityFactory } from "@onchain-id/solidity/contracts/factory/IIdentityFactory.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import { InteroperableAddress } from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";

import { InteropSuiteTest } from "test/integration/helpers/InteropSuiteTest.sol";
import { ERC7786GatewayMock } from "test/integration/mocks/ERC7786GatewayMock.sol";

/// @dev Stands in for another IdentityFactory after an admin upgrades the registry beacon: it answers the views
///      `TREXRegistry` reads and links exactly one wallet to one identity.
contract OtherIdentityFactoryStub {

    bytes32 private immutable _LINKED_WALLET_KEY;
    address private immutable _LINKED_IDENTITY;

    constructor(bytes memory linkedWallet, address linkedIdentity) {
        _LINKED_WALLET_KEY = keccak256(linkedWallet);
        _LINKED_IDENTITY = linkedIdentity;
    }

    function getIdentityIncludingRevoked(bytes calldata account)
        external
        view
        returns (address, IIdentityFactory.AccountStatus)
    {
        if (keccak256(account) == _LINKED_WALLET_KEY) {
            return (_LINKED_IDENTITY, IIdentityFactory.AccountStatus.Active);
        }
        return (address(0), IIdentityFactory.AccountStatus.None);
    }

    function getIdentity(bytes calldata account) external view returns (address) {
        if (keccak256(account) == _LINKED_WALLET_KEY) return _LINKED_IDENTITY;
        return address(0);
    }

    function getAccountStatus(bytes calldata account) external view returns (IIdentityFactory.AccountStatus) {
        if (keccak256(account) == _LINKED_WALLET_KEY) return IIdentityFactory.AccountStatus.Active;
        return IIdentityFactory.AccountStatus.None;
    }

    function identityTypeOf(address) external pure returns (uint256) {
        return 0;
    }

}

/// @dev The shipped rule, end to end. It is the reference every module author will copy, so it is exercised
///      through the whole lifecycle: a native transfer, a mint, a burn, an issuance, two validations racing
///      for the same cap, a discard, a late settlement that breaches, and a relocation between one identity's
///      own wallets. The rule keeps nothing: every number it decides from is the compliance's ledger.
contract MaxBalancePerIdentityModuleTest is InteropSuiteTest {

    uint256 internal constant CAP = 1000;
    uint256 internal constant BALANCE = 2000;

    MaxBalancePerIdentityModule internal rule;
    bytes internal aliceSat;
    bytes internal bobSat;

    function setUp() public override {
        super.setUp();
        _openEvmChain(token, POLYGON, address(_newTrustedGateway(POLYGON)));
        aliceSat = _fundSatelliteWallet(aliceIdentity, alice, POLYGON, makeAccount("aliceOnPolygon"), BALANCE);
        bobSat = _linkSatelliteWallet(bobIdentity, POLYGON, makeAccount("bobOnPolygon"));

        rule = MaxBalancePerIdentityModule(
            address(
                new ModuleProxy(
                    address(new MaxBalancePerIdentityModule()),
                    abi.encodeCall(MaxBalancePerIdentityModule.initialize, (address(accessManager)))
                )
            )
        );
        bytes[] memory settings = new bytes[](1);
        settings[0] = abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (CAP));
        vm.prank(deployer);
        boundCompliance.addAndSetModule(address(rule), settings);

        vm.prank(agent);
        token.unpause();
    }

    // ==== Declaration Tests ====

    function test_moduleTypes_NamesOnlyRule() public view {
        assertEq(rule.moduleTypes().length, 1);
        assertEq(uint8(rule.moduleTypes()[0]), uint8(IModule.ModuleType.RULE));
        assertEq(boundCompliance.getModulesByType(IModule.ModuleType.RULE)[0], address(rule));
        assertTrue(rule.isPlugAndPlay());
        assertEq(rule.name(), "MaxBalancePerIdentityModule");
    }

    function test_setMaxBalance_Success_WhenSetThroughTheCompliance() public {
        assertEq(rule.maxBalanceOf(address(boundCompliance)), CAP);

        vm.prank(deployer);
        boundCompliance.callModuleFunction(
            abi.encodeCall(MaxBalancePerIdentityModule.setMaxBalance, (CAP * 2)), address(rule)
        );

        assertEq(rule.maxBalanceOf(address(boundCompliance)), CAP * 2);
    }

    /// @notice The cap is scoped by the bind nonce: an unbind discards it, and a re-bind starts unset.
    function test_removeModule_DiscardsTheCap() public {
        vm.prank(deployer);
        boundCompliance.removeModule(address(rule));
        assertEq(rule.maxBalanceOf(address(boundCompliance)), 0);

        vm.prank(deployer);
        boundCompliance.addModule(address(rule));
        assertEq(rule.maxBalanceOf(address(boundCompliance)), 0);

        vm.prank(agent);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.mint(alice, 1);
    }

    function test_setMaxBalance_RevertWhen_CalledDirectly() public {
        vm.prank(deployer);
        vm.expectRevert(ErrorsLib.OnlyBoundComplianceCanCall.selector);
        rule.setMaxBalance(CAP);
    }

    // ==== Native movement Tests ====

    /// @notice A mint is allowed up to the cap and refused past it, counting what the identity already owns.
    function test_mint_Success_WhenUnderTheCap() public {
        vm.prank(agent);
        token.mint(bob, CAP);

        assertEq(_position(address(bobIdentity)), CAP);

        vm.prank(agent);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.mint(bob, 1);
    }

    /// @notice A transfer is narrowed by what the recipient already owns, not by what the sender sends.
    ///         Charlie is the sender: alice already holds a satellite position from the fixture, and the cap
    ///         judges the recipient alone.
    function test_transfer_RevertWhen_TheRecipientWouldExceedTheCap() public {
        vm.startPrank(agent);
        token.mint(charlie, CAP);
        token.mint(bob, CAP - 100);
        vm.stopPrank();

        vm.prank(charlie);
        token.transfer(bob, 100);
        assertEq(_position(address(bobIdentity)), CAP);

        vm.prank(charlie);
        vm.expectRevert(ERC3643ErrorsLib.ComplianceNotFollowed.selector);
        token.transfer(bob, 1);
    }

    /// @notice The cap can be priced against a stale position only if a funded wallet changes identity, so that its
    ///         balance has not followed yet when the rules run. Every registry path that could do that is
    ///         refused, so bob's balance stays bob's and charlie's position is the one the cap reads.
    function test_registry_CannotRelinkAFundedWallet_SoTheCapNeverReadsAStalePosition() public {
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        uint256 sixtyPercentOfCap = CAP * 6 / 10;
        vm.startPrank(agent);
        token.mint(charlie, sixtyPercentOfCap);
        token.mint(bob, sixtyPercentOfCap);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, bob, address(bobIdentity))
        );
        registry.updateIdentity(bob, charlieIdentity);

        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.WalletBoundToAnotherIdentity.selector, bob, address(bobIdentity))
        );
        registry.registerIdentity(bob, charlieIdentity, 0);

        vm.expectRevert(ErrorsLib.Deprecated.selector);
        registry.setIdentityRegistryStorage(makeAddr("anotherStorage"));

        registry.deleteIdentity(bob);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.WalletAlreadyRevoked.selector, bob));
        registry.registerIdentity(bob, charlieIdentity, 0);
        vm.stopPrank();

        assertEq(address(registry.identity(bob)), address(bobIdentity));
        assertEq(_position(address(bobIdentity)), sixtyPercentOfCap);
        assertEq(_position(address(charlieIdentity)), sixtyPercentOfCap);
    }

    /// @notice The one path left that can relink a funded wallet is an admin upgrading the registry beacon to an
    ///         implementation on another IdentityFactory. The cap would then be priced against the new identity's
    ///         empty position while the wallet's balance followed unchecked. The ledger refuses instead: the wallet
    ///         cannot move until the registry names the owner the ledger credited.
    function test_registryUpgradeToAnotherFactory_RevertWhen_AFundedWalletWouldChangeIdentity() public {
        address walletViaFactory = makeAddr("walletViaFactory");
        IIdentity identityA = _deployIdentity(walletViaFactory, "walletViaFactory");
        uint256 sixtyPercentOfCap = CAP * 6 / 10;
        vm.prank(agent);
        token.mint(walletViaFactory, sixtyPercentOfCap);
        address identityB = makeAddr("identityB");
        OtherIdentityFactoryStub otherFactory = new OtherIdentityFactoryStub(
            InteroperableAddress.formatEvmV1(block.chainid, walletViaFactory), identityB
        );
        ITREXImplementationAuthority.SuiteImplementations memory implementations = _suiteImplementations();
        implementations.trexRegistryImplementation = address(new TREXRegistry(address(otherFactory)));
        Version next = VersionLib.pack(5, 0, 1);
        vm.prank(deployer);
        trexImplementationAuthority.publishAndUpgrade(next, implementations);
        TREXRegistry registry = TREXRegistry(address(token.identityRegistry()));
        assertEq(address(registry.identity(walletViaFactory)), identityB, "the wallet now resolves to B");

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.WalletBoundToAnotherIdentity.selector, walletViaFactory, address(identityA)
            )
        );
        token.mint(walletViaFactory, sixtyPercentOfCap);

        assertEq(_position(address(identityA)), sixtyPercentOfCap, "the position stays with the credited owner");
        assertEq(_position(identityB), 0, "nothing landed on B");
        assertEq(token.balanceOf(walletViaFactory), sixtyPercentOfCap);
    }

    /// @notice A burn is never limited: it lowers a position, so no cap can be breached by one.
    function test_burn_Success_WhenTheSenderIsAtTheCap() public {
        vm.prank(agent);
        token.mint(bob, CAP);

        vm.prank(agent);
        token.burn(bob, CAP);

        assertEq(_position(address(bobIdentity)), 0);
    }

    /// @notice Two wallets of one identity: a relocation changes no position, so the cap does not apply.
    ///         Charlie's second wallet is used, since alice already holds a satellite position here.
    function test_transfer_Success_WhenRelocatingBetweenOwnWallets() public {
        address charlieSecond = makeAddr("charlieSecondWallet");
        vm.startPrank(agent);
        token.identityRegistry().registerIdentity(charlieSecond, charlieIdentity, 1);
        token.mint(charlie, CAP);
        vm.stopPrank();

        vm.prank(charlie);
        token.transfer(charlieSecond, CAP);

        assertEq(_position(address(charlieIdentity)), CAP, "a relocation is not a change of ownership");
    }

    // ==== Cross-chain Tests ====

    /// @notice An issuance is narrowed to the room left under the cap, with no hook on the module.
    function test_requestTransferValidation_Success_WhenNarrowedToTheRoomLeft() public {
        vm.prank(agent);
        token.mint(bob, CAP - 300);

        uint256 id = _issue(10, CAP);

        assertEq(boundCompliance.validationOf(id).amountMax, 300, "narrowed to what is left under the cap");
    }

    /// @notice Two validations racing for one cap: the second sees the first one's reservation, which is the
    ///         case a module keeping its own counter used to get wrong.
    function test_requestTransferValidation_Success_WhenTwoValidationsRaceForTheCap() public {
        uint256 first = _issue(10, 600);
        assertEq(boundCompliance.validationOf(first).amountMax, 600);

        uint256 second = _issue(10, 600);

        assertEq(boundCompliance.validationOf(second).amountMax, 400, "the cap is shared, not doubled");
        assertEq(_ledger().pendingInOf(address(bobIdentity)), CAP);
    }

    /// @notice A discard gives the room back, so the next validation gets the whole cap again.
    function test_discardExpiredValidations_Success_WhenTheRoomComesBack() public {
        uint256 id = _issue(10, CAP);
        vm.warp(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);

        assertEq(boundCompliance.validationOf(_issue(10, CAP)).amountMax, CAP);
    }

    /// @notice A settlement turns the reservation into a position, and the rule narrows against it afterwards.
    function test_handleSettlement_Success_WhenTheExecutedAmountBecomesAPosition() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        uint256 id = _issue(10, 600);

        gateway.relay(_liteSettles(gateway, token, _settlement(id, aliceSat, bobSat, 400)));

        assertEq(_position(address(bobIdentity)), 400);
        assertEq(_ledger().pendingInOf(address(bobIdentity)), 0);
        assertEq(boundCompliance.validationOf(_issue(10, CAP)).amountMax, 600, "the rest of the cap is free");
    }

    /// @notice A late settlement above what the rule allows now is applied and reported, pausing that chain.
    function test_handleSettlement_Success_WhenALateSettlementBreachesTheCap() public {
        ERC7786GatewayMock gateway = ERC7786GatewayMock(token.routeFor(polygon));
        uint256 late = _issue(10, CAP);
        vm.warp(block.timestamp + VALIDITY_WINDOW + POLYGON_WINDOW + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = late;
        vm.prank(keeper);
        boundCompliance.discardExpiredValidations(ids);

        _issue(10, CAP);

        gateway.relay(_liteSettles(gateway, token, _settlement(late, aliceSat, bobSat, CAP)));

        assertEq(_position(address(bobIdentity)), CAP, "applied regardless: the satellite already executed it");
        assertTrue(boundCompliance.isIssuancePaused(polygon), "the origin chain stopped issuing");
        assertEq(uint8(boundCompliance.statusOf(late)), uint8(ITransferValidation.ValidationStatus.LateReconciled));
    }

    // ==== Helpers ====

    function _issue(uint256 min, uint256 max) private returns (uint256) {
        return _requestValidation(address(aliceIdentity), aliceSat, bobSat, min, max);
    }

    function _ledger() private view returns (IComplianceLedger) {
        return IComplianceLedger(address(boundCompliance));
    }

    function _position(address identity) private view returns (uint256) {
        return _ledger().positionOf(identity);
    }

}

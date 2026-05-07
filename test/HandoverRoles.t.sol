// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {HandoverRoles} from "../script/deploy/HandoverRoles.s.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";

contract HandoverRolesTest is Test {
    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    Treasury private treasury;
    HandoverRoles private script;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    address private deployer;
    address private govSafe = address(0xCAFEBABE);

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.startPrank(deployer);
        k613 = new K613(deployer);
        xk613 = new xK613(deployer);
        staking = new Staking(address(k613), address(xk613), 7 days, 5_000);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), 7 days);
        treasury = new Treasury(address(k613), address(xk613), address(staking), address(distributor));
        // mirror DeployK613.s.sol wiring: xK613 minter = Staking
        xk613.setMinter(address(staking));
        vm.stopPrank();

        script = new HandoverRoles();
    }

    /// @notice testRunWith_GovHasAllRolesAfter: after handover, Governance Safe holds DEFAULT_ADMIN + PAUSER on all 5.
    function testRunWith_GovHasAllRolesAfter() public {
        _runScript();

        assertTrue(k613.hasRole(DEFAULT_ADMIN_ROLE, govSafe), "K613 admin -> Safe");
        assertTrue(k613.hasRole(PAUSER_ROLE, govSafe), "K613 pauser -> Safe");
        assertTrue(xk613.hasRole(DEFAULT_ADMIN_ROLE, govSafe), "xK613 admin -> Safe");
        assertTrue(xk613.hasRole(PAUSER_ROLE, govSafe), "xK613 pauser -> Safe");
        assertTrue(staking.hasRole(DEFAULT_ADMIN_ROLE, govSafe), "Staking admin -> Safe");
        assertTrue(staking.hasRole(PAUSER_ROLE, govSafe), "Staking pauser -> Safe");
        assertTrue(distributor.hasRole(DEFAULT_ADMIN_ROLE, govSafe), "RD admin -> Safe");
        assertTrue(distributor.hasRole(PAUSER_ROLE, govSafe), "RD pauser -> Safe");
        assertTrue(treasury.hasRole(DEFAULT_ADMIN_ROLE, govSafe), "Treasury admin -> Safe");
        assertTrue(treasury.hasRole(PAUSER_ROLE, govSafe), "Treasury pauser -> Safe");
    }

    /// @notice testRunWith_DeployerLosesAllRolesAfter: after handover, deployer holds NO admin/pauser on any of 5.
    function testRunWith_DeployerLosesAllRolesAfter() public {
        _runScript();

        assertFalse(k613.hasRole(DEFAULT_ADMIN_ROLE, deployer), "K613 admin revoked");
        assertFalse(k613.hasRole(PAUSER_ROLE, deployer), "K613 pauser revoked");
        assertFalse(xk613.hasRole(DEFAULT_ADMIN_ROLE, deployer), "xK613 admin revoked");
        assertFalse(xk613.hasRole(PAUSER_ROLE, deployer), "xK613 pauser revoked");
        assertFalse(staking.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Staking admin revoked");
        assertFalse(staking.hasRole(PAUSER_ROLE, deployer), "Staking pauser revoked");
        assertFalse(distributor.hasRole(DEFAULT_ADMIN_ROLE, deployer), "RD admin revoked");
        assertFalse(distributor.hasRole(PAUSER_ROLE, deployer), "RD pauser revoked");
        assertFalse(treasury.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Treasury admin revoked");
        assertFalse(treasury.hasRole(PAUSER_ROLE, deployer), "Treasury pauser revoked");
    }

    /// @notice testRunWith_K613MinterRotatedToSafe: K613.minter() and MINTER_ROLE moved from deployer to govSafe.
    function testRunWith_K613MinterRotatedToSafe() public {
        // sanity: deployer is initial minter
        assertTrue(k613.hasRole(k613.MINTER_ROLE(), deployer));
        assertEq(k613.minter(), deployer);

        _runScript();

        assertEq(k613.minter(), govSafe, "K613.minter() pointer to Safe");
        assertTrue(k613.hasRole(k613.MINTER_ROLE(), govSafe), "Safe has MINTER_ROLE");
        assertFalse(k613.hasRole(k613.MINTER_ROLE(), deployer), "deployer no longer has MINTER_ROLE");
    }

    /// @notice testRunWith_xK613MinterUntouched: xK613.minter() must remain Staking — script must NOT touch it.
    function testRunWith_xK613MinterUntouched() public {
        // sanity: setUp set xK613.minter = Staking
        assertEq(xk613.minter(), address(staking));

        _runScript();

        assertEq(xk613.minter(), address(staking), "xK613 minter unchanged (must stay on Staking)");
        assertTrue(xk613.hasRole(xk613.MINTER_ROLE(), address(staking)), "Staking still has xK613 MINTER_ROLE");
    }

    /// @notice testRunWith_ZeroAddressReverts: any zero target or zero govSafe must revert.
    function testRunWith_ZeroAddressReverts() public {
        vm.expectRevert(HandoverRoles.ZeroAddress.selector);
        script.runWith(
            address(0), address(xk613), address(staking), address(distributor), address(treasury), govSafe, DEPLOYER_PK
        );
        vm.expectRevert(HandoverRoles.ZeroAddress.selector);
        script.runWith(
            address(k613),
            address(xk613),
            address(staking),
            address(distributor),
            address(treasury),
            address(0),
            DEPLOYER_PK
        );
    }

    /// @notice testRunWith_CallerLacksAdminReverts: pk that doesn't hold admin role on any contract is rejected pre-broadcast.
    function testRunWith_CallerLacksAdminReverts() public {
        uint256 randomPk = 0xDEADBEEF;
        address random = vm.addr(randomPk);
        vm.expectRevert(abi.encodeWithSelector(HandoverRoles.CallerLacksAdmin.selector, address(k613), random));
        script.runWith(
            address(k613), address(xk613), address(staking), address(distributor), address(treasury), govSafe, randomPk
        );
    }

    /// @notice testRunWith_GovSafeCanPauseAfterHandover: end-to-end check — Safe can actually exercise its new authority.
    function testRunWith_GovSafeCanPauseAfterHandover() public {
        _runScript();

        vm.prank(govSafe);
        k613.pause();
        assertTrue(k613.paused());
    }

    function _runScript() internal {
        script.runWith(
            address(k613),
            address(xk613),
            address(staking),
            address(distributor),
            address(treasury),
            govSafe,
            DEPLOYER_PK
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613S1} from "../src/token/K613S1.sol";
import {K613S1Distributor} from "../src/campaign/K613S1Distributor.sol";
import {DeployCampaignTestnet} from "../script/deploy/DeployCampaignTestnet.s.sol";

contract DeployCampaignTestnetTest is Test {
    DeployCampaignTestnet private script;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    uint256 private constant ARBITRUM_SEPOLIA = 421614;
    uint256 private constant EXPECTED_CAP = 5_000_000e18;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address private deployer;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        script = new DeployCampaignTestnet();
    }

    /// @notice On Arbitrum Sepolia the script deploys both contracts and wires MINTER_ROLE.
    function testRunWith_DeploysAndWiresMinterRole() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        script.runWith(DEPLOYER_PK);

        K613S1 k613s1 = K613S1(script.k613s1Addr());
        K613S1Distributor distributor = K613S1Distributor(script.distributorAddr());

        assertTrue(script.k613s1Addr() != address(0), "K613S1 deployed");
        assertTrue(script.distributorAddr() != address(0), "Distributor deployed");
        assertEq(address(distributor.k613s1()), script.k613s1Addr(), "Distributor points at K613S1");
        assertEq(distributor.weeklyMintCap(), EXPECTED_CAP, "weekly mint cap = 5M");
        assertTrue(k613s1.hasRole(MINTER_ROLE, script.distributorAddr()), "Distributor has MINTER_ROLE");
    }

    /// @notice All roles remain on the deployer EOA (OPERATOR_ROLE needed for B's post-root).
    function testRunWith_AllRolesOnDeployer() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        script.runWith(DEPLOYER_PK);

        K613S1 k613s1 = K613S1(script.k613s1Addr());
        K613S1Distributor distributor = K613S1Distributor(script.distributorAddr());

        assertTrue(k613s1.hasRole(DEFAULT_ADMIN_ROLE, deployer), "K613S1 admin -> deployer");
        assertTrue(k613s1.hasRole(PAUSER_ROLE, deployer), "K613S1 pauser -> deployer");
        assertTrue(distributor.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Distributor admin -> deployer");
        assertTrue(distributor.hasRole(PAUSER_ROLE, deployer), "Distributor pauser -> deployer");
        assertTrue(distributor.hasRole(OPERATOR_ROLE, deployer), "Distributor operator -> deployer");
    }

    /// @notice On any non-Arbitrum-Sepolia chain the script reverts WrongNetwork.
    function testRunWith_RevertsOnWrongNetwork() public {
        vm.chainId(143); // Monad mainnet
        vm.expectRevert(abi.encodeWithSelector(DeployCampaignTestnet.WrongNetwork.selector, uint256(143)));
        script.runWith(DEPLOYER_PK);
    }
}

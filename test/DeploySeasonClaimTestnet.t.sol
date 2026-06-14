// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {K613S1} from "../src/token/K613S1.sol";
import {K613SeasonClaim} from "../src/campaign/K613SeasonClaim.sol";
import {DeploySeasonClaimTestnet} from "../script/deploy/DeploySeasonClaimTestnet.s.sol";

contract DeploySeasonClaimTestnetTest is Test {
    DeploySeasonClaimTestnet private script;
    K613 private k613;
    K613S1 private k613s1;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    uint256 private constant ARBITRUM_SEPOLIA = 421614;
    bytes32 private constant ROOT = bytes32(uint256(0xBEEF));
    uint256 private constant TGE = 2_000_000_000; // some future-ish timestamp

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant BURNER_ROLE = keccak256("BURNER_ROLE");

    address private deployer;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.startPrank(deployer);
        k613 = new K613(deployer);
        k613s1 = new K613S1(); // deployer gets K613S1 DEFAULT_ADMIN_ROLE
        vm.stopPrank();
        script = new DeploySeasonClaimTestnet();
    }

    function _run() internal {
        script.runWith(address(k613), address(k613s1), ROOT, TGE, deployer, DEPLOYER_PK);
    }

    /// @notice On Arbitrum Sepolia: deploys SeasonClaim, wires it correctly, grants BURNER_ROLE.
    function testRunWith_DeploysAndWiresBurnerRole() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        _run();

        K613SeasonClaim sc = K613SeasonClaim(script.seasonClaimAddr());

        assertTrue(script.seasonClaimAddr() != address(0), "SeasonClaim deployed");
        assertEq(address(sc.k613()), address(k613), "k613 wired");
        assertEq(address(sc.k613s1()), address(k613s1), "k613s1 wired");
        assertEq(sc.merkleRoot(), ROOT, "merkle root set");
        assertEq(sc.tgeTimestamp(), TGE, "tge set");
        assertEq(sc.claimDeadline(), TGE + 365 days, "claim deadline = tge + 365d");
        assertTrue(k613s1.hasRole(BURNER_ROLE, script.seasonClaimAddr()), "SeasonClaim has BURNER_ROLE");
    }

    /// @notice Admin (deployer on testnet) holds DEFAULT_ADMIN_ROLE + PAUSER_ROLE on SeasonClaim.
    function testRunWith_AdminRolesOnDeployer() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        _run();

        K613SeasonClaim sc = K613SeasonClaim(script.seasonClaimAddr());
        assertTrue(sc.hasRole(DEFAULT_ADMIN_ROLE, deployer), "SeasonClaim admin -> deployer");
        assertTrue(sc.hasRole(PAUSER_ROLE, deployer), "SeasonClaim pauser -> deployer");
    }

    /// @notice On any non-Arbitrum-Sepolia chain the script reverts WrongNetwork.
    function testRunWith_RevertsOnWrongNetwork() public {
        vm.chainId(143); // Monad mainnet
        vm.expectRevert(abi.encodeWithSelector(DeploySeasonClaimTestnet.WrongNetwork.selector, uint256(143)));
        _run();
    }

    /// @notice A zero Merkle root must propagate the contract's EmptyMerkleRoot revert (not be swallowed).
    function testRunWith_RevertsOnZeroMerkleRoot() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        vm.expectRevert(K613SeasonClaim.EmptyMerkleRoot.selector);
        script.runWith(address(k613), address(k613s1), bytes32(0), TGE, deployer, DEPLOYER_PK);
    }
}

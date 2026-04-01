// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

// Aave interfaces
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);
}

// Minimal DataTypes
library DataTypes {
    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        bool isActive;
        bool isFrozen;
    }

    struct ReserveConfigurationMap {
        uint256 data;
    }
}

/// @title FullLendingEconomyCycle
contract FullLendingEconomyCycle is Script {
    // === CONFIG ===
    uint256 private constant LOCK_DURATION = 120;
    uint256 private constant EPOCH_DURATION = 120;
    uint256 private constant INSTANT_EXIT_PENALTY_BPS = 5000;

    address private constant SUPPLY_TOKEN = address(0);
    address private constant BORROW_TOKEN = address(0);
    address private constant AAVE_POOL = address(0);

    // Time periods
    uint256 private constant CYCLE_1_DURATION = 7 days;
    uint256 private constant CYCLE_2_DURATION = 7 days;
    uint256 private constant CYCLE_3_DURATION = 7 days;

    // Initial amounts
    uint256 private constant ADMIN_K613 = 10_000_000 ether;
    uint256 private constant USER_A_COLLATERAL = 100_000 ether; // Supply to Aave
    uint256 private constant USER_A_STAKE = 50_000 ether; // Stake K613
    uint256 private constant USER_B_BORROW = 50_000 ether; // Borrow from Aave

    // === PROTOCOL STATE ===
    struct ProtocolState {
        K613 k613;
        xK613 xk613;
        Staking staking;
        RewardsDistributor rd;
        Treasury treasury;
        IPool aavePool;
        address supplyToken;
        address borrowToken;
    }

    struct UserState {
        address addr;
        uint256 k613;
        uint256 xk613;
        uint256 stakingDeposit;
        uint256 aaveCollateral; // aToken balance
        uint256 aaveBorrow; // Debt balance
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("=== K613 + AAVE FULL LENDING CYCLE ===");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(pk);

        // 1. Deploy K613 stack
        ProtocolState memory protocol = _deploy(deployer);

        // 2. Setup - mint tokens
        _setupInitial(protocol, deployer);

        // 3. CYCLE 1: Supply, Borrow, Stake
        console.log("");
        console.log("========== CYCLE 1: SUPPLY & BORROW ==========");
        _cycle1SupplyAndBorrow(protocol, deployer);
        _printStateAfterCycle1(protocol, deployer);

        // 4. Warp time - rewards accrue
        console.log("");
        console.log("--- Warping 7 days ---");
        vm.warp(block.timestamp + CYCLE_1_DURATION);

        // 5. CYCLE 2: Claim rewards, recompound, admin buyback
        console.log("");
        console.log("========== CYCLE 2: CLAIM & COMPOUND ==========");
        _cycle2ClaimRewards(protocol, deployer);
        _printStateAfterCycle2(protocol, deployer);

        // 6. Warp time again
        console.log("");
        console.log("--- Warping 7 more days ---");
        vm.warp(block.timestamp + CYCLE_2_DURATION);

        // 7. CYCLE 3: Claim staking rewards, initiate exits
        console.log("");
        console.log("========== CYCLE 3: STAKING REWARDS & EXITS ==========");
        _cycle3StakingRewards(protocol, deployer);
        _printStateAfterCycle3(protocol, deployer);

        // 8. Warp time final
        console.log("");
        console.log("--- Warping 7 final days ---");
        vm.warp(block.timestamp + CYCLE_3_DURATION);

        // 9. Final state
        console.log("");
        console.log("========== FINAL STATE ==========");
        _printFinalState(protocol, deployer);

        vm.stopBroadcast();
    }

    // ============================================================================
    // DEPLOYMENT
    // ============================================================================
    function _deploy(address deployer) internal returns (ProtocolState memory) {
        console.log("--- Deploying K613 Stack ---");

        K613 k613 = new K613(deployer);
        xK613 xk613 = new xK613(deployer);
        Staking staking = new Staking(address(k613), address(xk613), LOCK_DURATION, INSTANT_EXIT_PENALTY_BPS);
        RewardsDistributor rd = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH_DURATION);
        Treasury treasury = new Treasury(address(k613), address(xk613), address(staking), address(rd));

        xk613.setMinter(address(staking));
        xk613.setTransferWhitelist(address(rd), true);
        xk613.setTransferWhitelist(address(staking), true);
        xk613.setTransferWhitelist(address(treasury), true);

        staking.setRewardsDistributor(address(rd));
        rd.setStaking(address(staking));
        rd.grantRole(rd.REWARDS_NOTIFIER_ROLE(), address(treasury));

        return ProtocolState({
            k613: k613,
            xk613: xk613,
            staking: staking,
            rd: rd,
            treasury: treasury,
            aavePool: IPool(vm.envAddress("AAVE_POOL_ADDRESS")),
            supplyToken: vm.envAddress("SUPPLY_TOKEN_ADDRESS"),
            borrowToken: vm.envAddress("BORROW_TOKEN_ADDRESS")
        });
    }

    function _setupInitial(ProtocolState memory protocol, address admin) internal {
        console.log("--- Initial Setup ---");

        // Mint K613 for admin
        protocol.k613.mint(admin, ADMIN_K613);
        console.log("Admin K613:", ADMIN_K613 / 1 ether);

        // Mint supply token for users (if K613 is supply token)
        // For now assume they have supply tokens already
    }

    // ============================================================================
    // CYCLE 1: SUPPLY & BORROW
    // ============================================================================
    function _cycle1SupplyAndBorrow(ProtocolState memory protocol, address admin) internal {
        address userA = address(0xAAAA);
        address userB = address(0xBBBB);

        console.log("--- User A: Supply to Aave & Stake K613 ---");

        // User A supplies collateral to Aave
        vm.prank(admin);
        IERC20(protocol.supplyToken).transfer(userA, USER_A_COLLATERAL);

        vm.prank(userA);
        IERC20(protocol.supplyToken).approve(address(protocol.aavePool), USER_A_COLLATERAL);
        vm.prank(userA);
        protocol.aavePool.supply(protocol.supplyToken, USER_A_COLLATERAL, userA, 0);
        console.log("User A supplied:", USER_A_COLLATERAL / 1 ether);

        // User A stakes K613
        vm.prank(admin);
        protocol.k613.transfer(userA, USER_A_STAKE);

        vm.prank(userA);
        protocol.k613.approve(address(protocol.staking), USER_A_STAKE);
        vm.prank(userA);
        protocol.staking.stake(USER_A_STAKE);
        console.log("User A staked K613:", USER_A_STAKE / 1 ether);

        // User A deposits xK613 to RewardsDistributor
        (uint256 stakedAmount,) = protocol.staking.deposits(userA);
        vm.prank(userA);
        IERC20(address(protocol.xk613)).approve(address(protocol.rd), stakedAmount);
        vm.prank(userA);
        protocol.rd.deposit(stakedAmount);
        console.log("User A RD deposit:", stakedAmount / 1 ether);

        console.log("");
        console.log("--- User B: Borrow from Aave ---");

        // User B needs to have supply token to deposit as collateral first
        vm.prank(admin);
        IERC20(protocol.supplyToken).transfer(userB, USER_B_BORROW * 2); // 2x for collateral

        // User B supplies collateral
        vm.prank(userB);
        IERC20(protocol.supplyToken).approve(address(protocol.aavePool), USER_B_BORROW * 2);
        vm.prank(userB);
        protocol.aavePool.supply(protocol.supplyToken, USER_B_BORROW * 2, userB, 0);
        console.log("User B supplied collateral:", USER_B_BORROW * 2 / 1 ether);

        // User B borrows
        vm.prank(userB);
        protocol.aavePool.borrow(protocol.borrowToken, USER_B_BORROW, 2, 0, userB); // 2 = variable rate
        console.log("User B borrowed:", USER_B_BORROW / 1 ether);

        // Admin deposits rewards
        console.log("");
        console.log("--- Admin: Deposit Treasury Rewards ---");
        uint256 rewardAmount = 10_000 ether;
        vm.prank(admin);
        protocol.k613.approve(address(protocol.treasury), rewardAmount);
        vm.prank(admin);
        protocol.treasury.depositRewards(rewardAmount);
        console.log("Treasury reward:", rewardAmount / 1 ether);
    }

    // ============================================================================
    // CYCLE 2: CLAIM REWARDS & COMPOUND
    // ============================================================================
    function _cycle2ClaimRewards(ProtocolState memory protocol, address admin) internal {
        address userA = address(0xAAAA);
        address userB = address(0xBBBB);

        console.log("--- Claim RD Rewards ---");

        // Advance epoch
        protocol.rd.advanceEpoch();

        // User A claims
        uint256 userAPending = protocol.rd.pendingRewardsOf(userA);
        if (userAPending > 0) {
            vm.prank(userA);
            protocol.rd.claim();
            console.log("User A claimed:", userAPending / 1 ether);
        }

        // User B claims
        uint256 userBPending = protocol.rd.pendingRewardsOf(userB);
        if (userBPending > 0) {
            vm.prank(userB);
            protocol.rd.claim();
            console.log("User B claimed:", userBPending / 1 ether);
        }

        console.log("");
        console.log("--- User B: Instant Exit (penalty) ---");

        // User B does instant exit on partial rewards
        uint256 userBxK613 = IERC20(address(protocol.xk613)).balanceOf(userB);
        if (userBxK613 > 0) {
            uint256 exitAmount = userBxK613 / 2; // Exit half
            vm.prank(userB);
            IERC20(address(protocol.xk613)).approve(address(protocol.staking), exitAmount);
            vm.prank(userB);
            protocol.staking.initiateExit(exitAmount);

            // Wait 1 day and do instant exit
            vm.warp(block.timestamp + 1 days);
            vm.prank(userB);
            protocol.staking.instantExit(0);
            console.log("User B instant exit:", exitAmount / 1 ether);
        }

        console.log("");
        console.log("--- Admin: Buyback Simulation ---");
        // Simulate collecting fees and doing buyback
        uint256 feeAmount = 1_000 ether;
        if (protocol.k613.balanceOf(admin) > feeAmount) {
            vm.prank(admin);
            protocol.k613.approve(address(protocol.staking), feeAmount);
            vm.prank(admin);
            protocol.staking.stake(feeAmount);
            console.log("Admin staked (buyback simulation):", feeAmount / 1 ether);
        }

        console.log("");
        console.log("--- Recompound: Deposit back to RD ---");

        // User A re-deposits to RD
        uint256 userARDBalance = protocol.rd.balanceOf(userA);
        if (userARDBalance > 0) {
            vm.prank(userA);
            protocol.rd.withdraw(userARDBalance);

            (uint256 userAStaked,) = protocol.staking.deposits(userA);
            vm.prank(userA);
            IERC20(address(protocol.xk613)).approve(address(protocol.rd), userAStaked);
            vm.prank(userA);
            protocol.rd.deposit(userAStaked);
            console.log("User A recompound:", userAStaked / 1 ether);
        }
    }

    // ============================================================================
    // CYCLE 3: STAKING REWARDS & EXITS
    // ============================================================================
    function _cycle3StakingRewards(ProtocolState memory protocol, address admin) internal {
        address userA = address(0xAAAA);

        console.log("--- Now Staking Rewards Available ---");
        console.log("From penalties + admin buyback stake");

        // Advance epoch for staking rewards
        protocol.rd.advanceEpoch();

        console.log("");
        console.log("--- User A: Claim Staking Rewards & Initiate Exit ---");

        uint256 userAPending = protocol.rd.pendingRewardsOf(userA);
        if (userAPending > 0) {
            vm.prank(userA);
            protocol.rd.claim();
            console.log("User A staking rewards claimed:", userAPending / 1 ether);
        }

        // User A initiates exit
        (uint256 userAStaked,) = protocol.staking.deposits(userA);
        if (userAStaked > 0) {
            uint256 userAxK613 = IERC20(address(protocol.xk613)).balanceOf(userA);
            if (userAxK613 >= userAStaked) {
                vm.prank(userA);
                IERC20(address(protocol.xk613)).approve(address(protocol.staking), userAStaked);
                vm.prank(userA);
                protocol.staking.initiateExit(userAStaked);
                console.log("User A initiated exit:", userAStaked / 1 ether);

                // Wait for lock period
                vm.warp(block.timestamp + LOCK_DURATION);
                vm.prank(userA);
                protocol.staking.exit(0);
                console.log("User A exited after lock period");
            }
        }

        console.log("");
        console.log("--- User A: Repay Borrow (if applicable) ---");
        // Note: User A only supplied, didn't borrow. User B borrowed.
    }

    // ============================================================================
    // REPORTING
    // ============================================================================
    function _printStateAfterCycle1(ProtocolState memory protocol, address admin) internal view {
        address userA = address(0xAAAA);
        address userB = address(0xBBBB);

        console.log("");
        console.log("=== STATE AFTER CYCLE 1 ===");

        console.log("Admin K613:", protocol.k613.balanceOf(admin) / 1 ether);

        (uint256 userAStaked,) = protocol.staking.deposits(userA);
        console.log("UserA K613:", protocol.k613.balanceOf(userA) / 1 ether);
        console.log("UserA xK613:", IERC20(address(protocol.xk613)).balanceOf(userA) / 1 ether);
        console.log("UserA staked:", userAStaked / 1 ether);
        console.log("UserA RD deposit:", protocol.rd.balanceOf(userA) / 1 ether);

        console.log("UserB K613:", protocol.k613.balanceOf(userB) / 1 ether);

        console.log("Protocol staking backing:", protocol.staking.totalBacking() / 1 ether);
        console.log("Protocol RD deposits:", protocol.rd.totalDeposits() / 1 ether);
    }

    function _printStateAfterCycle2(ProtocolState memory protocol, address admin) internal view {
        address userA = address(0xAAAA);
        address userB = address(0xBBBB);

        console.log("");
        console.log("=== STATE AFTER CYCLE 2 ===");

        (uint256 userAStaked,) = protocol.staking.deposits(userA);
        console.log("UserA K613:", protocol.k613.balanceOf(userA) / 1 ether);
        console.log("UserA xK613:", IERC20(address(protocol.xk613)).balanceOf(userA) / 1 ether);
        console.log("UserA RD deposit:", protocol.rd.balanceOf(userA) / 1 ether);

        console.log("UserB K613:", protocol.k613.balanceOf(userB) / 1 ether);
        console.log("UserB xK613:", IERC20(address(protocol.xk613)).balanceOf(userB) / 1 ether);

        console.log("Protocol RD pending rewards:", protocol.rd.pendingRewards() / 1 ether);
    }

    function _printStateAfterCycle3(ProtocolState memory protocol, address admin) internal view {
        address userA = address(0xAAAA);

        console.log("");
        console.log("=== STATE AFTER CYCLE 3 ===");

        (uint256 userAStaked,) = protocol.staking.deposits(userA);
        console.log("UserA K613:", protocol.k613.balanceOf(userA) / 1 ether);
        console.log("UserA xK613:", IERC20(address(protocol.xk613)).balanceOf(userA) / 1 ether);
        console.log("UserA staked:", userAStaked / 1 ether);

        console.log("Protocol staking backing:", protocol.staking.totalBacking() / 1 ether);
    }

    function _printFinalState(ProtocolState memory protocol, address admin) internal view {
        address userA = address(0xAAAA);
        address userB = address(0xBBBB);

        console.log("Admin K613:", protocol.k613.balanceOf(admin) / 1 ether);
        console.log("UserA K613:", protocol.k613.balanceOf(userA) / 1 ether);
        console.log("UserB K613:", protocol.k613.balanceOf(userB) / 1 ether);

        console.log("K613 totalSupply:", IERC20(address(protocol.k613)).totalSupply() / 1 ether);
        console.log("xK613 totalSupply:", IERC20(address(protocol.xk613)).totalSupply() / 1 ether);

        console.log("Protocol staking backing:", protocol.staking.totalBacking() / 1 ether);
    }
}

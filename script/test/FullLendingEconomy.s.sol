// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {K613} from "src/token/K613.sol";
import {xK613} from "src/token/xK613.sol";
import {Staking} from "src/staking/Staking.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {DataTypes} from "lib/L2-Protocol/src/contracts/protocol/libraries/types/DataTypes.sol";

interface IPool {
    function ADDRESSES_PROVIDER() external view returns (address);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function getReserveData(address asset) external view returns (DataTypes.ReserveDataLegacy memory);
}

interface IPoolAddressesProviderLite {
    function getAddress(bytes32 id) external view returns (address);
}

interface IRewardsControllerLite {
    function claimRewards(address[] calldata assets, uint256 amount, address to, address reward)
        external
        returns (uint256);
    function getUserRewards(address[] calldata assets, address user, address reward) external view returns (uint256);
    function getRewardsByAsset(address asset) external view returns (address[] memory);
}

contract FullLendingEconomyCycle is Script {
    uint256 private constant PHASE_WARP = 7 days;
    uint256 private constant USER_A_STAKE = 50_000 ether;
    uint256 private constant TREASURY_REWARD = 10_000 ether;
    uint256 private constant ADMIN_BUYBACK_STAKE = 1_000 ether;

    uint256 private constant DEPLOY_LOCK_DURATION = 120;
    uint256 private constant DEPLOY_EPOCH_DURATION = 120;
    uint256 private constant DEPLOY_INSTANT_EXIT_PENALTY_BPS = 5000;
    uint256 private constant ARBITRUM_SEPOLIA = 421_614;

    bytes32 private constant INCENTIVES_CONTROLLER_ID = keccak256("INCENTIVES_CONTROLLER");

    struct ProtocolState {
        K613 k613;
        xK613 xk613;
        Staking staking;
        RewardsDistributor rd;
        Treasury treasury;
        IPool aavePool;
        address supplyToken;
        address borrowToken;
        address userA;
        address userB;
    }

    function run() external {
        _maybeSelectForkLatest();

        uint256 adminPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(adminPk);

        ProtocolState memory protocol;
        if (vm.envOr("FULL_LENDING_DEPLOY", uint256(0)) != 0) {
            vm.startBroadcast(adminPk);
            protocol = _deployNearProd(deployer);
            vm.stopBroadcast();
            console.log("FULL_LENDING_DEPLOY: set K613_ADDRESS, XK613_ADDRESS, STAKING_ADDRESS, etc. from logs above");
        } else {
            protocol = _loadProtocolFromEnv();
        }

        (address userAAddr, uint256 userAPk) = _resolveUserA(deployer, adminPk, protocol.userA);
        (address userBAddr, uint256 userBPk) = _resolveUserB(deployer, adminPk, userAAddr, protocol.userB);
        protocol.userA = userAAddr;
        protocol.userB = userBAddr;

        console.log("=== K613 + AAVE FULL LIFECYCLE (env snapshot) ===");
        console.log("Admin (deployer, buyback / seed):", deployer);
        console.log("User A:", userAAddr);
        console.log("User B:", userBAddr);
        console.log("");

        vm.startBroadcast(adminPk);

        _printStepZeroSnapshot(protocol, deployer);

        console.log("========== PHASE 1: SEED, AAVE SUPPLY, K613 STAKE, B BORROW ==========");
        _phase1Bootstrap(protocol, deployer, adminPk, userAPk, userBPk);
        _printSnapshot("AFTER PHASE 1", protocol, deployer);

        console.log("");
        console.log("--- Warp ---");
        vm.warp(block.timestamp + PHASE_WARP);

        console.log("");
        console.log("========== PHASE 2: AAVE INCENTIVES, RD EPOCH , B INSTANT EXIT, TREASURY ==========");
        _phase2LiquidityAndTreasury(protocol, deployer, adminPk, userAPk, userBPk);
        _printSnapshot("AFTER PHASE 2", protocol, deployer);

        console.log("");
        console.log("--- Warp ---");
        vm.warp(block.timestamp + PHASE_WARP);

        console.log("");
        console.log("========== PHASE 3: AAVE + RD CLAIMS, RECOMPOUND, STAKE REWARDS, INITIATE EXIT ==========");
        _phase3StakingClaimsAndExitStart(protocol, deployer, adminPk, userAPk, userBPk);
        _printSnapshot("AFTER PHASE 3", protocol, deployer);

        console.log("");
        console.log("--- Warp ---");
        vm.warp(block.timestamp + PHASE_WARP);

        console.log("");
        console.log("========== PHASE 4: STAKING + RD - full exit (exit queue, then RD, instant exit ) ==========");
        _phase4DrainStakingAndRd(protocol, deployer, adminPk, userAPk, userBPk);
        _printSnapshot("AFTER PHASE 4", protocol, deployer);

        console.log("");
        console.log("--- Warp ---");
        vm.warp(block.timestamp + PHASE_WARP);

        console.log("");
        console.log("========== PHASE 5: AAVE - repay borrow + withdraw all supply ==========");
        _phase5AaveEvacuate(protocol, deployer, adminPk, userAPk, userBPk);

        console.log("");
        console.log("========== FINAL DUST (all users left staking, RD, and Aave) ==========");
        _printDustSnapshot(protocol, deployer);

        vm.stopBroadcast();
    }

    function _maybeSelectForkLatest() internal {
        if (vm.envOr("FULL_LENDING_FORK_LATEST", uint256(0)) == 0) return;
        string memory url = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");
        vm.createSelectFork(url);
        console.log("FULL_LENDING_FORK_LATEST: fork reset to latest block");
    }

    function _deployNearProd(address deployer) internal returns (ProtocolState memory p) {
        K613 k613 = new K613(deployer);
        xK613 xk = new xK613(deployer);
        Staking staking = new Staking(address(k613), address(xk), DEPLOY_LOCK_DURATION, DEPLOY_INSTANT_EXIT_PENALTY_BPS);
        RewardsDistributor rd = new RewardsDistributor(address(xk), address(xk), address(k613), DEPLOY_EPOCH_DURATION);
        Treasury treasury = new Treasury(address(k613), address(xk), address(staking), address(rd));

        xk.setMinter(address(staking));
        xk.setTransferWhitelist(address(rd), true);
        xk.setTransferWhitelist(address(staking), true);
        xk.setTransferWhitelist(address(treasury), true);

        staking.setRewardsDistributor(address(rd));
        staking.addSystemStaker(address(rd));
        staking.addSystemStaker(address(treasury));
        rd.setStaking(address(staking));
        rd.grantRole(rd.REWARDS_NOTIFIER_ROLE(), address(treasury));

        if (block.chainid == ARBITRUM_SEPOLIA) {
            console.log(
                "Treasury.buybackV3ExactInputSingle needs SwapRouter02 exactInputSingle; whitelist manually via setRouterWhitelist."
            );
        }

        console.log("Deployed K613:", address(k613));
        console.log("Deployed xK613:", address(xk));
        console.log("Deployed Staking:", address(staking));
        console.log("Deployed RewardsDistributor:", address(rd));
        console.log("Deployed Treasury:", address(treasury));

        p.k613 = k613;
        p.xk613 = xk;
        p.staking = staking;
        p.rd = rd;
        p.treasury = treasury;
        p.aavePool = IPool(vm.envAddress("AAVE_POOL_ADDRESS"));
        p.supplyToken = vm.envAddress("SUPPLY_TOKEN_ADDRESS");
        p.borrowToken = vm.envAddress("BORROW_TOKEN_ADDRESS");
        p.userA = vm.envAddress("FULL_LENDING_USER_A_ADDRESS");
        p.userB = vm.envAddress("FULL_LENDING_USER_B_ADDRESS");
    }

    function _resolveUserA(address deployer, uint256 adminPk, address configuredUser)
        internal
        view
        returns (address, uint256)
    {
        require(configuredUser != deployer, "FULL_LENDING_USER_A_ADDRESS must differ from deployer");
        uint256 userPk = vm.envUint("FULL_LENDING_USER_A_PRIVATE_KEY");
        require(userPk != adminPk, "FULL_LENDING_USER_A_PRIVATE_KEY must differ from PRIVATE_KEY");
        require(vm.addr(userPk) == configuredUser, "FULL_LENDING_USER_A_PRIVATE_KEY mismatch");
        return (configuredUser, userPk);
    }

    function _resolveUserB(address deployer, uint256 adminPk, address userA, address configuredUser)
        internal
        view
        returns (address, uint256)
    {
        require(configuredUser != deployer, "FULL_LENDING_USER_B_ADDRESS must differ from deployer");
        require(configuredUser != userA, "FULL_LENDING_USER_B_ADDRESS must differ from User A");
        uint256 userPk = vm.envUint("FULL_LENDING_USER_B_PRIVATE_KEY");
        require(userPk != adminPk, "FULL_LENDING_USER_B_PRIVATE_KEY must differ from PRIVATE_KEY");
        require(vm.addr(userPk) == configuredUser, "FULL_LENDING_USER_B_PRIVATE_KEY mismatch");
        return (configuredUser, userPk);
    }

    function _loadProtocolFromEnv() internal view returns (ProtocolState memory) {
        return ProtocolState({
            k613: K613(vm.envAddress("K613_ADDRESS")),
            xk613: xK613(vm.envAddress("XK613_ADDRESS")),
            staking: Staking(vm.envAddress("STAKING_ADDRESS")),
            rd: RewardsDistributor(vm.envAddress("REWARDS_DISTRIBUTOR_ADDRESS")),
            treasury: Treasury(vm.envAddress("TREASURY_ADDRESS")),
            aavePool: IPool(vm.envAddress("AAVE_POOL_ADDRESS")),
            supplyToken: vm.envAddress("SUPPLY_TOKEN_ADDRESS"),
            borrowToken: vm.envAddress("BORROW_TOKEN_ADDRESS"),
            userA: vm.envAddress("FULL_LENDING_USER_A_ADDRESS"),
            userB: vm.envAddress("FULL_LENDING_USER_B_ADDRESS")
        });
    }

    function _rewardsController(IPool pool) internal view returns (IRewardsControllerLite) {
        address ap = pool.ADDRESSES_PROVIDER();
        address rc = IPoolAddressesProviderLite(ap).getAddress(INCENTIVES_CONTROLLER_ID);
        return IRewardsControllerLite(rc);
    }

    function _supplyAToken(IPool pool, address asset) internal view returns (address) {
        return pool.getReserveData(asset).aTokenAddress;
    }

    function _claimAaveSupplyIfAny(ProtocolState memory protocol, address user, uint256 userPk, uint256 adminPk)
        internal
    {
        address aToken;
        try protocol.aavePool.getReserveData(protocol.supplyToken) returns (DataTypes.ReserveDataLegacy memory data) {
            aToken = data.aTokenAddress;
        } catch {
            console.log("Aave supply incentives: getReserveData failed, skip");
            return;
        }
        if (aToken == address(0)) {
            console.log("Aave supply incentives: no aToken, skip");
            return;
        }

        address ap;
        try protocol.aavePool.ADDRESSES_PROVIDER() returns (address provider) {
            ap = provider;
        } catch {
            console.log("Aave supply incentives: ADDRESSES_PROVIDER failed, skip");
            return;
        }
        if (ap == address(0)) return;

        address rcAddr;
        try IPoolAddressesProviderLite(ap).getAddress(INCENTIVES_CONTROLLER_ID) returns (address controller) {
            rcAddr = controller;
        } catch {
            console.log("Aave supply incentives: getAddress incentives failed, skip");
            return;
        }
        if (rcAddr == address(0)) {
            console.log("Aave supply incentives: controller address zero, skip");
            return;
        }

        IRewardsControllerLite rc = IRewardsControllerLite(rcAddr);
        address[] memory assets = new address[](1);
        assets[0] = aToken;

        address[] memory rewardTokens = _aaveSupplyRewardCandidates(rc, aToken);
        if (rewardTokens.length == 0) {
            console.log(
                "Aave supply incentives: no reward tokens for aToken (emissions off or set AAVE_SUPPLY_REWARD_TOKEN)"
            );
            return;
        }

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address reward = rewardTokens[i];
            if (reward == address(0)) continue;
            uint256 pending;
            try rc.getUserRewards(assets, user, reward) returns (uint256 p) {
                pending = p;
            } catch {
                continue;
            }
            if (pending == 0) continue;

            vm.stopBroadcast();
            vm.startBroadcast(userPk);
            (bool claimOk, bytes memory claimRet) =
                address(rc).call(abi.encodeCall(IRewardsControllerLite.claimRewards, (assets, pending, user, reward)));
            if (!claimOk) {
                console.log("Aave supply incentives: claimRewards reverted");
                console.log("  user:", user);
                console.log("  reward token:", reward);
                console.log("  pending raw:", pending);
                console.logBytes(claimRet);
            } else {
                uint256 claimed = abi.decode(claimRet, (uint256));
                console.log("[transfer] Aave incentives -> user (claimRewards)");
                console.log("  user:", user);
                console.log("  reward token:", reward);
                console.log("  reward symbol:", _tokenSymbol(reward));
                console.log("  claimed:", claimed / (10 ** _tokenDecimals(reward)));
                console.log("  claimed raw:", claimed);
            }
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }
    }

    function _aaveSupplyRewardCandidates(IRewardsControllerLite rc, address aToken)
        internal
        view
        returns (address[] memory)
    {
        address explicitReward = vm.envOr("AAVE_SUPPLY_REWARD_TOKEN", address(0));
        if (explicitReward != address(0)) {
            address[] memory one = new address[](1);
            one[0] = explicitReward;
            return one;
        }
        try rc.getRewardsByAsset(aToken) returns (address[] memory fromChain) {
            return fromChain;
        } catch {
            return new address[](0);
        }
    }

    function _warpUntilEpochReady(RewardsDistributor rd) internal {
        uint256 nextAt = rd.nextEpochAt();
        if (block.timestamp < nextAt) {
            vm.warp(nextAt);
        }
    }

    function _availableSystemBacking(ProtocolState memory protocol) internal view returns (uint256 total) {
        total += _stakingExitableXk613(protocol.staking, address(protocol.rd));
        total += _stakingExitableXk613(protocol.staking, address(protocol.treasury));
    }

    function _stakingExitableXk613(Staking staking, address user) internal view returns (uint256) {
        (uint256 staked, Staking.ExitRequest[] memory queue) = staking.deposits(user);
        uint256 inQueue;
        for (uint256 i = 0; i < queue.length; ++i) {
            inQueue += queue[i].amount;
        }
        if (staked <= inQueue) return 0;
        return staked - inQueue;
    }

    function _tokenDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _tokenSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "?";
        }
    }

    function _logMoveAuto(string memory tag, address token, address from, address to, uint256 amountRaw) internal view {
        uint8 d = _tokenDecimals(token);
        console.log("[transfer]", tag);
        console.log("  symbol:", _tokenSymbol(token));
        console.log("  token:", token);
        console.log("  from :", from);
        console.log("  to   :", to);
        console.log("  amount :", amountRaw / (10 ** d));
        console.log("  amount raw   :", amountRaw);
    }

    function _logBalanceDelta(string memory tag, address token, address account, uint256 balBefore, uint256 balAfter)
        internal
        view
    {
        uint256 delta = balAfter > balBefore ? balAfter - balBefore : balBefore - balAfter;
        if (delta == 0) {
            console.log("[balance]", tag, "(no change)", account);
            return;
        }
        uint8 d = _tokenDecimals(token);
        bool received = balAfter > balBefore;
        console.log("[balance]", tag);
        console.log("  token:", token);
        console.log("  symbol:", _tokenSymbol(token));
        console.log("  account:", account);
        console.log("  before :", balBefore / (10 ** d));
        console.log("  after  :", balAfter / (10 ** d));
        console.log("  direction in/out:", received ? "in" : "out");
        console.log("  delta :", delta / (10 ** d));
    }

    function _phase1Bootstrap(
        ProtocolState memory protocol,
        address admin,
        uint256 adminPk,
        uint256 userAPk,
        uint256 userBPk
    ) internal {
        address userA = protocol.userA;
        address userB = protocol.userB;

        uint256 userASupply = vm.envOr("FULL_LENDING_AAVE_USER_A_SUPPLY", uint256(100_000 ether));
        uint256 userBCollateral = vm.envOr("FULL_LENDING_AAVE_USER_B_COLLATERAL", uint256(100_000 ether));
        uint256 userBBorrow = vm.envOr("FULL_LENDING_AAVE_USER_B_BORROW", uint256(50_000 ether));
        uint256 userBStake = vm.envOr("FULL_LENDING_USER_B_K613_STAKE", uint256(400 ether));
        uint8 supplyDecimals = IERC20Metadata(protocol.supplyToken).decimals();
        uint8 borrowDecimals = IERC20Metadata(protocol.borrowToken).decimals();

        console.log("--- Admin: seed supply asset to users ---");
        _logMoveAuto("Admin -> User A (supply asset seed)", protocol.supplyToken, admin, userA, userASupply);
        IERC20(protocol.supplyToken).transfer(userA, userASupply);

        console.log("--- User A: Aave supply ---");
        vm.stopBroadcast();
        vm.startBroadcast(userAPk);
        _logMoveAuto(
            "User A -> Aave pool (supply)", protocol.supplyToken, userA, address(protocol.aavePool), userASupply
        );
        IERC20(protocol.supplyToken).approve(address(protocol.aavePool), userASupply);
        protocol.aavePool.supply(protocol.supplyToken, userASupply, userA, 0);
        console.log("User A supplied :", userASupply / (10 ** supplyDecimals));

        console.log("--- User A: K613 stake + RD deposit ---");
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        _logMoveAuto("Admin -> User A (K613 for stake/RD)", address(protocol.k613), admin, userA, USER_A_STAKE);
        protocol.k613.transfer(userA, USER_A_STAKE);
        vm.stopBroadcast();
        vm.startBroadcast(userAPk);
        _logMoveAuto(
            "User A -> Staking (stake pull K613)",
            address(protocol.k613),
            userA,
            address(protocol.staking),
            USER_A_STAKE
        );
        protocol.k613.approve(address(protocol.staking), USER_A_STAKE);
        protocol.staking.stake(USER_A_STAKE);
        console.log("User A staked K613:", USER_A_STAKE / 1 ether);
        _logMoveAuto(
            "User A -> RewardsDistributor (RD deposit xK613)",
            address(protocol.xk613),
            userA,
            address(protocol.rd),
            USER_A_STAKE
        );
        IERC20(address(protocol.xk613)).approve(address(protocol.rd), USER_A_STAKE);
        protocol.rd.deposit(USER_A_STAKE);
        console.log("User A RD deposit:", USER_A_STAKE / 1 ether);

        console.log("--- User B: Aave collateral + borrow ---");
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        _logMoveAuto(
            "Admin -> User B (supply asset collateral seed)", protocol.supplyToken, admin, userB, userBCollateral
        );
        IERC20(protocol.supplyToken).transfer(userB, userBCollateral);
        vm.stopBroadcast();
        vm.startBroadcast(userBPk);
        _logMoveAuto(
            "User B -> Aave pool (supply collateral)",
            protocol.supplyToken,
            userB,
            address(protocol.aavePool),
            userBCollateral
        );
        IERC20(protocol.supplyToken).approve(address(protocol.aavePool), userBCollateral);
        protocol.aavePool.supply(protocol.supplyToken, userBCollateral, userB, 0);
        console.log("User B supplied collateral :", userBCollateral / (10 ** supplyDecimals));
        uint256 bBorrowBalBefore = IERC20(protocol.borrowToken).balanceOf(userB);
        protocol.aavePool.borrow(protocol.borrowToken, userBBorrow, 2, 0, userB);
        uint256 bBorrowBalAfter = IERC20(protocol.borrowToken).balanceOf(userB);
        _logBalanceDelta(
            "User B borrow draw (borrow asset)", protocol.borrowToken, userB, bBorrowBalBefore, bBorrowBalAfter
        );
        console.log("User B borrowed :", userBBorrow / (10 ** borrowDecimals));

        console.log("--- User B: K613 stake (for later instant exit demo) ---");
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        _logMoveAuto("Admin -> User B (K613 for stake)", address(protocol.k613), admin, userB, userBStake);
        protocol.k613.transfer(userB, userBStake);
        vm.stopBroadcast();
        vm.startBroadcast(userBPk);
        _logMoveAuto(
            "User B -> Staking (stake pull K613)", address(protocol.k613), userB, address(protocol.staking), userBStake
        );
        protocol.k613.approve(address(protocol.staking), userBStake);
        protocol.staking.stake(userBStake);
        console.log("User B staked K613:", userBStake / 1 ether);
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
    }

    function _phase2LiquidityAndTreasury(
        ProtocolState memory protocol,
        address admin,
        uint256 adminPk,
        uint256 userAPk,
        uint256 userBPk
    ) internal {
        address userA = protocol.userA;
        address userB = protocol.userB;

        console.log("--- User A: Aave supply incentives ---");
        _claimAaveSupplyIfAny(protocol, userA, userAPk, adminPk);

        console.log("--- User B: Aave supply incentives ---");
        _claimAaveSupplyIfAny(protocol, userB, userBPk, adminPk);

        console.log("--- RewardsDistributor: advanceEpoch (no user RD claim yet) ---");
        _warpUntilEpochReady(protocol.rd);
        protocol.rd.advanceEpoch();

        console.log("--- User B: instant exit (penalty to RD) ---");
        uint256 userBxK613 = IERC20(address(protocol.xk613)).balanceOf(userB);
        uint256 exitableStake = _stakingExitableXk613(protocol.staking, userB);
        if (userBxK613 > 0 && exitableStake > 0) {
            uint256 halfWallet = userBxK613 / 2;
            uint256 exitAmount = halfWallet < exitableStake ? halfWallet : exitableStake;
            if (exitAmount > 0) {
                vm.stopBroadcast();
                vm.startBroadcast(userBPk);
                _logMoveAuto(
                    "User B -> Staking (xK613 initiateExit escrow)",
                    address(protocol.xk613),
                    userB,
                    address(protocol.staking),
                    exitAmount
                );
                IERC20(address(protocol.xk613)).approve(address(protocol.staking), exitAmount);
                protocol.staking.initiateExit(exitAmount);
                uint256 lockLen = protocol.staking.lockDuration();
                if (lockLen > 1) {
                    vm.warp(block.timestamp + lockLen - 1);
                }
                uint256 kBefore = protocol.k613.balanceOf(userB);
                protocol.staking.instantExit(0);
                uint256 kAfter = protocol.k613.balanceOf(userB);
                _logBalanceDelta(
                    "User B after instantExit (K613 payout net of penalty)",
                    address(protocol.k613),
                    userB,
                    kBefore,
                    kAfter
                );
                console.log("User B instant exit xK613 face:", exitAmount / 1 ether);
                vm.stopBroadcast();
                vm.startBroadcast(adminPk);
            }
        }

        console.log("--- Admin: protocol fees (Aave collector / reserve factor off-chain); buyback implied ---");

        console.log("--- Admin: stake K613 (buyback stand-in) ---");
        if (protocol.k613.balanceOf(admin) > ADMIN_BUYBACK_STAKE) {
            _logMoveAuto(
                "Admin -> Staking (buyback stand-in stake)",
                address(protocol.k613),
                admin,
                address(protocol.staking),
                ADMIN_BUYBACK_STAKE
            );
            protocol.k613.approve(address(protocol.staking), ADMIN_BUYBACK_STAKE);
            protocol.staking.stake(ADMIN_BUYBACK_STAKE);
            console.log("Admin staked K613:", ADMIN_BUYBACK_STAKE / 1 ether);
        }

        console.log("--- Treasury: depositRewards ---");
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        _logMoveAuto(
            "Admin -> Treasury (K613 via transferFrom in depositRewards)",
            address(protocol.k613),
            admin,
            address(protocol.treasury),
            TREASURY_REWARD
        );
        protocol.k613.approve(address(protocol.treasury), TREASURY_REWARD);
        protocol.treasury.depositRewards(TREASURY_REWARD);
        _logMoveAuto(
            "Treasury -> RewardsDistributor (xK613 after internal stake)",
            address(protocol.xk613),
            address(protocol.treasury),
            address(protocol.rd),
            TREASURY_REWARD
        );
        console.log("Treasury reward K613:", TREASURY_REWARD / 1 ether);
        _maybeTreasuryBuyback(protocol, adminPk);
    }

    function _maybeTreasuryBuyback(ProtocolState memory protocol, uint256 adminPk) internal {
        if (vm.envOr("FULL_LENDING_BUYBACK", uint256(0)) == 0) return;
        address treasuryAddr = address(protocol.treasury);
        address token = vm.envAddress("TOKEN_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
        uint256 amount = vm.envOr("AMOUNT_TO_BUYBACK", uint256(0));
        if (amount == 0) {
            amount = IERC20(token).balanceOf(treasuryAddr);
        }
        if (amount == 0) {
            console.log("FULL_LENDING_BUYBACK: skip zero TOKEN balance on Treasury");
            return;
        }
        uint256 minK613Out = vm.envUint("MIN_K613_OUT");
        console.log("--- Optional: Treasury buyback V3 (same env as TreasuryBuybackV3) ---");
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        uint256 k613Out = protocol.treasury.buybackV3ExactInputSingle(token, router, amount, minK613Out, poolFee, true);
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        console.log("FULL_LENDING_BUYBACK K613 out:", k613Out);
    }

    function _phase3StakingClaimsAndExitStart(
        ProtocolState memory protocol,
        address admin,
        uint256 adminPk,
        uint256 userAPk,
        uint256 userBPk
    ) internal {
        address userA = protocol.userA;
        address userB = protocol.userB;

        console.log("--- User A: Aave supply incentives ---");
        _claimAaveSupplyIfAny(protocol, userA, userAPk, adminPk);

        console.log("--- User B: Aave supply incentives ---");
        _claimAaveSupplyIfAny(protocol, userB, userBPk, adminPk);

        console.log("--- RewardsDistributor: advanceEpoch + RD claims ---");
        _warpUntilEpochReady(protocol.rd);
        protocol.rd.advanceEpoch();

        uint256 aPending = protocol.rd.pendingRewardsOf(userA);
        if (aPending > 0) {
            vm.stopBroadcast();
            vm.startBroadcast(userAPk);
            uint256 x0 = IERC20(address(protocol.xk613)).balanceOf(userA);
            protocol.rd.claim();
            uint256 x1 = IERC20(address(protocol.xk613)).balanceOf(userA);
            _logBalanceDelta("User A RD claim (xK613 reward)", address(protocol.xk613), userA, x0, x1);
            console.log("User A RD claimed:", aPending / 1 ether);
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }

        uint256 bPending = protocol.rd.pendingRewardsOf(userB);
        if (bPending > 0) {
            vm.stopBroadcast();
            vm.startBroadcast(userBPk);
            uint256 x0b = IERC20(address(protocol.xk613)).balanceOf(userB);
            protocol.rd.claim();
            uint256 x1b = IERC20(address(protocol.xk613)).balanceOf(userB);
            _logBalanceDelta("User B RD claim (xK613 reward)", address(protocol.xk613), userB, x0b, x1b);
            console.log("User B RD claimed:", bPending / 1 ether);
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }

        console.log("--- User A: recompound RD ---");
        uint256 userARDBalance = protocol.rd.balanceOf(userA);
        if (userARDBalance > 0) {
            vm.stopBroadcast();
            vm.startBroadcast(userAPk);
            _logMoveAuto(
                "RewardsDistributor -> User A (RD withdraw xK613)",
                address(protocol.xk613),
                address(protocol.rd),
                userA,
                userARDBalance
            );
            protocol.rd.withdraw(userARDBalance);
            (uint256 stakedForRecompound,) = protocol.staking.deposits(userA);
            uint256 xWallet = IERC20(address(protocol.xk613)).balanceOf(userA);
            uint256 toDeposit = stakedForRecompound <= xWallet ? stakedForRecompound : xWallet;
            if (toDeposit > 0) {
                _logMoveAuto(
                    "User A -> RewardsDistributor (RD re-deposit xK613)",
                    address(protocol.xk613),
                    userA,
                    address(protocol.rd),
                    toDeposit
                );
                IERC20(address(protocol.xk613)).approve(address(protocol.rd), toDeposit);
                protocol.rd.deposit(toDeposit);
                console.log("User A RD recompound deposited:", toDeposit / 1 ether);
            }
            if (toDeposit < stakedForRecompound) {
                console.log("User A RD recompound capped; staked:", stakedForRecompound / 1 ether);
            }
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }

        if (protocol.k613.balanceOf(admin) > ADMIN_BUYBACK_STAKE) {
            _logMoveAuto(
                "Admin -> Staking (buyback stand-in repeat)",
                address(protocol.k613),
                admin,
                address(protocol.staking),
                ADMIN_BUYBACK_STAKE
            );
            protocol.k613.approve(address(protocol.staking), ADMIN_BUYBACK_STAKE);
            protocol.staking.stake(ADMIN_BUYBACK_STAKE);
            console.log("Admin staked K613 (repeat):", ADMIN_BUYBACK_STAKE / 1 ether);
        }

        console.log("--- User A: RD claim after new accrual (if any) ---");
        uint256 aPending2 = protocol.rd.pendingRewardsOf(userA);
        if (aPending2 > 0) {
            vm.stopBroadcast();
            vm.startBroadcast(userAPk);
            uint256 x0c = IERC20(address(protocol.xk613)).balanceOf(userA);
            protocol.rd.claim();
            uint256 x1c = IERC20(address(protocol.xk613)).balanceOf(userA);
            _logBalanceDelta("User A RD claim (2) xK613", address(protocol.xk613), userA, x0c, x1c);
            console.log("User A RD claimed (2):", aPending2 / 1 ether);
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }

        console.log("--- User A: staking exit deferred to PHASE 4 (instant exit path) ---");
    }

    function _phase4DrainStakingAndRd(
        ProtocolState memory protocol,
        address admin,
        uint256 adminPk,
        uint256 userAPk,
        uint256 userBPk
    ) internal {
        console.log("--- Evacuate User A ---");
        _evacuateUserStakingAndRd(protocol, protocol.userA, userAPk, adminPk);
        console.log("--- Evacuate User B ---");
        _evacuateUserStakingAndRd(protocol, protocol.userB, userBPk, adminPk);
        console.log("--- Evacuate Admin (staking only) ---");
        _evacuateUserStakingAndRd(protocol, admin, adminPk, adminPk);
    }

    function _evacuateUserStakingAndRd(ProtocolState memory protocol, address user, uint256 userPk, uint256 adminPk)
        internal
    {
        IERC20 x = IERC20(address(protocol.xk613));
        for (uint256 iter = 0; iter < 24; ++iter) {
            _drainExitQueuePreferInstant(protocol.staking, user, userPk, adminPk);

            uint256 rdPending = protocol.rd.pendingRewardsOf(user);
            if (rdPending > 0) {
                vm.stopBroadcast();
                vm.startBroadcast(userPk);
                try protocol.rd.claim() {
                    console.log("RD claim user:", user);
                } catch {
                    console.log("RD claim skipped (user):", user);
                }
                vm.stopBroadcast();
                vm.startBroadcast(adminPk);
            }

            uint256 rdBal = protocol.rd.balanceOf(user);
            if (rdBal > 0) {
                vm.stopBroadcast();
                vm.startBroadcast(userPk);
                _logMoveAuto(
                    "RewardsDistributor -> user (RD withdraw xK613)",
                    address(protocol.xk613),
                    address(protocol.rd),
                    user,
                    rdBal
                );
                protocol.rd.withdraw(rdBal);
                console.log("RD withdraw user:", user);
                vm.stopBroadcast();
                vm.startBroadcast(adminPk);
            }

            (uint256 staked,) = protocol.staking.deposits(user);
            if (staked == 0) {
                break;
            }

            uint256 xBal = x.balanceOf(user);
            if (xBal == 0) {
                console.log("Staking drain stalled: staked>0 but wallet xK613=0 user:", user);
                break;
            }

            uint256 chunk = staked <= xBal ? staked : xBal;
            vm.stopBroadcast();
            vm.startBroadcast(userPk);
            _logMoveAuto(
                "user -> Staking (xK613 initiateExit for instant chunk)",
                address(protocol.xk613),
                user,
                address(protocol.staking),
                chunk
            );
            uint256 kPre = protocol.k613.balanceOf(user);
            x.approve(address(protocol.staking), chunk);
            protocol.staking.initiateExit(chunk);
            protocol.staking.instantExit(0);
            uint256 kPost = protocol.k613.balanceOf(user);
            _logBalanceDelta("user after instantExit chunk (K613)", address(protocol.k613), user, kPre, kPost);
            console.log("Staking instant exit chunk user:", user);
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }

        // H-01 FIX: redeem excess reward xK613 via redeemRewards
        // First, advance epoch so pending penalty K613 gets staked → increases system backing
        _warpUntilEpochReady(protocol.rd);
        try protocol.rd.advanceEpoch() {
            console.log("advanceEpoch before redeemRewards: OK (pending K613 staked)");
        } catch {
            console.log("advanceEpoch before redeemRewards: skipped");
        }

        (uint256 stakedFinal,) = protocol.staking.deposits(user);
        uint256 xWalletFinal = x.balanceOf(user);
        uint256 excess = xWalletFinal > stakedFinal ? xWalletFinal - stakedFinal : 0;
        if (excess > 0) {
            // Cap redeem to available system-staker backing (RD + Treasury)
            uint256 availableBacking = _availableSystemBacking(protocol);
            uint256 redeemAmount = excess > availableBacking ? availableBacking : excess;

            vm.stopBroadcast();
            vm.startBroadcast(userPk);
            console.log("--- redeemRewards: user has excess reward xK613 ---");
            console.log("  user:", user);
            console.log("  staked position:", stakedFinal / 1 ether);
            console.log("  xK613 wallet:", xWalletFinal / 1 ether);
            console.log("  excess (reward xK613):", excess / 1 ether);
            console.log("  available system backing:", availableBacking / 1 ether);
            console.log("  redeem amount (capped):", redeemAmount / 1 ether);
            if (redeemAmount > 0) {
                uint256 kPreRedeem = protocol.k613.balanceOf(user);
                x.approve(address(protocol.staking), redeemAmount);
                try protocol.staking.redeemRewards(redeemAmount) {
                    uint256 kPostRedeem = protocol.k613.balanceOf(user);
                    _logBalanceDelta(
                        "user after redeemRewards (K613)", address(protocol.k613), user, kPreRedeem, kPostRedeem
                    );
                    console.log("  redeemed K613:", (kPostRedeem - kPreRedeem) / 1 ether);
                } catch {
                    console.log("  redeemRewards reverted -- skipped");
                }
            } else {
                console.log("  no system backing available -- skip redeem");
            }
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }
    }

    function _drainExitQueuePreferInstant(Staking staking, address user, uint256 userPk, uint256 adminPk) internal {
        uint256 guard = 0;
        while (staking.exitQueueLength(user) > 0 && guard < 16) {
            ++guard;
            (, uint256 t0) = staking.exitRequestAt(user, 0);
            vm.stopBroadcast();
            vm.startBroadcast(userPk);
            address k613Token = address(staking.k613());
            uint256 kPreQ = IERC20(k613Token).balanceOf(user);
            if (block.timestamp < t0 + staking.lockDuration()) {
                staking.instantExit(0);
                uint256 kPostQ = IERC20(k613Token).balanceOf(user);
                _logBalanceDelta("exit queue instantExit (K613 to user)", k613Token, user, kPreQ, kPostQ);
                console.log("Exit queue instantExit user:", user);
            } else {
                staking.exit(0);
                uint256 kPostQ2 = IERC20(k613Token).balanceOf(user);
                _logBalanceDelta("exit queue timed exit (K613 to user)", k613Token, user, kPreQ, kPostQ2);
                console.log("Exit queue normal exit user:", user);
            }
            vm.stopBroadcast();
            vm.startBroadcast(adminPk);
        }
    }

    function _topUpUserBForAaveRepay(ProtocolState memory protocol, address admin, address userB) internal {
        IERC20 asset = IERC20(protocol.borrowToken);
        uint256 debt;
        try protocol.aavePool.getReserveData(protocol.borrowToken) returns (DataTypes.ReserveDataLegacy memory d) {
            if (d.variableDebtTokenAddress != address(0)) {
                debt = IERC20(d.variableDebtTokenAddress).balanceOf(userB);
            }
        } catch {
            return;
        }
        uint8 bd = _tokenDecimals(protocol.borrowToken);
        console.log("[Aave repay prep] User B variable debt ():", debt / (10 ** bd));
        console.log("[Aave repay prep] User B variable debt (raw):", debt);
        if (debt == 0) return;
        uint256 bal = asset.balanceOf(userB);
        console.log("[Aave repay prep] User B borrow wallet ():", bal / (10 ** bd));
        if (bal >= debt) return;
        uint256 shortfall = debt - bal;
        uint256 adminBal = asset.balanceOf(admin);
        console.log("[Aave repay prep] shortfall ():", shortfall / (10 ** bd));
        console.log("[Aave repay prep] Admin borrow wallet ():", adminBal / (10 ** bd));
        if (adminBal == 0) return;
        uint256 send = shortfall <= adminBal ? shortfall : adminBal;
        _logMoveAuto("Admin -> User B (top up borrow asset for repay)", protocol.borrowToken, admin, userB, send);
        asset.transfer(userB, send);
    }

    function _phase5AaveEvacuate(
        ProtocolState memory protocol,
        address admin,
        uint256 adminPk,
        uint256 userAPk,
        uint256 userBPk
    ) internal {
        address userA = protocol.userA;
        address userB = protocol.userB;

        console.log("--- Aave incentives before leaving ---");
        _claimAaveSupplyIfAny(protocol, userA, userAPk, adminPk);
        _claimAaveSupplyIfAny(protocol, userB, userBPk, adminPk);

        console.log("--- Admin: top up User B borrow asset for repay (interest after warps) ---");
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);
        _topUpUserBForAaveRepay(protocol, admin, userB);
        vm.stopBroadcast();

        console.log("--- User B: repay variable debt (max) + withdraw supply (max) ---");
        vm.startBroadcast(userBPk);
        uint256 bRep0 = IERC20(protocol.borrowToken).balanceOf(userB);
        IERC20(protocol.borrowToken).approve(address(protocol.aavePool), type(uint256).max);
        protocol.aavePool.repay(protocol.borrowToken, type(uint256).max, 2, userB);
        uint256 bRep1 = IERC20(protocol.borrowToken).balanceOf(userB);
        _logBalanceDelta("User B after repay (borrow asset)", protocol.borrowToken, userB, bRep0, bRep1);
        uint256 sWb0 = IERC20(protocol.supplyToken).balanceOf(userB);
        protocol.aavePool.withdraw(protocol.supplyToken, type(uint256).max, userB);
        uint256 sWb1 = IERC20(protocol.supplyToken).balanceOf(userB);
        _logBalanceDelta("User B after withdraw supply (supply asset)", protocol.supplyToken, userB, sWb0, sWb1);
        vm.stopBroadcast();

        console.log("--- User A: withdraw supply (max) ---");
        vm.startBroadcast(userAPk);
        uint256 sWa0 = IERC20(protocol.supplyToken).balanceOf(userA);
        protocol.aavePool.withdraw(protocol.supplyToken, type(uint256).max, userA);
        uint256 sWa1 = IERC20(protocol.supplyToken).balanceOf(userA);
        _logBalanceDelta("User A after withdraw supply (supply asset)", protocol.supplyToken, userA, sWa0, sWa1);
        vm.stopBroadcast();
        vm.startBroadcast(adminPk);

        console.log("--- Aave incentives after exit (leftover accrual) ---");
        _claimAaveSupplyIfAny(protocol, userA, userAPk, adminPk);
        _claimAaveSupplyIfAny(protocol, userB, userBPk, adminPk);
    }

    function _printStepZeroSnapshot(ProtocolState memory protocol, address admin) internal view {
        address userA = protocol.userA;
        address userB = protocol.userB;
        uint8 sDec = _tokenDecimals(protocol.supplyToken);
        uint8 bDec = _tokenDecimals(protocol.borrowToken);

        console.log("");
        console.log("========== STEP 0: INITIAL STATE (before PHASE 1) ==========");
        console.log("K613:", address(protocol.k613));
        console.log("xK613:", address(protocol.xk613));
        console.log("Staking:", address(protocol.staking));
        console.log("RewardsDistributor:", address(protocol.rd));
        console.log("Treasury:", address(protocol.treasury));
        console.log("Aave pool:", address(protocol.aavePool));
        console.log("Supply asset:", protocol.supplyToken, _tokenSymbol(protocol.supplyToken));
        console.log("Borrow asset:", protocol.borrowToken, _tokenSymbol(protocol.borrowToken));

        console.log("");
        console.log("--- Actors (K613/xK613 in ether-scale units; Aave assets in token decimals) ---");
        _printActorStepZero("Admin", protocol, admin, sDec, bDec);
        _printActorStepZero("User A", protocol, userA, sDec, bDec);
        _printActorStepZero("User B", protocol, userB, sDec, bDec);

        console.log("");
        console.log("--- Core contracts ---");
        IERC20 supT = IERC20(protocol.supplyToken);
        IERC20 borT = IERC20(protocol.borrowToken);
        address tr = address(protocol.treasury);
        address st = address(protocol.staking);
        address rdAddr = address(protocol.rd);
        console.log("Treasury K613:", protocol.k613.balanceOf(tr) / 1 ether);
        console.log("Treasury xK613:", IERC20(address(protocol.xk613)).balanceOf(tr) / 1 ether);
        console.log("Treasury supply asset:", supT.balanceOf(tr) / (10 ** sDec));
        console.log("Treasury borrow asset:", borT.balanceOf(tr) / (10 ** bDec));
        console.log("Staking K613:", protocol.k613.balanceOf(st) / 1 ether);
        console.log("Staking xK613:", IERC20(address(protocol.xk613)).balanceOf(st) / 1 ether);
        console.log("Staking totalBacking:", protocol.staking.totalBacking() / 1 ether);
        console.log("RD xK613 (token bal):", IERC20(address(protocol.xk613)).balanceOf(rdAddr) / 1 ether);
        console.log("RD K613:", protocol.k613.balanceOf(rdAddr) / 1 ether);
        console.log("RD totalDeposits:", protocol.rd.totalDeposits() / 1 ether);
        console.log("RD pendingRewards:", protocol.rd.pendingRewards() / 1 ether);
        console.log("RD pendingPenalties:", protocol.rd.pendingPenalties() / 1 ether);

        console.log("");
        console.log("--- Total supply ---");
        console.log("K613 totalSupply:", IERC20(address(protocol.k613)).totalSupply() / 1 ether);
        console.log("xK613 totalSupply:", IERC20(address(protocol.xk613)).totalSupply() / 1 ether);
    }

    function _printActorStepZero(
        string memory tag,
        ProtocolState memory protocol,
        address who,
        uint8 supplyDec,
        uint8 borrowDec
    ) internal view {
        (uint256 staked,) = protocol.staking.deposits(who);
        IERC20 supE = IERC20(protocol.supplyToken);
        IERC20 borE = IERC20(protocol.borrowToken);
        console.log(string.concat(tag, " addr:"), who);
        console.log(string.concat(tag, " native:"), who.balance);
        console.log(string.concat(tag, " K613:"), protocol.k613.balanceOf(who) / 1 ether);
        console.log(string.concat(tag, " xK613:"), IERC20(address(protocol.xk613)).balanceOf(who) / 1 ether);
        console.log(string.concat(tag, " supplyAsset:"), supE.balanceOf(who) / (10 ** supplyDec));
        console.log(string.concat(tag, " borrowAsset:"), borE.balanceOf(who) / (10 ** borrowDec));
        console.log(string.concat(tag, " staked:"), staked / 1 ether);
        console.log(string.concat(tag, " RD share:"), protocol.rd.balanceOf(who) / 1 ether);
        console.log(string.concat(tag, " RD pending:"), protocol.rd.pendingRewardsOf(who) / 1 ether);
        console.log(string.concat(tag, " exitQLen:"), protocol.staking.exitQueueLength(who));
        _printAaveStepZero(protocol, who, tag);
    }

    function _printAaveStepZero(ProtocolState memory protocol, address user, string memory tag) internal view {
        uint8 sd = _tokenDecimals(protocol.supplyToken);
        uint8 bd = _tokenDecimals(protocol.borrowToken);
        try protocol.aavePool.getReserveData(protocol.supplyToken) returns (DataTypes.ReserveDataLegacy memory s) {
            address at = s.aTokenAddress;
            uint256 aBal = at == address(0) ? 0 : IERC20(at).balanceOf(user);
            console.log(string.concat(tag, " Aave aToken:"), aBal / (10 ** sd));
        } catch {
            console.log(string.concat(tag, " Aave aToken: n/a"));
        }
        try protocol.aavePool.getReserveData(protocol.borrowToken) returns (DataTypes.ReserveDataLegacy memory b) {
            address vd = b.variableDebtTokenAddress;
            uint256 dBal = vd == address(0) ? 0 : IERC20(vd).balanceOf(user);
            console.log(string.concat(tag, " Aave varDebt:"), dBal / (10 ** bd));
        } catch {
            console.log(string.concat(tag, " Aave varDebt: n/a"));
        }
    }

    function _printDustSnapshot(ProtocolState memory protocol, address admin) internal view {
        address userA = protocol.userA;
        address userB = protocol.userB;

        console.log("");
        console.log("=== DUST SNAPSHOT: users ===");
        _printUserDustLine("UserA", protocol, userA);
        _printUserDustLine("UserB", protocol, userB);
        _printUserDustLine("Admin", protocol, admin);

        console.log("");
        console.log("=== DUST SNAPSHOT: core contracts ===");
        console.log("Treasury K613:", protocol.k613.balanceOf(address(protocol.treasury)) / 1 ether);
        console.log("Treasury xK613:", IERC20(address(protocol.xk613)).balanceOf(address(protocol.treasury)) / 1 ether);
        console.log("Staking K613:", protocol.k613.balanceOf(address(protocol.staking)) / 1 ether);
        console.log("Staking xK613:", IERC20(address(protocol.xk613)).balanceOf(address(protocol.staking)) / 1 ether);
        console.log("Staking totalBacking:", protocol.staking.totalBacking() / 1 ether);
        console.log("RD xK613:", IERC20(address(protocol.xk613)).balanceOf(address(protocol.rd)) / 1 ether);
        console.log("RD K613:", protocol.k613.balanceOf(address(protocol.rd)) / 1 ether);
        console.log("RD totalDeposits:", protocol.rd.totalDeposits() / 1 ether);
        console.log("RD pendingRewards (global):", protocol.rd.pendingRewards() / 1 ether);
        console.log("RD pendingPenalties:", protocol.rd.pendingPenalties() / 1 ether);

        console.log("");
        console.log("=== DUST SNAPSHOT: Aave positions (aToken / variable debt) ===");
        _printAaveDust(protocol, userA, "UserA");
        _printAaveDust(protocol, userB, "UserB");

        console.log("");
        console.log("=== DUST SNAPSHOT: token supply ===");
        console.log("K613 totalSupply:", IERC20(address(protocol.k613)).totalSupply() / 1 ether);
        console.log("xK613 totalSupply:", IERC20(address(protocol.xk613)).totalSupply() / 1 ether);
    }

    function _printUserDustLine(string memory tag, ProtocolState memory protocol, address user) internal view {
        (uint256 staked,) = protocol.staking.deposits(user);
        console.log(string.concat(tag, " K613:"), protocol.k613.balanceOf(user) / 1 ether);
        console.log(string.concat(tag, " xK613:"), IERC20(address(protocol.xk613)).balanceOf(user) / 1 ether);
        console.log(string.concat(tag, " staked:"), staked / 1 ether);
        console.log(string.concat(tag, " RD share:"), protocol.rd.balanceOf(user) / 1 ether);
        console.log(string.concat(tag, " RD pending:"), protocol.rd.pendingRewardsOf(user) / 1 ether);
        console.log(string.concat(tag, " exitQueueLen:"), protocol.staking.exitQueueLength(user));
    }

    function _printAaveDust(ProtocolState memory protocol, address user, string memory tag) internal view {
        address aToken;
        address vDebt;
        try protocol.aavePool.getReserveData(protocol.supplyToken) returns (DataTypes.ReserveDataLegacy memory s) {
            aToken = s.aTokenAddress;
        } catch {
            console.log(string.concat(tag, " Aave: getReserveData supply failed"));
            return;
        }
        try protocol.aavePool.getReserveData(protocol.borrowToken) returns (DataTypes.ReserveDataLegacy memory b) {
            vDebt = b.variableDebtTokenAddress;
        } catch {
            console.log(string.concat(tag, " Aave: getReserveData borrow failed"));
            return;
        }
        uint256 aBal = aToken == address(0) ? 0 : IERC20(aToken).balanceOf(user);
        uint256 dBal = vDebt == address(0) ? 0 : IERC20(vDebt).balanceOf(user);
        console.log(string.concat(tag, " aToken bal:"), aBal);
        console.log(string.concat(tag, " variableDebt bal:"), dBal);
    }

    function _printSnapshot(string memory label, ProtocolState memory protocol, address admin) internal view {
        address userA = protocol.userA;
        address userB = protocol.userB;
        (uint256 aStaked,) = protocol.staking.deposits(userA);

        console.log("");
        console.log("=== SNAPSHOT:", label, "===");
        console.log("Admin K613:", protocol.k613.balanceOf(admin) / 1 ether);
        console.log("UserA K613:", protocol.k613.balanceOf(userA) / 1 ether);
        console.log("UserA xK613:", IERC20(address(protocol.xk613)).balanceOf(userA) / 1 ether);
        console.log("UserA staked:", aStaked / 1 ether);
        console.log("UserA RD:", protocol.rd.balanceOf(userA) / 1 ether);
        console.log("UserB K613:", protocol.k613.balanceOf(userB) / 1 ether);
        console.log("UserB xK613:", IERC20(address(protocol.xk613)).balanceOf(userB) / 1 ether);
        console.log("Staking backing:", protocol.staking.totalBacking() / 1 ether);
        console.log("RD totalDeposits:", protocol.rd.totalDeposits() / 1 ether);
        console.log("K613 totalSupply:", IERC20(address(protocol.k613)).totalSupply() / 1 ether);
        console.log("xK613 totalSupply:", IERC20(address(protocol.xk613)).totalSupply() / 1 ether);
    }
}

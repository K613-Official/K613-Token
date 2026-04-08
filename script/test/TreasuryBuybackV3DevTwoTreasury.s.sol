// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {RewardsDistributor} from "src/staking/RewardsDistributor.sol";
import {xK613} from "src/token/xK613.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

contract TreasuryBuybackV3DevTwoTreasury is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Treasury mainTreasury = Treasury(_mainTreasury());
        address usdc = vm.envAddress("USDC_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));

        address k613Addr = address(mainTreasury.k613());
        address xk613Addr = address(mainTreasury.xk613());
        address stakingAddr = address(mainTreasury.staking());
        address rdAddr = address(mainTreasury.rewardsDistributor());

        uint256 human = vm.envOr("DEV_HUMAN_TOKEN_AMOUNT", uint256(5));
        uint256 usdcXfer = human * (10 ** uint256(IERC20Metadata(usdc).decimals()));
        uint256 xXfer = human * (10 ** uint256(IERC20Metadata(xk613Addr).decimals()));

        require(IERC20(usdc).balanceOf(address(mainTreasury)) >= usdcXfer, "DevTwoTreasury: main USDC balance");
        require(IERC20(xk613Addr).balanceOf(address(mainTreasury)) >= xXfer, "DevTwoTreasury: main xK613 balance");

        vm.startBroadcast(pk);

        Treasury testTreasury = new Treasury(k613Addr, xk613Addr, stakingAddr, rdAddr);
        console.log("Test Treasury deployed:", address(testTreasury));

        xK613(xk613Addr).setTransferWhitelist(address(testTreasury), true);
        RewardsDistributor(rdAddr).grantRole(RewardsDistributor(rdAddr).REWARDS_NOTIFIER_ROLE(), address(testTreasury));

        mainTreasury.withdraw(usdc, address(testTreasury), usdcXfer);
        mainTreasury.withdraw(xk613Addr, address(testTreasury), xXfer);

        address pm = vm.envOr("POSITION_MANAGER_ADDRESS", address(0));
        if (pm != address(0)) {
            uint256 liqUsdc = vm.envUint("LIQUIDITY_USDC_AMOUNT");
            uint256 liqK613 = vm.envUint("LIQUIDITY_K613_AMOUNT");
            int24 tickLower = int24(vm.envInt("TICK_LOWER"));
            int24 tickUpper = int24(vm.envInt("TICK_UPPER"));
            require(IERC20(usdc).balanceOf(address(mainTreasury)) >= liqUsdc, "DevTwoTreasury: main USDC liq");
            require(IERC20(k613Addr).balanceOf(address(mainTreasury)) >= liqK613, "DevTwoTreasury: main K613 liq");
            mainTreasury.withdraw(usdc, deployer, liqUsdc);
            mainTreasury.withdraw(k613Addr, deployer, liqK613);

            address t0 = usdc < k613Addr ? usdc : k613Addr;
            address t1 = usdc < k613Addr ? k613Addr : usdc;
            uint256 amt0Desired = t0 == usdc ? liqUsdc : liqK613;
            uint256 amt1Desired = t1 == usdc ? liqUsdc : liqK613;

            IERC20(t0).approve(pm, amt0Desired);
            IERC20(t1).approve(pm, amt1Desired);

            (uint256 tokenId, uint128 liquidity,,) = INonfungiblePositionManager(pm)
                .mint(
                    INonfungiblePositionManager.MintParams({
                        token0: t0,
                        token1: t1,
                        fee: poolFee,
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        amount0Desired: amt0Desired,
                        amount1Desired: amt1Desired,
                        amount0Min: 0,
                        amount1Min: 0,
                        recipient: deployer,
                        deadline: block.timestamp + 3600
                    })
                );
            console.log("NPM position tokenId:", tokenId);
            console.log("NPM liquidity:", uint256(liquidity));
        }

        mainTreasury.setRouterWhitelist(router, true);
        testTreasury.setRouterWhitelist(router, true);

        uint256 minOut = vm.envUint("MIN_K613_OUT");
        bool distributeRewards = vm.envOr("DISTRIBUTE_REWARDS", uint256(1)) != 0;

        uint256 swapMain = vm.envOr("SWAP_USDC_MAIN_TREASURY", uint256(0));
        if (swapMain == 0) {
            swapMain = IERC20(usdc).balanceOf(address(mainTreasury));
        }
        uint256 swapTest = vm.envOr("SWAP_USDC_TEST_TREASURY", uint256(0));
        if (swapTest == 0) {
            swapTest = IERC20(usdc).balanceOf(address(testTreasury));
        }

        if (swapMain > 0) {
            uint256 outMain =
                mainTreasury.buybackV3ExactInputSingle(usdc, router, swapMain, minOut, poolFee, distributeRewards);
            console.log("Main Treasury buyback K613 out:", outMain);
        }
        if (swapTest > 0) {
            uint256 outTest =
                testTreasury.buybackV3ExactInputSingle(usdc, router, swapTest, minOut, poolFee, distributeRewards);
            console.log("Test Treasury buyback K613 out:", outTest);
        }

        vm.stopBroadcast();
    }

    function _mainTreasury() private view returns (address) {
        if (vm.envExists("MAIN_TREASURY_ADDRESS")) {
            return vm.envAddress("MAIN_TREASURY_ADDRESS");
        }
        if (vm.envExists("TREASURY_ADDRESS")) {
            return vm.envAddress("TREASURY_ADDRESS");
        }
        return vm.envAddress("K613_TREASURY_ADDRESS");
    }
}

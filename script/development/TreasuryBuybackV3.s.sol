// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Treasury} from "src/treasury/Treasury.sol";

contract TreasuryBuybackV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasuryAddr = _treasuryAddress();
        address tokenIn = vm.envAddress("TOKEN_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE"));
        uint256 amountIn = vm.envOr("AMOUNT", uint256(0));
        uint256 minK613Out = vm.envUint("MIN_K613_OUT");

        Treasury treasury = Treasury(treasuryAddr);
        address k613Addr = address(treasury.k613());
        require(tokenIn != k613Addr, "TOKEN_ADDRESS must not be K613");

        if (amountIn == 0) {
            amountIn = IERC20(tokenIn).balanceOf(treasuryAddr);
            console.log("Using full Treasury tokenIn balance:", amountIn);
        }
        require(amountIn != 0, "TreasuryBuybackV3: zero amount");

        console.log("Treasury:", treasuryAddr);
        console.log("Router  :", router);
        console.log("tokenIn :", tokenIn);
        console.log("K613    :", k613Addr);
        console.log("poolFee :", uint256(poolFee));
        console.log("amountIn:", amountIn);
        console.log("minOut  :", minK613Out);

        vm.startBroadcast(pk);
        uint256 k613Out = treasury.buybackV3ExactInputSingle(tokenIn, router, amountIn, minK613Out, poolFee, true);
        vm.stopBroadcast();

        console.log("Buyback V3 done. K613 out:", k613Out);
    }

    function _treasuryAddress() private view returns (address) {
        if (vm.envExists("TREASURY_ADDRESS")) {
            return vm.envAddress("TREASURY_ADDRESS");
        }
        return vm.envAddress("K613_TREASURY_ADDRESS");
    }
}

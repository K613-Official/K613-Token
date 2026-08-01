// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {K613TwapPriceFeed} from "src/oracles/K613TwapPriceFeed.sol";

/// @title DeployTwapPriceFeed
/// @notice Deploys the K613/USDC TWAP reward oracle and, if needed, grows the pool's observation
///         buffer so a full 30-minute average can be served (the pool ships with cardinality 1,
///         which would make the feed fall back to the spot tick forever). Growing the buffer is
///         permissionless; the slots fill as swaps happen, so the TWAP becomes available only after
///         the pool has traded across the window — until then the feed reports spot, by design.
/// @dev Env interface: PRIVATE_KEY only. Post-deploy, the xK613 emission admin must point the
///      incentives at the new feed:
///        cast send <EmissionManager> "setRewardOracle(address,address)" <xK613> <feed>
contract DeployTwapPriceFeed is Script {
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;
    address private constant POOL = 0xDD5557CEcFD7Ba0F5F2A1C38967d83Df2951a4F4;
    address private constant XK613 = 0x9064d55A8A8473fA39c41A16492Fa1094Eb4E8b5;
    address private constant EMISSION_MANAGER = 0x7eEdb2D4D4b89b8B854c734e8fAABfB24E0537A6;

    /// @notice Observation slots to keep. 60 covers the 30-minute window unless the pool sees more
    ///         than 60 swaps within it, which the fallback handles anyway.
    uint16 private constant TARGET_CARDINALITY = 60;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        uint256 pk = vm.envUint("PRIVATE_KEY");

        (,,,, uint16 cardinalityNext,,) = IUniswapV3Pool(POOL).slot0();

        vm.startBroadcast(pk);
        K613TwapPriceFeed feed = new K613TwapPriceFeed();
        if (cardinalityNext < TARGET_CARDINALITY) {
            IUniswapV3Pool(POOL).increaseObservationCardinalityNext(TARGET_CARDINALITY);
        }
        vm.stopBroadcast();

        int256 answer = feed.latestAnswer();
        require(answer > 0, "feed returned non-positive answer");

        console.log("--- K613TwapPriceFeed deployed (Monad mainnet 143) ---");
        console.log("  Feed:            ", address(feed));
        console.log("  latestAnswer (8d):", uint256(answer));
        console.log("  TWAP available:  ", feed.twapAvailable());
        console.log("  observation cardinalityNext was:", uint256(cardinalityNext));
        console.log("");
        console.log("REMAINING STEP - point the incentives at it (xK613 emission admin):");
        console.log("  cast send", EMISSION_MANAGER);
        console.log("    \"setRewardOracle(address,address)\"", XK613);
        console.log("   ", address(feed));
    }
}

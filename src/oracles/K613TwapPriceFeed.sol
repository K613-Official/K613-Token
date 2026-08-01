// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AggregatorInterface} from "lib/K613-Protocol/src/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @title K613TwapPriceFeed
/// @notice Chainlink-shaped price feed reporting the USD price of K613 (and therefore xK613, which
///         is backed 1:1) from the protocol-owned Uniswap V3 K613/USDC pool. Replaces the fixed
///         `StaticRewardPriceFeed` as the reward oracle of the Aave incentives so displayed reward
///         APRs track the market instead of a hardcoded listing price.
/// @dev The reward oracle is DISPLAY-ONLY: emissions are denominated in tokens per second, so a
///      manipulated answer skews shown APRs but never changes what users actually receive.
///      Two safety properties matter more than precision here:
///        1. it must NEVER revert — a reverting reward oracle bricks `UiIncentiveDataProviderV3`
///           and with it the whole markets page (that exact failure took the UI down in July 2026);
///           so the TWAP read is wrapped and falls back to the spot tick.
///        2. the answer is clamped to [MIN_ANSWER, MAX_ANSWER], bounding how far a cheap swap in a
///           thin pool can move the displayed APR.
///      USDC is treated as $1; the pool is the only price source.
contract K613TwapPriceFeed is AggregatorInterface {
    /// @notice Monad mainnet K613/USDC Uniswap V3 pool, 0.05% fee (docs/OPERATIONS_SOP.md D.3).
    address public constant POOL = 0xDD5557CEcFD7Ba0F5F2A1C38967d83Df2951a4F4;
    address public constant K613 = 0xb09582631336068d4B0089d943f40CbF46dE5189;
    address public constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    /// @notice Averaging window. Requires the pool's observation cardinality to cover it; if it
    ///         does not (or the pool is too young), the feed degrades to the spot tick.
    uint32 public constant TWAP_WINDOW = 30 minutes;

    /// @notice Answer decimals — 8, matching Chainlink USD feeds and the previous static feed.
    uint8 private constant ANSWER_DECIMALS = 8;
    /// @dev The pool quotes USDC (6 decimals); scale that quote to 8-decimal answers.
    uint256 private constant QUOTE_TO_ANSWER = 100;
    /// @dev One whole K613 as the base amount of the quote.
    uint128 private constant ONE_K613 = 1e18;

    /// @notice Lower clamp: $0.002.
    int256 public constant MIN_ANSWER = 200_000;
    /// @notice Upper clamp: $0.05.
    int256 public constant MAX_ANSWER = 5_000_000;

    /// @inheritdoc AggregatorInterface
    function decimals() external pure override returns (uint8) {
        return ANSWER_DECIMALS;
    }

    /// @inheritdoc AggregatorInterface
    function description() external pure override returns (string memory) {
        return "xK613 / USD (Uniswap V3 TWAP)";
    }

    /// @notice Clamped TWAP price of one K613 in USD, 8 decimals.
    function latestAnswer() public view override returns (int256) {
        uint256 quote = OracleLibrary.getQuoteAtTick(_tick(), ONE_K613, K613, USDC);
        int256 answer = int256(quote * QUOTE_TO_ANSWER);
        if (answer < MIN_ANSWER) return MIN_ANSWER;
        if (answer > MAX_ANSWER) return MAX_ANSWER;
        return answer;
    }

    /// @notice Always the current block — the answer is derived on read, never pushed.
    function latestTimestamp() public view override returns (uint256) {
        return block.timestamp;
    }

    /// @notice Round ids are meaningless for a derived feed; a constant keeps consumers happy.
    function latestRound() public pure override returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorInterface
    function getAnswer(uint256) external view override returns (int256) {
        return latestAnswer();
    }

    /// @inheritdoc AggregatorInterface
    function getTimestamp(uint256) external view override returns (uint256) {
        return block.timestamp;
    }

    /// @inheritdoc AggregatorInterface
    function getRoundData(uint80 roundId_)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (roundId_, latestAnswer(), block.timestamp, block.timestamp, roundId_);
    }

    /// @inheritdoc AggregatorInterface
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, latestAnswer(), block.timestamp, block.timestamp, 1);
    }

    /// @notice True while the pool can serve a full `TWAP_WINDOW` average; false means `latestAnswer`
    ///         is currently falling back to the spot tick. Useful for monitoring after cardinality
    ///         changes — not consumed on-chain.
    function twapAvailable() external view returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        try IUniswapV3Pool(POOL).observe(secondsAgos) returns (int56[] memory, uint160[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev TWAP tick over `TWAP_WINDOW`, falling back to the spot tick when the pool cannot serve
    ///      the window (insufficient observation cardinality, or a pool younger than the window).
    function _tick() private view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(POOL).observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int24 tick = int24(delta / int56(uint56(TWAP_WINDOW)));
            // Uniswap rounds towards negative infinity for negative averages.
            if (delta < 0 && (delta % int56(uint56(TWAP_WINDOW)) != 0)) tick--;
            return tick;
        } catch {
            (, int24 spotTick,,,,,) = IUniswapV3Pool(POOL).slot0();
            return spotTick;
        }
    }
}

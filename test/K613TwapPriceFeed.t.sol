// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613TwapPriceFeed} from "../src/oracles/K613TwapPriceFeed.sol";

/// @dev Minimal stand-in for the K613/USDC pool, etched at the feed's hardcoded `POOL` constant.
///      Only the two calls the feed makes are implemented; each can be told to revert so the
///      fallback path can be exercised.
contract MockV3Pool {
    int24 public spotTick;
    int56 public cumulativeDelta;
    bool public observeReverts;
    bool public slot0Reverts;

    function setSpotTick(int24 t) external {
        spotTick = t;
    }

    function setCumulativeDelta(int56 d) external {
        cumulativeDelta = d;
    }

    function setObserveReverts(bool v) external {
        observeReverts = v;
    }

    function setSlot0Reverts(bool v) external {
        slot0Reverts = v;
    }

    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory) {
        require(!observeReverts, "OLD");
        int56[] memory cumulatives = new int56[](2);
        cumulatives[0] = 0;
        cumulatives[1] = cumulativeDelta;
        uint160[] memory liq = new uint160[](2);
        return (cumulatives, liq);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        require(!slot0Reverts, "slot0");
        return (0, spotTick, 0, 0, 0, 0, true);
    }
}

/// @title K613TwapPriceFeedTest
/// @notice The feed exists to satisfy two properties, neither of which had a test: it must never
///         revert (a reverting reward oracle bricks `UiIncentiveDataProviderV3` and with it the
///         markets page), and its answer must stay inside [MIN_ANSWER, MAX_ANSWER] so a cheap swap
///         in a thin pool cannot move what consumers see. Since `K613TreasuryOperatorV2` now uses
///         this same feed as the floor for `runBuyback`, the clamp is no longer display-only —
///         these tests pin it as a money-path property.
contract K613TwapPriceFeedTest is Test {
    K613TwapPriceFeed private feed;
    MockV3Pool private pool;

    int24 private constant TWAP_WINDOW_I = 1800;

    function setUp() public {
        feed = new K613TwapPriceFeed();
        MockV3Pool impl = new MockV3Pool();
        vm.etch(feed.POOL(), address(impl).code);
        pool = MockV3Pool(feed.POOL());
    }

    /// @dev The feed divides the cumulative delta by the window, so seed the delta from the tick.
    function _setTwapTick(int24 tick) private {
        pool.setCumulativeDelta(int56(tick) * TWAP_WINDOW_I);
        pool.setSpotTick(tick);
    }

    function test_Decimals_MatchesChainlinkUsdConvention() public view {
        assertEq(feed.decimals(), 8);
    }

    function test_Description() public view {
        assertEq(feed.description(), "xK613 / USD (Uniswap V3 TWAP)");
    }

    /// @notice The clamp is the entire protection against a thin-pool price push. It must hold for
    ///         any tick the pool can report, not just plausible ones.
    function testFuzz_AnswerAlwaysWithinClamp(int24 tick) public {
        // Bounded to the range TickMath accepts; outside it Uniswap itself would revert.
        tick = int24(bound(int256(tick), -887000, 887000));
        _setTwapTick(tick);

        int256 answer = feed.latestAnswer();
        assertGe(answer, feed.MIN_ANSWER(), "below floor");
        assertLe(answer, feed.MAX_ANSWER(), "above ceiling");
    }

    function test_ExtremeTicks_ClampToBothBounds() public {
        // K613 is token1 in the live pool, so a very negative tick prices it high and a very
        // positive one prices it near zero. Assert both ends land exactly on their bound.
        _setTwapTick(-887000);
        assertEq(feed.latestAnswer(), feed.MAX_ANSWER(), "should clamp to ceiling");

        _setTwapTick(887000);
        assertEq(feed.latestAnswer(), feed.MIN_ANSWER(), "should clamp to floor");
    }

    /// @notice The documented degradation: a pool that cannot serve the window must not take the
    ///         feed down with it.
    function test_ObserveReverts_FallsBackToSpotAndDoesNotRevert() public {
        _setTwapTick(0);
        int256 viaTwap = feed.latestAnswer();

        pool.setObserveReverts(true);
        int256 viaSpot = feed.latestAnswer();

        assertEq(viaSpot, viaTwap, "spot fallback should price the same tick identically");
        assertFalse(feed.twapAvailable(), "twapAvailable must report the degradation");
    }

    function test_TwapAvailable_TracksPoolCapability() public {
        _setTwapTick(0);
        assertTrue(feed.twapAvailable());
        pool.setObserveReverts(true);
        assertFalse(feed.twapAvailable());
    }

    /// @notice The gap the NatSpec does not mention: the fallback has no fallback. If the pool
    ///         cannot serve `observe` AND `slot0` — it has no code, is a different contract, or is
    ///         mid-upgrade — `latestAnswer` reverts, which is the exact failure the contract was
    ///         written to prevent. `POOL` is an immutable constant, so there is no recovery short
    ///         of redeploying the feed and repointing every consumer.
    function test_BothPoolCallsRevert_FeedRevertsWithNoRecovery() public {
        pool.setObserveReverts(true);
        pool.setSlot0Reverts(true);
        vm.expectRevert();
        feed.latestAnswer();
    }

    /// @notice Same failure reached the other way: a `POOL` address holding no code at all.
    function test_PoolWithoutCode_FeedReverts() public {
        vm.etch(feed.POOL(), "");
        vm.expectRevert();
        feed.latestAnswer();
    }

    function test_ChainlinkShapedGetters_AgreeWithLatestAnswer() public {
        _setTwapTick(0);
        int256 answer = feed.latestAnswer();

        assertEq(feed.getAnswer(1), answer);
        assertEq(feed.latestTimestamp(), block.timestamp);
        assertEq(feed.getTimestamp(1), block.timestamp);
        assertEq(feed.latestRound(), 1);

        (uint80 roundId, int256 a, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) = feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(a, answer);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredIn, 1);

        (uint80 rid2, int256 a2,,, uint80 answeredIn2) = feed.getRoundData(42);
        assertEq(rid2, 42, "getRoundData echoes the requested round");
        assertEq(a2, answer);
        assertEq(answeredIn2, 42);
    }

    /// @notice A realistic tick must survive unclamped, otherwise the clamp — not the pool — is
    ///         what everyone is reading. Tick 322880 is roughly the live price (~$0.0095): the base
    ///         amount is 1e18 K613 and the quote is 6-decimal USDC, so the whole band sits far from
    ///         zero.
    function test_RealisticTick_PricesInsideTheClampBand() public {
        _setTwapTick(322880);
        int256 answer = feed.latestAnswer();

        assertGt(answer, feed.MIN_ANSWER(), "must not sit on the floor");
        assertLt(answer, feed.MAX_ANSWER(), "must not sit on the ceiling");
        // ~$0.0095 with 8 decimals, allowing for tick granularity.
        assertApproxEqRel(answer, int256(950_000), 0.02e18);
    }

    /// @notice The band in which the pool actually governs the answer is narrow, and both edges are
    ///         compile-time constants. Outside roughly tick 306200..338450 — K613 over $0.05 or
    ///         under $0.002 — the feed stops tracking the market entirely. Worth pinning because
    ///         `K613TreasuryOperatorV2` derives its buyback floor from this number: once K613 trades
    ///         above $0.05 the floor demands more K613 than the market gives and `runBuyback`
    ///         reverts until governance repoints `setPriceGuard`.
    function test_ClampBandEdges_AreWhereTrackingStops() public {
        _setTwapTick(300000);
        assertEq(feed.latestAnswer(), feed.MAX_ANSWER(), "K613 over $0.05 reads as exactly $0.05");

        _setTwapTick(345000);
        assertEq(feed.latestAnswer(), feed.MIN_ANSWER(), "K613 under $0.002 reads as exactly $0.002");
    }

    /// @notice The negative-average rounding correction in `_tick` cannot be observed through the
    ///         public API: a negative tick prices K613 above $1, which is 20x the ceiling, so every
    ///         such answer is clamped to MAX_ANSWER regardless of whether the correction ran. The
    ///         branch is defensive only. Pinned so nobody "simplifies" it believing it is load-
    ///         bearing, and so the reason is recorded rather than rediscovered.
    function test_NegativeAverage_CorrectionIsMaskedByTheClamp() public {
        // Delta that does not divide evenly by the window: the correction path runs.
        pool.setCumulativeDelta(-(TWAP_WINDOW_I * 100) - 1);
        int256 corrected = feed.latestAnswer();

        // The truncated tick, reached via the spot fallback: the correction path does not run.
        pool.setSpotTick(-100);
        pool.setObserveReverts(true);
        int256 truncated = feed.latestAnswer();

        assertEq(corrected, truncated, "clamp masks the one-tick difference");
        assertEq(corrected, feed.MAX_ANSWER(), "both sit on the ceiling");
    }
}

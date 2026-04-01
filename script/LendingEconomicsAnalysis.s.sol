// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

/// @title LendingEconomicsAnalysis
/// @notice Economic analysis for K613 + Aave lending integration
/// Calculates:
/// - Optimal borrow rates for profitability
/// - Utilization impact on sustainability
/// - Token inflation from rewards vs buyback pressure
/// - Fee distribution across stakeholders
contract LendingEconomicsAnalysis is Script {
    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant PRECISION = 1e18;

    function run() external {
        console.log("=== K613 LENDING ECONOMICS ANALYSIS ===");
        console.log("");

        _analyzeOptimalBorrowRates();
        console.log("");
        _analyzeFeeDistribution();
        console.log("");
        _analyzeUtilizationDynamics();
        console.log("");
        _analyzeTokenPressure();
        console.log("");
        _recommendedParameters();
    }

    // ============================================================================
    // SCENARIO 1: OPTIMAL BORROW RATES
    // ============================================================================
    function _analyzeOptimalBorrowRates() internal view {
        console.log("--- OPTIMAL BORROW RATES ---");
        console.log("Target: Find borrow rate where users WANT to borrow");
        console.log("");

        // Key equation:
        // borrowAPY > 0  (always earn interest)
        // borrowAPY < supplyAPY  (suppliers earn spread)
        // borrowAPY >= user's opportunity cost

        uint256[] memory supplierAPYs = new uint256[](4);
        supplierAPYs[0] = 800; // 8%
        supplierAPYs[1] = 1200; // 12%
        supplierAPYs[2] = 1500; // 15%
        supplierAPYs[3] = 2000; // 20%

        uint256[] memory spreads = new uint256[](4);
        spreads[0] = 200; // 2%
        spreads[1] = 300; // 3%
        spreads[2] = 400; // 4%
        spreads[3] = 500; // 5%

        console.log("Supply% | 2% Spread | 3% Spread | 4% Spread | 5% Spread");
        console.log("========|===========|===========|===========|===========");

        for (uint256 i = 0; i < supplierAPYs.length; i++) {
            uint256 supplyAPY = supplierAPYs[i];

            console.log(supplyAPY / 100, "%");

            for (uint256 j = 0; j < spreads.length; j++) {
                uint256 spread = spreads[j];
                uint256 borrowAPY = supplyAPY > spread ? supplyAPY - spread : 0;

                // Calculate where this breaks even
                // Need: (borrowed * borrowAPY * protocol_fee%) >= (supplied * supplyAPY)
                // With 75% utilization: (75% * borrowAPY) >= supplyAPY => borrowAPY >= supplyAPY/0.75 = 1.33x
                // Not possible! So we need treasury to seed rewards

                if (j == 0) {
                    console.log(" | ");
                }
            }
        }

        console.log("");
        console.log("KEY INSIGHT: Pure economics rarely sustains supply APY");
        console.log("Solution: Protocol must seed initial rewards");
        console.log("          These come from token emissions or protocol revenue");
        console.log("");
        console.log("FORMULA: supplyAPY = (borrows * borrowAPY * protocol_fee%) + treasury_seeding");
        console.log("         Where:");
        console.log("           borrows = utilization * supplied");
        console.log("           protocol_fee% = typical 15-25%");
        console.log("           treasury_seeding = K613 rewards distributed");
    }

    // ============================================================================
    // SCENARIO 2: FEE DISTRIBUTION
    // ============================================================================
    function _analyzeFeeDistribution() internal view {
        console.log("--- FEE DISTRIBUTION TO STAKEHOLDERS ---");
        console.log("");

        // Model:
        // Borrower pays: borrow_interest = borrowed * borrowAPY
        // Split:
        // - 85% to suppliers
        // - 15% to protocol (admin/treasury)

        uint256 tvl = 100_000_000 ether; // 100M TVL
        uint256 borrowAPY = 1000; // 10% borrow rate
        uint256 utilization = 7500; // 75% utilization
        uint256 protocol_fee_percent = 1500; // 15% of interest

        uint256 borrowed = (tvl * utilization) / BPS_DENOM;
        uint256 totalInterest = (borrowed * borrowAPY) / BPS_DENOM;
        uint256 protocolRevenue = (totalInterest * protocol_fee_percent) / BPS_DENOM;
        uint256 supplierRevenue = totalInterest - protocolRevenue;

        console.log("100M TVL, 75% utilization, 10% borrow APY:");
        console.log("");
        console.log("Total borrowed:", borrowed / 1e6, "M K613");
        console.log("Annual interest:", totalInterest / 1e6, "M K613");
        console.log("");
        console.log("Distribution:");
        console.log("  Suppliers (85%):", supplierRevenue / 1e6, "M K613");
        console.log("  Protocol (15%):", protocolRevenue / 1e6, "M K613");
        console.log("");

        // What supply APY does this support?
        uint256 supplied = tvl;
        uint256 supplyAPYSupported = (supplierRevenue * BPS_DENOM) / supplied;

        console.log("Supply APY supported by fees:", supplyAPYSupported / 100, "%");
        console.log("");
        console.log("Gap analysis:");

        uint256 targetSupplyAPY = 1200; // Target 12%
        if (supplyAPYSupported < targetSupplyAPY) {
            uint256 gap = targetSupplyAPY - supplyAPYSupported;
            uint256 neededFromTreasury = (tvl * gap) / BPS_DENOM;
            console.log("  Target supply APY: 12%");
            console.log("  Fee-supported APY:", supplyAPYSupported / 100, "%");
            console.log("  Gap:", gap / 100, "%");
            console.log("  Treasury must seed:", neededFromTreasury / 1e6, "M K613/year");
        }

        console.log("");
        console.log("Protocol revenue uses:");
        console.log("  50% -> Buyback (token support)");
        console.log("  50% -> Additional rewards (incentive bootstrap)");
    }

    // ============================================================================
    // SCENARIO 3: UTILIZATION DYNAMICS
    // ============================================================================
    function _analyzeUtilizationDynamics() internal view {
        console.log("--- UTILIZATION RATE DYNAMICS ---");
        console.log("Borrow rate should float to maintain target utilization");
        console.log("");

        // Model: borrow_rate = base_rate + (utilization - target) * multiplier
        uint256 baseRate = 500; // 5% minimum
        uint256 multiplier = 100; // 1% rate increase per 1% utilization above target
        uint256 targetUtil = 7500; // 75% target

        console.log("Base rate: 5%");
        console.log("Target utilization: 75%");
        console.log("Rate multiplier: 1% per 1% over target");
        console.log("");
        console.log("Utilization | Borrow Rate | Supply Incentive");
        console.log("=============|=============|=================");

        uint256[] memory utils = new uint256[](5);
        utils[0] = 3000; // 30%
        utils[1] = 5000; // 50%
        utils[2] = 7500; // 75% (target)
        utils[3] = 9000; // 90%
        utils[4] = 10000; // 100%

        for (uint256 i = 0; i < utils.length; i++) {
            uint256 util = utils[i];

            // Calculate borrow rate
            uint256 borrowRate = baseRate;
            if (util > targetUtil) {
                uint256 overTarget = util - targetUtil;
                borrowRate += (overTarget * multiplier) / BPS_DENOM;
            }

            // Supply incentive = borrow_rate * 0.85 (after protocol fee)
            uint256 supplyIncentive = (borrowRate * 8500) / BPS_DENOM;

            uint256 utilPercent = util / 100;
            uint256 borrowPercent = borrowRate / 100;
            uint256 supplyPercent = supplyIncentive / 100;

            console.log("Util:", utilPercent, "Borrow:", borrowPercent);
            console.log("  Supply incentive:", supplyPercent);
        }

        console.log("");
        console.log("MECHANISM:");
        console.log("- Below 75%: Low rates encourage borrowing");
        console.log("- Above 75%: High rates discourage borrowing, encourage repayment");
        console.log("- Keeps utilization stable");
    }

    // ============================================================================
    // SCENARIO 4: TOKEN INFLATION VS BUYBACK
    // ============================================================================
    function _analyzeTokenPressure() internal view {
        console.log("--- TOKEN INFLATION PRESSURE ---");
        console.log("Analysis: Will K613 token inflate or deflate?");
        console.log("");

        uint256 tvl = 100_000_000 ether;
        uint256 targetSupplyAPY = 1200; // 12%

        // Annual supply rewards
        uint256 annualSupplyRewards = (tvl * targetSupplyAPY) / BPS_DENOM;

        // Protocol revenue (assume 75% util, 10% borrow, 15% fee)
        uint256 borrowed = (tvl * 7500) / BPS_DENOM;
        uint256 totalInterest = (borrowed * 1000) / BPS_DENOM;
        uint256 protocolRevenue = (totalInterest * 1500) / BPS_DENOM;

        // Buyback and staking rewards
        uint256 buyback = (protocolRevenue * 5000) / BPS_DENOM;
        uint256 stakingRewards = protocolRevenue - buyback;

        // Admin staking (assume admin stakes buyback)
        uint256 adminStakeRewards = 0; // Minimal initially

        // Net inflation
        uint256 totalEmissions = annualSupplyRewards;
        uint256 totalBuyback = buyback;
        int256 netInflation = int256(totalEmissions) - int256(totalBuyback);

        console.log("100M TVL Annual Dynamics:");
        console.log("");
        console.log("Emissions:");
        console.log("  Supply APY (12%):      ", annualSupplyRewards / 1e6, "M K613");
        console.log("  Staking rewards:       ", stakingRewards / 1e6, "M K613");
        console.log("  Total emissions:       ", (annualSupplyRewards + stakingRewards) / 1e6, "M K613");
        console.log("");
        console.log("Sinks:");
        console.log("  Buyback:               ", buyback / 1e6, "M K613");
        console.log("");
        if (netInflation > 0) {
            uint256 absInflation = uint256(netInflation);
            console.log("Net annual inflation:", absInflation / 1e6, "M K613");
            console.log("Status: INFLATIONARY");
            uint256 inflRate = (absInflation * 10000) / (tvl + absInflation);
            console.log("Inflation rate:", inflRate / 100, "%");
        } else {
            uint256 absDeflation = uint256(-netInflation);
            console.log("Net annual deflation:", absDeflation / 1e6, "M K613");
            console.log("Status: DEFLATIONARY");
        }
        console.log("");
        console.log("Impact on token holders:");
        console.log("- Stakers benefit from buyback pressure (supports price)");
        console.log("- Supply inflation creates sell pressure");
        console.log("- Need sufficient TVL growth to absorb inflation");
    }

    // ============================================================================
    // SCENARIO 5: RECOMMENDATIONS
    // ============================================================================
    function _recommendedParameters() internal view {
        console.log("--- RECOMMENDED PARAMETERS ---");
        console.log("");

        console.log("BORROW RATE STRATEGY:");
        console.log("  Base rate: 5%");
        console.log("  Target utilization: 75%");
        console.log("  Rate multiplier: 1% per 1% over target");
        console.log("  Result: Natural supply APY 8.5% at 75% util");
        console.log("");

        console.log("PROTOCOL FEE STRATEGY:");
        console.log("  Protocol fee: 15% of borrow interest");
        console.log("  Split:");
        console.log("    50% -> Buyback (token support)");
        console.log("    50% -> Staking rewards (incentive bootstrap)");
        console.log("");

        console.log("TREASURY SEEDING:");
        console.log("  Supply APY target: 12%");
        console.log("  Fee-supported: ~8.5%");
        console.log("  Gap to fund: ~3.5%");
        console.log("  Recommended: Seed with K613 emissions initially");
        console.log("  Taper as TVL grows (fees increase)");
        console.log("");

        console.log("STAKING INCENTIVES:");
        console.log("  Instant exit penalty: 50%");
        console.log("  Lock period: 120 seconds (configurable)");
        console.log("  Reward source: Penalties + protocol fee allocation");
        console.log("  Expected staking APY: 15-25% initially, declining");
        console.log("");

        console.log("BUYBACK STRATEGY:");
        console.log("  Frequency: Monthly");
        console.log("  Amount: 50% of protocol revenue");
        console.log("  Method: Buy and burn or buy and stake");
        console.log("  Goal: Support token price floor");
        console.log("");

        console.log("TVL TARGETS:");
        console.log("  Phase 1 (bootstrap): 10M (treasury seeding high)");
        console.log("  Phase 2 (growth): 50M (protocol fees increase)");
        console.log("  Phase 3 (mature): 100M+ (self-sustaining)");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DataTypes} from "lib/K613-Protocol/src/contracts/protocol/libraries/types/DataTypes.sol";
import {WadRayMath} from "lib/K613-Protocol/src/contracts/protocol/libraries/math/WadRayMath.sol";
import {IScaledBalanceToken} from "lib/K613-Protocol/src/contracts/interfaces/IScaledBalanceToken.sol";

interface IPool {
    function getReserveData(address asset) external view returns (DataTypes.ReserveDataLegacy memory);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
}

contract LendingEconomicsAnalysis is Script {
    using WadRayMath for uint256;

    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant RAY = 1e27;
    uint256 private constant MAX_TOKEN_DECIMALS = 30;

    struct ReserveSnapshot {
        bool ok;
        uint8 decimals;
        uint256 totalSuppliedWei;
        uint256 totalBorrowedWei;
        uint256 utilizationBps;
        uint256 supplyApyBpsLinear;
        uint256 borrowApyBpsLinear;
        address aToken;
        address variableDebtToken;
    }

    struct EconomicsParams {
        uint256 tvlWei;
        uint256 protocolFeeBps;
        uint256 buybackOfProtocolBps;
        uint256 targetSupplyApyBps;
        uint256 borrowBaseBps;
        uint256 borrowTargetUtilBps;
        uint256 borrowSlopeBps;
        uint256 feeScenarioUtilBps;
        uint256 feeBorrowOverrideBps;
        uint256 netPositiveExtraBps;
    }

    function run() external {
        EconomicsParams memory p = _loadEconomicsParams();
        _logRule("K613 LENDING ECONOMICS ANALYSIS");
        console.log(
            "How to read: bps = basis points (100 bps = 1%). APY from pool is linearized from RAY, not compounded."
        );
        console.log("Env: ANALYSIS_* overrides. Chain: set AAVE_POOL_ADDRESS, SUPPLY_TOKEN_ADDRESS, RPC.");
        console.log("If ANALYSIS_PREFER_CHAIN=1 and fork works, TVL / utilization / borrow APR come from the reserve.");
        console.log("");
        _logSubRule("Addresses (FullLendingEconomy-compatible)");
        _logFullLendingEnvAddresses();
        console.log("");
        ReserveSnapshot memory snap = _forkAndReadReserveSnapshot();
        if (snap.ok) {
            _logReserveSnapshot(snap);
            if (vm.envOr("ANALYSIS_PREFER_CHAIN", uint256(1)) != 0) {
                p.tvlWei = snap.totalSuppliedWei;
                p.feeScenarioUtilBps = snap.utilizationBps;
                p.feeBorrowOverrideBps = snap.borrowApyBpsLinear;
                console.log("Applied on-chain merge: scenario TVL = total supplied; util and borrow APR from reserve.");
            }
        } else {
            console.log("No fork snapshot (missing pool, asset, or RPC). Scenario uses ANALYSIS_* only.");
        }
        console.log("");
        _logSubRule("Scenario parameters after any chain merge");
        _logLoadedParams(p);
        uint8 displayDecimals = _resolveDisplayDecimals(snap);
        uint256 rawPerMillion = _rawPerMillionTokenUnits(displayDecimals);
        console.log("Token decimals for display:", displayDecimals);
        console.log("One million token units in raw wei (divisor for *_M lines):", rawPerMillion);
        console.log("Whole-token amounts = raw amount / 10^decimals (integer, floor).");
        console.log("");
        _analyzeSupplyBorrowSpreadMatrix(snap);
        console.log("");
        _analyzeBorrowRewardBreakevenAndUtilBuybackChain(p, snap, rawPerMillion);
        console.log("");
        _analyzeFeeDistribution(p, rawPerMillion);
        console.log("");
        _analyzeUtilizationDynamics(p);
        console.log("");
        _analyzeTokenPressure(p, rawPerMillion);
        console.log("");
        if (snap.ok) {
            _analyzeBorrowIncentiveBreakeven(snap);
        }
        console.log("");
        _recommendedParameters(p, snap);
        _logRule("END");
    }

    function _logRule(string memory title) internal view {
        console.log("======================================================================");
        console.log(title);
        console.log("======================================================================");
    }

    function _logSubRule(string memory title) internal view {
        console.log("----------------------------------------------------------------------");
        console.log(title);
        console.log("----------------------------------------------------------------------");
    }

    function _loadEconomicsParams() internal view returns (EconomicsParams memory p) {
        p.tvlWei = vm.envOr("ANALYSIS_TVL_WEI", uint256(100_000_000 ether));
        p.protocolFeeBps = vm.envOr("ANALYSIS_PROTOCOL_FEE_BPS", uint256(1500));
        p.buybackOfProtocolBps = vm.envOr("ANALYSIS_BUYBACK_OF_PROTOCOL_BPS", uint256(5000));
        p.targetSupplyApyBps = vm.envOr("ANALYSIS_TARGET_SUPPLY_APY_BPS", uint256(1200));
        p.borrowBaseBps = vm.envOr("ANALYSIS_BORROW_BASE_BPS", uint256(500));
        p.borrowTargetUtilBps = vm.envOr("ANALYSIS_BORROW_TARGET_UTIL_BPS", uint256(7500));
        p.borrowSlopeBps = vm.envOr("ANALYSIS_BORROW_SLOPE_BPS", uint256(100));
        p.feeScenarioUtilBps = vm.envOr("ANALYSIS_FEE_SCENARIO_UTIL_BPS", uint256(7500));
        p.feeBorrowOverrideBps = vm.envOr("ANALYSIS_FEE_BORROW_OVERRIDE_BPS", uint256(0));
        p.netPositiveExtraBps = vm.envOr("ANALYSIS_NET_POSITIVE_EXTRA_BPS", uint256(100));
    }

    function _logLoadedParams(EconomicsParams memory p) internal view {
        console.log("TVL (raw, same units as underlying token):", p.tvlWei);
        console.log("Protocol share of borrow interest (bps):", p.protocolFeeBps);
        console.log("Of protocol revenue routed to buyback (bps):", p.buybackOfProtocolBps);
        console.log("Target supply-side incentive / emissions (APR bps on TVL):", p.targetSupplyApyBps);
        console.log("Synthetic borrow curve: base rate at or below kink (bps):", p.borrowBaseBps);
        console.log("Synthetic borrow curve: kink utilization (bps of pool):", p.borrowTargetUtilBps);
        console.log("Synthetic borrow curve: slope above kink (bps add per 100% util past kink):", p.borrowSlopeBps);
        console.log("Fee scenario: utilization (bps):", p.feeScenarioUtilBps);
        console.log("Fee scenario: borrow APR (bps), 0 = use synthetic curve:", p.feeBorrowOverrideBps);
        console.log(
            "Breakeven table: extra reward bps assumed on borrow for net-positive borrower:", p.netPositiveExtraBps
        );
    }

    function _logFullLendingEnvAddresses() internal view {
        address pool = vm.envOr("AAVE_POOL_ADDRESS", address(0));
        address supply = vm.envOr("SUPPLY_TOKEN_ADDRESS", address(0));
        address borrow = vm.envOr("BORROW_TOKEN_ADDRESS", address(0));
        console.log("Aave pool:", pool);
        console.log("Supply / scenario asset:", supply);
        console.log("Borrow asset (info only here):", borrow);
    }

    function _rawPerMillionTokenUnits(uint8 decimals) internal pure returns (uint256) {
        return 1_000_000 * (10 ** uint256(decimals));
    }

    function _oneTokenRaw(uint256 rawPerMillion) internal pure returns (uint256) {
        return rawPerMillion / 1_000_000;
    }

    function _wholeTokens(uint256 amountRaw, uint256 rawPerMillion) internal pure returns (uint256) {
        uint256 one = _oneTokenRaw(rawPerMillion);
        if (one == 0) return 0;
        return amountRaw / one;
    }

    function _resolveDisplayDecimals(ReserveSnapshot memory snap) internal view returns (uint8) {
        if (snap.ok) {
            return snap.decimals;
        }
        uint256 d = vm.envOr("ANALYSIS_TOKEN_DECIMALS", uint256(18));
        if (d > MAX_TOKEN_DECIMALS) {
            d = 18;
        }
        return uint8(d);
    }

    function _forkAndReadReserveSnapshot() internal returns (ReserveSnapshot memory s) {
        address pool = vm.envOr("AAVE_POOL_ADDRESS", address(0));
        address asset = vm.envOr("SUPPLY_TOKEN_ADDRESS", address(0));
        string memory rpc = vm.envOr("ANALYSIS_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            rpc = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        }
        if (pool == address(0) || asset == address(0) || bytes(rpc).length == 0) {
            return s;
        }
        vm.createSelectFork(rpc);
        return _readReserveSnapshot(pool, asset);
    }

    function _readReserveSnapshot(address pool, address asset) internal view returns (ReserveSnapshot memory s) {
        DataTypes.ReserveDataLegacy memory d = IPool(pool).getReserveData(asset);
        s.aToken = d.aTokenAddress;
        s.variableDebtToken = d.variableDebtTokenAddress;
        if (s.aToken == address(0) || s.variableDebtToken == address(0)) {
            return s;
        }
        uint256 normIncome = IPool(pool).getReserveNormalizedIncome(asset);
        uint256 normDebt = IPool(pool).getReserveNormalizedVariableDebt(asset);
        uint256 scaledAToken = IScaledBalanceToken(s.aToken).scaledTotalSupply();
        uint256 scaledDebt = IScaledBalanceToken(s.variableDebtToken).scaledTotalSupply();
        s.totalSuppliedWei = scaledAToken.rayMul(normIncome);
        s.totalBorrowedWei = scaledDebt.rayMul(normDebt);
        if (s.totalSuppliedWei > 0) {
            s.utilizationBps = s.totalBorrowedWei * BPS_DENOM / s.totalSuppliedWei;
        }
        s.supplyApyBpsLinear = uint256(d.currentLiquidityRate) * BPS_DENOM / RAY;
        s.borrowApyBpsLinear = uint256(d.currentVariableBorrowRate) * BPS_DENOM / RAY;
        try IERC20Metadata(asset).decimals() returns (uint8 dec) {
            s.decimals = dec;
        } catch {
            s.decimals = 18;
        }
        s.ok = true;
    }

    function _logReserveSnapshot(ReserveSnapshot memory s) internal view {
        _logSubRule("On-chain reserve snapshot (SUPPLY_TOKEN_ADDRESS)");
        console.log("aToken:", s.aToken);
        console.log("Variable debt token:", s.variableDebtToken);
        console.log("Underlying decimals:", s.decimals);
        console.log("Total supplied (raw):", s.totalSuppliedWei);
        console.log("Total variable debt (raw):", s.totalBorrowedWei);
        console.log("Utilization = debt / supplied (bps):", s.utilizationBps);
        console.log("Supply APR linearized from RAY (bps):", s.supplyApyBpsLinear);
        console.log("Variable borrow APR linearized from RAY (bps):", s.borrowApyBpsLinear);
        if (s.borrowApyBpsLinear >= s.supplyApyBpsLinear) {
            console.log("Spread borrow minus supply (bps):", s.borrowApyBpsLinear - s.supplyApyBpsLinear);
        } else {
            console.log(
                "Borrow APR below supply (unusual); shortfall (bps):", s.supplyApyBpsLinear - s.borrowApyBpsLinear
            );
        }
    }

    function _analyzeBorrowIncentiveBreakeven(ReserveSnapshot memory s) internal view {
        _logSubRule("Borrow-side rewards breakeven (uses chain APR)");
        console.log("Minimum annual reward on borrowed notional to offset borrow cost (bps):", s.borrowApyBpsLinear);
        if (s.totalSuppliedWei > 0 && s.totalBorrowedWei > 0) {
            uint256 poolShareBps = s.totalBorrowedWei * BPS_DENOM / s.totalSuppliedWei;
            console.log(
                "If rewards are sized on full supplied TVL instead of borrows, equivalent bps on TVL:",
                (s.borrowApyBpsLinear * poolShareBps) / BPS_DENOM
            );
            console.log("(Derived as borrow APR bps times utilization.)");
        }
    }

    function _feeScenarioBorrowBps(EconomicsParams memory p) internal pure returns (uint256) {
        if (p.feeBorrowOverrideBps > 0) return p.feeBorrowOverrideBps;
        return _borrowRateBps(p.feeScenarioUtilBps, p.borrowBaseBps, p.borrowTargetUtilBps, p.borrowSlopeBps);
    }

    function _supplierShareBps(EconomicsParams memory p) internal pure returns (uint256) {
        return BPS_DENOM - p.protocolFeeBps;
    }

    function _borrowRateBps(uint256 utilBps, uint256 baseRateBps, uint256 targetUtilBps, uint256 multiplierBps)
        internal
        pure
        returns (uint256)
    {
        uint256 r = baseRateBps;
        if (utilBps > targetUtilBps) {
            r += ((utilBps - targetUtilBps) * multiplierBps) / BPS_DENOM;
        }
        return r;
    }

    function _logBorrowEconomicsRow(
        uint256 util,
        uint256 tvl,
        uint256 borrowBps,
        uint256 protocolFeeBps,
        uint256 protocolToBuybackBps,
        uint256 annualSupplyEmissions,
        uint256 netPositiveExtraBps,
        uint256 rawPerMillion
    ) internal view {
        if (tvl == 0) return;
        uint256 borrowed = (tvl * util) / BPS_DENOM;
        uint256 totalInterest = (borrowed * borrowBps) / BPS_DENOM;
        uint256 protocolRevenue = (totalInterest * protocolFeeBps) / BPS_DENOM;
        uint256 buyback = (protocolRevenue * protocolToBuybackBps) / BPS_DENOM;
        uint256 buybackBpsOfTvl = (buyback * BPS_DENOM) / tvl;
        uint256 emissionsRatioBps = annualSupplyEmissions > 0 ? (buyback * BPS_DENOM) / annualSupplyEmissions : 0;

        console.log("");
        console.log("  Utilization (integer percent, e.g. 30 = 30%):", util / 100);
        console.log("  Model borrow APR (bps):", borrowBps);
        console.log("  Net borrower APR if reward = borrow + extra (bps):", borrowBps + netPositiveExtraBps);
        console.log("  Borrowed notional: millions of tokens (floor):", borrowed / rawPerMillion);
        console.log("  Borrowed notional: whole tokens (floor):", _wholeTokens(borrowed, rawPerMillion));
        console.log(
            "  Annual interest (same units): millions / whole:",
            totalInterest / rawPerMillion,
            _wholeTokens(totalInterest, rawPerMillion)
        );
        console.log(
            "  Protocol revenue: millions / whole:",
            protocolRevenue / rawPerMillion,
            _wholeTokens(protocolRevenue, rawPerMillion)
        );
        console.log(
            "  Buyback budget: millions / whole:", buyback / rawPerMillion, _wholeTokens(buyback, rawPerMillion)
        );
        console.log("  Buyback as bps of TVL:", buybackBpsOfTvl);
        console.log("  Buyback vs supply emissions budget (10000 = 100%):", emissionsRatioBps);
    }

    function _logBorrowBreakevenUtilRow(
        uint256 util,
        uint256 tvl,
        uint256 baseRate,
        uint256 multiplier,
        uint256 targetUtil,
        uint256 protocolFeeBps,
        uint256 protocolToBuybackBps,
        uint256 annualSupplyEmissions,
        uint256 netPositiveExtraBps,
        uint256 rawPerMillion
    ) internal view {
        uint256 borrowBps = _borrowRateBps(util, baseRate, targetUtil, multiplier);
        _logBorrowEconomicsRow(
            util,
            tvl,
            borrowBps,
            protocolFeeBps,
            protocolToBuybackBps,
            annualSupplyEmissions,
            netPositiveExtraBps,
            rawPerMillion
        );
    }

    function _analyzeSupplyBorrowSpreadMatrix(ReserveSnapshot memory snap) internal view {
        _logSubRule("Supply target vs implied borrow (spread toy model)");
        if (snap.ok) {
            console.log("From chain: supply APR (bps):", snap.supplyApyBpsLinear);
            console.log("From chain: borrow APR (bps):", snap.borrowApyBpsLinear);
            if (snap.borrowApyBpsLinear >= snap.supplyApyBpsLinear) {
                console.log(
                    "From chain: spread borrow minus supply (bps):", snap.borrowApyBpsLinear - snap.supplyApyBpsLinear
                );
            } else {
                console.log(
                    "From chain: supply exceeds borrow (bps diff):", snap.supplyApyBpsLinear - snap.borrowApyBpsLinear
                );
            }
        }
        console.log(
            "Synthetic grid: each row is a target supply APR (bps). For each spread, implied borrow APR = supply - spread (min 0)."
        );

        uint256[] memory supplierAPYs = new uint256[](4);
        supplierAPYs[0] = 800;
        supplierAPYs[1] = 1200;
        supplierAPYs[2] = 1500;
        supplierAPYs[3] = 2000;

        uint256[] memory spreads = new uint256[](4);
        spreads[0] = 200;
        spreads[1] = 300;
        spreads[2] = 400;
        spreads[3] = 500;

        for (uint256 i = 0; i < supplierAPYs.length; i++) {
            uint256 s = supplierAPYs[i];
            console.log("Target supply APR (bps):", s);
            for (uint256 j = 0; j < spreads.length; j++) {
                uint256 sp = spreads[j];
                uint256 b = s > sp ? s - sp : 0;
                console.log("  spread (bps):", sp, "  implied borrow APR (bps):", b);
            }
        }

        console.log(
            "Interpretation: high supplier APY from protocol fees alone needs high borrow rates or extra emissions."
        );
    }

    function _analyzeBorrowRewardBreakevenAndUtilBuybackChain(
        EconomicsParams memory p,
        ReserveSnapshot memory snap,
        uint256 rawPerMillion
    ) internal view {
        _logSubRule("Borrow economics vs utilization (synthetic borrow curve, then chain point)");
        console.log(
            "Assumes: interest = borrowed * borrow APR; protocol takes protocol_fee_bps; buyback takes buyback_of_protocol_bps of protocol slice."
        );
        console.log("Supply emissions budget = TVL * target_supply_apy_bps (annual, same token units).");
        console.log("Each block below is one utilization scenario; read indented lines for amounts.");
        console.log("");

        uint256 annualSupplyEmissions = (p.tvlWei * p.targetSupplyApyBps) / BPS_DENOM;

        console.log("Scenario TVL (raw):", p.tvlWei);
        console.log("Scenario TVL (whole tokens):", _wholeTokens(p.tvlWei, rawPerMillion));
        console.log(
            "Annual supply emissions budget: millions of tokens (floor):", annualSupplyEmissions / rawPerMillion
        );
        console.log(
            "Annual supply emissions budget: whole tokens (floor):", _wholeTokens(annualSupplyEmissions, rawPerMillion)
        );
        console.log("");

        uint256[] memory utils = new uint256[](5);
        utils[0] = 3000;
        utils[1] = 5000;
        utils[2] = 7500;
        utils[3] = 9000;
        utils[4] = 10000;

        for (uint256 i = 0; i < utils.length; i++) {
            _logBorrowBreakevenUtilRow(
                utils[i],
                p.tvlWei,
                p.borrowBaseBps,
                p.borrowSlopeBps,
                p.borrowTargetUtilBps,
                p.protocolFeeBps,
                p.buybackOfProtocolBps,
                annualSupplyEmissions,
                p.netPositiveExtraBps,
                rawPerMillion
            );
        }

        if (snap.ok && snap.totalSuppliedWei > 0) {
            console.log("");
            _logSubRule("Same fee model at on-chain utilization and borrow APR");
            _logBorrowEconomicsRow(
                snap.utilizationBps,
                snap.totalSuppliedWei,
                snap.borrowApyBpsLinear,
                p.protocolFeeBps,
                p.buybackOfProtocolBps,
                annualSupplyEmissions,
                p.netPositiveExtraBps,
                rawPerMillion
            );
        }

        console.log("");
        console.log("Note: emissions_ratio_bps compares annual buyback to supply emissions budget (10000 = 100%).");
    }

    function _analyzeFeeDistribution(EconomicsParams memory p, uint256 rawPerMillion) internal view {
        _logSubRule("Fee waterfall (single scenario: fee_scenario_util and borrow APR)");
        console.log(
            "Interest is split: suppliers get (1 - protocol_fee) of borrow interest; protocol keeps protocol_fee."
        );

        uint256 borrowBps = _feeScenarioBorrowBps(p);
        uint256 tvl = p.tvlWei;
        uint256 utilization = p.feeScenarioUtilBps;

        uint256 borrowed = (tvl * utilization) / BPS_DENOM;
        uint256 totalInterest = (borrowed * borrowBps) / BPS_DENOM;
        uint256 protocolRevenue = (totalInterest * p.protocolFeeBps) / BPS_DENOM;
        uint256 supplierRevenue = totalInterest - protocolRevenue;

        console.log("Utilization (bps of TVL):", utilization);
        console.log("Borrow APR used (bps):", borrowBps);
        console.log(
            "Borrowed principal: millions (floor) / whole tokens:",
            borrowed / rawPerMillion,
            _wholeTokens(borrowed, rawPerMillion)
        );
        console.log(
            "Total annual borrow interest: millions / whole:",
            totalInterest / rawPerMillion,
            _wholeTokens(totalInterest, rawPerMillion)
        );
        console.log(
            "Supplier share of interest: millions / whole:",
            supplierRevenue / rawPerMillion,
            _wholeTokens(supplierRevenue, rawPerMillion)
        );
        console.log(
            "Protocol share of interest: millions / whole:",
            protocolRevenue / rawPerMillion,
            _wholeTokens(protocolRevenue, rawPerMillion)
        );

        uint256 supplyAPYSupported = (supplierRevenue * BPS_DENOM) / tvl;
        console.log("Implied supply APY supported by fees only (bps on TVL):", supplyAPYSupported);

        if (supplyAPYSupported < p.targetSupplyApyBps) {
            uint256 gap = p.targetSupplyApyBps - supplyAPYSupported;
            uint256 neededFromTreasury = (tvl * gap) / BPS_DENOM;
            console.log("Shortfall vs target supply APY (bps):", gap);
            console.log(
                "Extra treasury funding per year: millions / whole tokens:",
                neededFromTreasury / rawPerMillion,
                _wholeTokens(neededFromTreasury, rawPerMillion)
            );
        }

        console.log("Of protocol fee revenue, buyback allocation (bps):", p.buybackOfProtocolBps);
        console.log("Remainder of protocol fee (e.g. staking) (bps):", BPS_DENOM - p.buybackOfProtocolBps);
    }

    function _analyzeUtilizationDynamics(EconomicsParams memory p) internal view {
        _logSubRule("Synthetic borrow curve: utilization vs rates");
        console.log("Supplier pass-through = borrow APR * (10000 - protocol_fee_bps) / 10000.");
        console.log("Columns per row: utilization (percent integer), borrow APR (bps), supplier-side APR (bps).");
        console.log("");

        uint256 supShare = _supplierShareBps(p);
        console.log("Supplier fraction of interest (bps of 10000):", supShare);
        console.log("");

        uint256[] memory utils = new uint256[](5);
        utils[0] = 3000;
        utils[1] = 5000;
        utils[2] = 7500;
        utils[3] = 9000;
        utils[4] = 10000;

        for (uint256 i = 0; i < utils.length; i++) {
            uint256 util = utils[i];
            uint256 borrowRate = _borrowRateBps(util, p.borrowBaseBps, p.borrowTargetUtilBps, p.borrowSlopeBps);
            uint256 supplyIncentive = (borrowRate * supShare) / BPS_DENOM;
            console.log("  Row utilization (pct):", util / 100);
            console.log("    Borrow APR (bps):", borrowRate);
            console.log("    Supplier APR from borrow pool (bps):", supplyIncentive);
        }
    }

    function _analyzeTokenPressure(EconomicsParams memory p, uint256 rawPerMillion) internal view {
        _logSubRule("Emissions vs buyback (rough token pressure)");
        console.log(
            "Supply rewards = TVL * target_supply_apy. Buyback = protocol_fee slice * buyback share. Compares first-order annual flows."
        );

        uint256 annualSupplyRewards = (p.tvlWei * p.targetSupplyApyBps) / BPS_DENOM;
        uint256 borrowBps = _feeScenarioBorrowBps(p);
        uint256 borrowed = (p.tvlWei * p.feeScenarioUtilBps) / BPS_DENOM;
        uint256 totalInterest = (borrowed * borrowBps) / BPS_DENOM;
        uint256 protocolRevenue = (totalInterest * p.protocolFeeBps) / BPS_DENOM;
        uint256 buyback = (protocolRevenue * p.buybackOfProtocolBps) / BPS_DENOM;
        uint256 stakingRewards = protocolRevenue - buyback;

        int256 netInflation = int256(annualSupplyRewards) - int256(buyback);

        console.log(
            "Annual supply-side rewards: millions / whole:",
            annualSupplyRewards / rawPerMillion,
            _wholeTokens(annualSupplyRewards, rawPerMillion)
        );
        console.log(
            "Annual staking slice from protocol fee: millions / whole:",
            stakingRewards / rawPerMillion,
            _wholeTokens(stakingRewards, rawPerMillion)
        );
        console.log(
            "Combined emissions (supply + staking slice): millions:",
            (annualSupplyRewards + stakingRewards) / rawPerMillion
        );
        console.log(
            "Annual buyback budget: millions / whole:", buyback / rawPerMillion, _wholeTokens(buyback, rawPerMillion)
        );

        if (netInflation > 0) {
            uint256 absInflation = uint256(netInflation);
            console.log(
                "Net flow: emissions minus buyback, millions / whole:",
                absInflation / rawPerMillion,
                _wholeTokens(absInflation, rawPerMillion)
            );
            console.log("Label: INFLATIONARY vs buyback (supply rewards exceed buyback in this toy model).");
            uint256 inflRate = (absInflation * 10000) / (p.tvlWei + absInflation);
            console.log("Rough intensity vs TVL (bps-style, not APY):", inflRate);
        } else {
            uint256 absDeflation = uint256(-netInflation);
            console.log(
                "Net flow: buyback minus emissions gap, millions / whole:",
                absDeflation / rawPerMillion,
                _wholeTokens(absDeflation, rawPerMillion)
            );
            console.log("Label: DEFLATIONARY vs emissions (buyback exceeds supply rewards in this toy model).");
        }
    }

    function _recommendedParameters(EconomicsParams memory p, ReserveSnapshot memory snap) internal view {
        _logSubRule("Summary: synthetic curve vs chain reference");
        console.log("Synthetic borrow curve: base (bps):", p.borrowBaseBps);
        console.log("Synthetic borrow curve: kink utilization (bps):", p.borrowTargetUtilBps);
        console.log("Synthetic borrow curve: slope above kink (bps per 100% util past kink):", p.borrowSlopeBps);
        console.log("Protocol fee (bps of borrow interest):", p.protocolFeeBps);
        console.log("Buyback (bps of protocol revenue):", p.buybackOfProtocolBps);
        console.log("Target supply APY / emissions (bps):", p.targetSupplyApyBps);
        uint256 atTarget =
            _borrowRateBps(p.borrowTargetUtilBps, p.borrowBaseBps, p.borrowTargetUtilBps, p.borrowSlopeBps);
        uint256 natSup = (atTarget * _supplierShareBps(p)) / BPS_DENOM;
        console.log("At kink utilization, synthetic borrow APR (bps):", atTarget);
        console.log("At kink, supplier APR implied from borrow only (bps):", natSup);
        if (snap.ok) {
            console.log("Chain: supply APR linear (bps):", snap.supplyApyBpsLinear);
            console.log("Chain: borrow APR linear (bps):", snap.borrowApyBpsLinear);
            console.log("Chain: utilization (bps):", snap.utilizationBps);
        }
    }
}

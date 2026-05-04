// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {K613VestingManager} from "../src/vesting/K613VestingManager.sol";
import {K613VestingWallet} from "../src/vesting/K613VestingWallet.sol";
import {DistributeK613} from "../script/deploy/DistributeK613.s.sol";

contract DistributeK613Test is Test {
    K613 private token;
    K613VestingManager private mgr;
    DistributeK613 private script;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    address private deployer;

    address private incentivesController = address(0xE1);
    address private lmReserve = address(0x102);
    address private polLp = address(0xC1);
    address private polReserve = address(0xC2);
    address private treasuryGov = address(0x715A);
    address private seedInvestor1 = address(0x5EE1);
    address private seedInvestor2 = address(0x5EE2);
    address private teamMember1 = address(0x7EA1);
    address private teamMember2 = address(0x7EA2);

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);

        vm.startPrank(deployer);
        token = new K613(deployer);
        mgr = new K613VestingManager(deployer, address(token));
        token.mint(deployer, token.MAX_SUPPLY());
        vm.stopPrank();

        script = new DistributeK613();
    }

    /// @dev Each test gets its own JSON file path so concurrent test runs don't race on shared FS state.
    function _testConfigPath(string memory tag) internal view returns (string memory) {
        return string.concat("test/_distribution.", vm.toString(address(this)), ".", tag, ".tmp.json");
    }

    /// @notice testRunWith_DistributesFullSupplyToAllBuckets: every transfer recipient and vesting beneficiary gets exact amount.
    function testRunWith_DistributesFullSupplyToAllBuckets() public {
        string memory path = _testConfigPath("distrib");
        _writeTestConfig(path);
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);

        assertEq(token.balanceOf(incentivesController), 40_000_000e18, "LM-IncentivesController");
        assertEq(token.balanceOf(lmReserve), 10_000_000e18, "LM-Reserve");
        assertEq(token.balanceOf(polLp), 5_000_000e18, "POL-LP (bootstrap)");
        assertEq(token.balanceOf(polReserve), 10_000_000e18, "POL-Reserve (future LP)");
        assertEq(token.balanceOf(treasuryGov), 10_000_000e18, "Treasury-Gov");
        assertEq(token.balanceOf(seedInvestor1), 5_000_000e18, "Seed-1");
        assertEq(token.balanceOf(seedInvestor2), 5_000_000e18, "Seed-2");

        address[] memory team1Wallets = mgr.getWalletsByBeneficiary(teamMember1);
        address[] memory team2Wallets = mgr.getWalletsByBeneficiary(teamMember2);
        assertEq(team1Wallets.length, 1, "Team-1 wallet count");
        assertEq(team2Wallets.length, 1, "Team-2 wallet count");
        assertEq(token.balanceOf(team1Wallets[0]), 7_500_000e18, "Team-1 wallet balance");
        assertEq(token.balanceOf(team2Wallets[0]), 7_500_000e18, "Team-2 wallet balance");
        assertEq(token.balanceOf(teamMember1), 0, "Team-1 direct balance");
        assertEq(token.balanceOf(teamMember2), 0, "Team-2 direct balance");
    }

    /// @notice testRunWith_DeployerBalanceZeroAfter: distributor must end with zero K613 balance.
    function testRunWith_DeployerBalanceZeroAfter() public {
        string memory path = _testConfigPath("zero");
        _writeTestConfig(path);
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);
        assertEq(token.balanceOf(deployer), 0);
    }

    /// @notice testRunWith_TotalEqualsMaxSupply: sum of all on-chain balances equals MAX_SUPPLY.
    function testRunWith_TotalEqualsMaxSupply() public {
        string memory path = _testConfigPath("total");
        _writeTestConfig(path);
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);

        uint256 sum;
        sum += token.balanceOf(incentivesController);
        sum += token.balanceOf(lmReserve);
        sum += token.balanceOf(polLp);
        sum += token.balanceOf(polReserve);
        sum += token.balanceOf(treasuryGov);
        sum += token.balanceOf(seedInvestor1);
        sum += token.balanceOf(seedInvestor2);
        sum += token.balanceOf(mgr.getWalletsByBeneficiary(teamMember1)[0]);
        sum += token.balanceOf(mgr.getWalletsByBeneficiary(teamMember2)[0]);
        assertEq(sum, token.MAX_SUPPLY());
        assertEq(sum, token.totalSupply());
    }

    /// @notice testRunWith_VestingScheduleParamsCorrect: cliff and duration land in VestingManager record exactly as configured.
    function testRunWith_VestingScheduleParamsCorrect() public {
        string memory path = _testConfigPath("vesting");
        _writeTestConfig(path);
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);

        address wallet = mgr.getWalletsByBeneficiary(teamMember1)[0];
        K613VestingManager.VestingRecord memory rec = mgr.getVestingRecord(wallet);
        assertEq(rec.beneficiary, teamMember1);
        assertEq(uint256(rec.cliffSeconds), 15_552_000, "6 months cliff");
        assertEq(uint256(rec.durationSeconds), 62_208_000, "24 months total duration (6mo cliff + 18mo linear)");
        assertEq(rec.initialAmount, 7_500_000e18);
    }

    /// @notice testRunWith_CallerBalanceNotEqualMaxSupplyReverts: balance < MAX_SUPPLY fails the strict invariant before any transfer.
    function testRunWith_CallerBalanceNotEqualMaxSupplyReverts() public {
        string memory path = _testConfigPath("balance");
        _writeTestConfig(path);
        // Burn 1 wei from the deployer's premint so balance becomes MAX_SUPPLY - 1.
        // burnFrom requires MINTER_ROLE (deployer has it) and an allowance.
        vm.startPrank(deployer);
        token.approve(deployer, 1);
        token.burnFrom(deployer, 1);
        vm.stopPrank();

        uint256 balance = token.balanceOf(deployer);
        uint256 maxSupply = token.MAX_SUPPLY();
        // sum still == MAX_SUPPLY so TotalMismatch passes; but balance ≠ MAX_SUPPLY → strict invariant fires.
        // The script also checks `callerBalance < grandTotal` first (InsufficientBalance) — since balance < MAX_SUPPLY = grandTotal,
        // that revert fires earlier. So we expect InsufficientBalance, not CallerBalanceMustEqualMaxSupply.
        vm.expectRevert(abi.encodeWithSelector(DistributeK613.InsufficientBalance.selector, balance, maxSupply));
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);
    }

    /// @notice testRunWith_InvalidVestingScheduleReverts: cliff > duration is rejected pre-broadcast.
    function testRunWith_InvalidVestingScheduleReverts() public {
        string memory path = _testConfigPath("invalidvest");
        // Build a config with valid total but cliff(100) > duration(50) on a single vesting entry.
        // Simplest: 1 transfer = 90M, 1 vesting = 10M with bad schedule.
        string memory bad = string.concat(
            '{"transferCount":1,"vestingCount":1,"transfers":[',
            _t("Treasury", treasuryGov, "90000000000000000000000000"),
            '],"vestings":[',
            _v("BadCliff", teamMember1, "10000000000000000000000000", "1762214400", "50", "100"),
            "]}"
        );
        vm.writeFile(path, bad);

        vm.expectRevert(
            abi.encodeWithSelector(DistributeK613.InvalidVestingSchedule.selector, "BadCliff", uint64(100), uint64(50))
        );
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);
    }

    /// @notice testRunWith_TotalMismatchReverts: if config sums to !=MAX_SUPPLY, script reverts before any tx.
    function testRunWith_TotalMismatchReverts() public {
        string memory path = _testConfigPath("bad");
        string memory bad = string.concat(
            '{"transferCount":1,"vestingCount":0,"transfers":[{"amount":"99999999999999999999999999","name":"X","to":"',
            vm.toString(treasuryGov),
            '"}],"vestings":[]}'
        );
        vm.writeFile(path, bad);

        vm.expectRevert(
            abi.encodeWithSelector(
                DistributeK613.TotalMismatch.selector, uint256(99_999_999_999_999_999_999_999_999), token.MAX_SUPPLY()
            )
        );
        script.runWith(address(token), address(mgr), path, DEPLOYER_PK);
    }

    function _writeTestConfig(string memory path) internal {
        string memory c = string.concat(
            '{"transferCount":7,"vestingCount":2,"transfers":[',
            _t("LM-IncentivesController", incentivesController, "40000000000000000000000000"),
            ",",
            _t("LM-Reserve", lmReserve, "10000000000000000000000000"),
            ",",
            _t("POL-LP", polLp, "5000000000000000000000000"),
            ",",
            _t("POL-Reserve", polReserve, "10000000000000000000000000"),
            ",",
            _t("Treasury-Gov", treasuryGov, "10000000000000000000000000"),
            ",",
            _t("Seed-1", seedInvestor1, "5000000000000000000000000"),
            ",",
            _t("Seed-2", seedInvestor2, "5000000000000000000000000"),
            '],"vestings":[',
            _v("Team-1", teamMember1, "7500000000000000000000000", "1762214400", "62208000", "15552000"),
            ",",
            _v("Team-2", teamMember2, "7500000000000000000000000", "1762214400", "62208000", "15552000"),
            "]}"
        );
        vm.writeFile(path, c);
    }

    function _t(string memory name, address to, string memory amount) internal view returns (string memory) {
        return string.concat('{"amount":"', amount, '","name":"', name, '","to":"', vm.toString(to), '"}');
    }

    function _v(
        string memory name,
        address ben,
        string memory amount,
        string memory startTs,
        string memory dur,
        string memory cliff
    ) internal view returns (string memory) {
        return string.concat(
            '{"amount":"',
            amount,
            '","beneficiary":"',
            vm.toString(ben),
            '","cliffSeconds":"',
            cliff,
            '","durationSeconds":"',
            dur,
            '","name":"',
            name,
            '","startTimestamp":"',
            startTs,
            '"}'
        );
    }
}

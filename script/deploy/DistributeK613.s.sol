// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {K613} from "src/token/K613.sol";
import {K613VestingManager} from "src/vesting/K613VestingManager.sol";

/// @title DistributeK613
/// @notice Reads a JSON distribution config and performs all TGE allocations: direct transfers + vesting wallet creation.
/// @dev Caller (PRIVATE_KEY) must hold the entire premint (i.e. is the governance Safe in real TGE; an EOA in test).
///      In production this is intended to be assembled into a Safe Transaction Builder batch; the on-chain tx-by-tx
///      flow here is for local simulation, dry-run, and reproducible testing.
contract DistributeK613 is Script {
    using stdJson for string;

    error TotalMismatch(uint256 sum, uint256 expected);
    error InsufficientBalance(uint256 balance, uint256 required);
    error CallerBalanceMustEqualMaxSupply(uint256 balance, uint256 maxSupply);
    error InvalidVestingSchedule(string name, uint64 cliffSeconds, uint64 durationSeconds);
    error WrongNetwork(uint256 chainId);

    uint256 private constant MONAD_MAINNET = 143;

    /// @notice K613 on Monad mainnet, deployed 2026-07-10 (see docs/OPERATIONS_SOP.md D.1).
    address private constant K613_MONAD = 0xb09582631336068d4B0089d943f40CbF46dE5189;

    function run() external {
        if (block.chainid != MONAD_MAINNET) revert WrongNetwork(block.chainid);
        runWith(
            K613_MONAD,
            vm.envAddress("VESTING_MANAGER_ADDRESS"),
            vm.envOr("DISTRIBUTION_CONFIG", string("script/deploy/distribution.json")),
            vm.envUint("PRIVATE_KEY")
        );
    }

    /// @notice Direct entrypoint without env vars. Used by tests to avoid env-race conditions; production uses `run()`.
    function runWith(address k613Addr, address vestingMgrAddr, string memory configPath, uint256 pk) public {
        address caller = vm.addr(pk);

        K613 token = K613(k613Addr);
        K613VestingManager mgr = K613VestingManager(vestingMgrAddr);

        string memory json = vm.readFile(configPath);
        uint256 transferCount = json.readUint(".transferCount");
        uint256 vestingCount = json.readUint(".vestingCount");

        (uint256 totalTransfers, uint256 totalVestings) = _previewTotals(json, transferCount, vestingCount);
        uint256 grandTotal = totalTransfers + totalVestings;

        if (grandTotal != token.MAX_SUPPLY()) {
            revert TotalMismatch(grandTotal, token.MAX_SUPPLY());
        }
        uint256 callerBalance = token.balanceOf(caller);
        if (callerBalance < grandTotal) {
            revert InsufficientBalance(callerBalance, grandTotal);
        }
        // Strong invariant: caller is the sole holder of the entire premint. Any pre-existing balance elsewhere
        // would mean a leak between premint and distribute and must be investigated before proceeding.
        if (callerBalance != token.MAX_SUPPLY()) {
            revert CallerBalanceMustEqualMaxSupply(callerBalance, token.MAX_SUPPLY());
        }
        _validateVestings(json, vestingCount);

        console.log("=== DistributeK613 ===");
        console.log("Caller (broadcaster):", caller);
        console.log("Transfers count:     ", transferCount);
        console.log("Vestings count:      ", vestingCount);
        console.log("Total transfers:     ", totalTransfers / 1e18, "K613");
        console.log("Total vestings:      ", totalVestings / 1e18, "K613");
        console.log("Grand total matches MAX_SUPPLY:", grandTotal == token.MAX_SUPPLY());

        vm.startBroadcast(pk);
        if (totalVestings > 0) {
            IERC20(k613Addr).approve(vestingMgrAddr, totalVestings);
        }
        for (uint256 i = 0; i < transferCount; i++) {
            string memory base = string.concat(".transfers[", vm.toString(i), "]");
            string memory name = json.readString(string.concat(base, ".name"));
            address to = json.readAddress(string.concat(base, ".to"));
            uint256 amount = vm.parseUint(json.readString(string.concat(base, ".amount")));
            IERC20(k613Addr).transfer(to, amount);
            console.log("transfer:", name, amount / 1e18);
        }
        for (uint256 i = 0; i < vestingCount; i++) {
            string memory base = string.concat(".vestings[", vm.toString(i), "]");
            string memory name = json.readString(string.concat(base, ".name"));
            address ben = json.readAddress(string.concat(base, ".beneficiary"));
            uint256 amount = vm.parseUint(json.readString(string.concat(base, ".amount")));
            uint64 startTs = uint64(vm.parseUint(json.readString(string.concat(base, ".startTimestamp"))));
            uint64 dur = uint64(vm.parseUint(json.readString(string.concat(base, ".durationSeconds"))));
            uint64 cliff = uint64(vm.parseUint(json.readString(string.concat(base, ".cliffSeconds"))));
            address wallet = mgr.createVestingWallet(ben, startTs, dur, cliff, amount);
            console.log("vesting :", name, amount / 1e18);
            console.log("  wallet:", wallet);
        }
        vm.stopBroadcast();

        console.log("=== Distribution complete ===");
        console.log("Caller balance after:", token.balanceOf(caller));
    }

    function _previewTotals(string memory json, uint256 transferCount, uint256 vestingCount)
        internal
        view
        returns (uint256 totalT, uint256 totalV)
    {
        for (uint256 i = 0; i < transferCount; i++) {
            string memory key = string.concat(".transfers[", vm.toString(i), "].amount");
            totalT += vm.parseUint(json.readString(key));
        }
        for (uint256 i = 0; i < vestingCount; i++) {
            string memory key = string.concat(".vestings[", vm.toString(i), "].amount");
            totalV += vm.parseUint(json.readString(key));
        }
    }

    function _validateVestings(string memory json, uint256 vestingCount) internal view {
        for (uint256 i = 0; i < vestingCount; i++) {
            string memory base = string.concat(".vestings[", vm.toString(i), "]");
            uint64 cliff = uint64(vm.parseUint(json.readString(string.concat(base, ".cliffSeconds"))));
            uint64 dur = uint64(vm.parseUint(json.readString(string.concat(base, ".durationSeconds"))));
            if (cliff > dur) {
                string memory name = json.readString(string.concat(base, ".name"));
                revert InvalidVestingSchedule(name, cliff, dur);
            }
        }
    }
}

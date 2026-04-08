// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {VestingWalletCliff} from "openzeppelin-contracts/contracts/finance/VestingWalletCliff.sol";
import {VestingWallet} from "openzeppelin-contracts/contracts/finance/VestingWallet.sol";

/// @title K613VestingWallet
/// @notice ERC20 vesting wallet with a cliff before any tokens become releasable.
/// @dev Thin wrapper over OpenZeppelin `VestingWalletCliff` / `VestingWallet`. The held token is whatever is sent to this contract; schedule is linear after the cliff over `durationSeconds`. Native ETH uses the inherited `receive()` and `release()` from `VestingWallet` (beneficiary withdraws vested ETH via `release()`).
// aderyn-fp-next-line(contract-locks-ether)
contract K613VestingWallet is VestingWalletCliff {
    /// @param beneficiary Address that receives vested tokens via `release`.
    /// @param startTimestamp Unix time when vesting window starts (cliff is measured from here).
    /// @param durationSeconds Linear vesting duration after the cliff ends.
    /// @param cliffSeconds Period after `startTimestamp` during which nothing is releasable.
    constructor(address beneficiary, uint64 startTimestamp, uint64 durationSeconds, uint64 cliffSeconds)
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
        VestingWalletCliff(cliffSeconds)
    {}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal interface for Staking to check exit queue without circular dependency.
interface IStaking {
    function exitQueueLength(address user) external view returns (uint256);
}

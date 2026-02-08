// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "../staking/RewardsDistributor.sol";

/// @title Treasury
/// @notice Manages K613 token flows: deposits rewards and executes buybacks via external DEX routers.
/// @dev Deposits mint xK613 to RewardsDistributor. Buyback swaps arbitrary tokens for K613 and optionally distributes to stakers.
contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a parameter.
    error ZeroAddress();
    /// @notice Thrown when amount is zero where a positive value is required.
    error ZeroAmount();
    /// @notice Thrown when no controller is set (reserved for future use).
    error NoController();
    /// @notice Thrown when no assets are available (reserved for future use).
    error NoAssets();
    /// @notice Thrown when the DEX swap call fails.
    error BuybackFailed();
    /// @notice Thrown when the swap output is less than minK613Out.
    error InsufficientOutput();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    xK613 public immutable xk613;
    RewardsDistributor public immutable rewardsDistributor;

    /// @notice Emitted when admin withdraws tokens.
    /// @param token Token withdrawn.
    /// @param to Recipient.
    /// @param amount Amount withdrawn.
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a buyback is executed.
    /// @param tokenIn Token swapped in for K613.
    /// @param router DEX router used for the swap.
    /// @param amountIn Amount of tokenIn swapped.
    /// @param k613Out Amount of K613 received.
    /// @param distributed Whether rewards were distributed to stakers.
    event BuybackExecuted(
        address indexed tokenIn, address indexed router, uint256 amountIn, uint256 k613Out, bool distributed
    );

    /// @notice Deploys the Treasury with K613, xK613, and RewardsDistributor addresses.
    /// @param k613Token Address of the K613 token.
    /// @param xk613Token Address of the xK613 token.
    /// @param rewardsDistributor_ Address of the RewardsDistributor contract.
    constructor(address k613Token, address xk613Token, address rewardsDistributor_) {
        if (k613Token == address(0) || xk613Token == address(0) || rewardsDistributor_ == address(0)) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = xK613(xk613Token);
        rewardsDistributor = RewardsDistributor(rewardsDistributor_);
    }

    /// @notice Deposits K613 rewards: transfers tokens from caller, mints xK613 to RewardsDistributor, and notifies rewards.
    /// @param amount Amount of K613 to deposit. If zero, the call is a no-op.
    function depositRewards(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) {
            return;
        }
        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(address(rewardsDistributor), amount);
        rewardsDistributor.notifyReward(amount);
    }

    /// @notice Executes a buyback: swaps tokenIn for K613 via the router and optionally distributes to stakers.
    /// @param tokenIn Token to swap for K613.
    /// @param router DEX router address (e.g. Uniswap, 1inch).
    /// @param amountIn Amount of tokenIn to swap.
    /// @param data Calldata for the router's swap function.
    /// @param minK613Out Minimum K613 expected; reverts if output is lower.
    /// @param distributeRewards If true, mints xK613 to RewardsDistributor and notifies reward.
    /// @return k613Out Amount of K613 received from the swap.
    function buyback(
        address tokenIn,
        address router,
        uint256 amountIn,
        bytes calldata data,
        uint256 minK613Out,
        bool distributeRewards
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused returns (uint256 k613Out) {
        if (tokenIn == address(0) || router == address(0)) {
            revert ZeroAddress();
        }
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        uint256 k613Before = k613.balanceOf(address(this));
        IERC20(tokenIn).forceApprove(router, amountIn);
        (bool success,) = router.call(data);
        if (!success) {
            revert BuybackFailed();
        }
        IERC20(tokenIn).forceApprove(router, 0);
        k613Out = k613.balanceOf(address(this)) - k613Before;
        if (k613Out < minK613Out) {
            revert InsufficientOutput();
        }
        if (distributeRewards && k613Out > 0) {
            xk613.mint(address(rewardsDistributor), k613Out);
            rewardsDistributor.notifyReward(k613Out);
        }
        emit BuybackExecuted(tokenIn, router, amountIn, k613Out, distributeRewards);
    }

    /// @notice Withdraws any ERC20 token from the Treasury. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param token Token to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function withdraw(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0) || to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Pauses deposit and buyback operations. Only callable by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes operations. Only callable by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

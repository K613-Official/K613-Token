// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {RewardsDistributor} from "../staking/RewardsDistributor.sol";
import {Staking} from "../staking/Staking.sol";

/// @title Treasury
/// @notice Manages K613 token flows: stakes K613 to get xK613 for rewards, executes buybacks. Rewards are distributed in xK613.
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
    /// @notice Thrown when buyback is called with a router not in the whitelist.
    error RouterNotWhitelisted();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    IERC20 public immutable xk613;
    Staking public immutable staking;
    RewardsDistributor public immutable rewardsDistributor;

    /// @notice Whitelist of DEX routers allowed for buyback. Only DEFAULT_ADMIN_ROLE can update.
    mapping(address => bool) public routerWhitelist;
    /// @notice List of whitelisted router addresses for enumeration (see getWhitelistedRouters).
    address[] private _whitelistedRouters;

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
    /// @notice Emitted when a router is added to or removed from the whitelist.
    event RouterWhitelistUpdated(address indexed router, bool allowed);

    /// @notice Deploys the Treasury with K613, xK613, Staking, and RewardsDistributor.
    constructor(address k613Token, address xk613Token, address staking_, address rewardsDistributor_) {
        if (
            k613Token == address(0) || xk613Token == address(0) || staking_ == address(0)
                || rewardsDistributor_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        k613 = IERC20(k613Token);
        xk613 = IERC20(xk613Token);
        staking = Staking(staking_);
        rewardsDistributor = RewardsDistributor(rewardsDistributor_);
    }

    /// @notice Deposits rewards: stakes K613 to get xK613, sends xK613 to RewardsDistributor and notifies. Caller must have approved Treasury for K613.
    /// @param amount Amount of K613 to stake and deposit as xK613 rewards. If zero, no-op.
    function depositRewards(uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (amount == 0) return;
        k613.safeTransferFrom(msg.sender, address(this), amount);
        k613.forceApprove(address(staking), amount);
        staking.stake(amount);
        k613.forceApprove(address(staking), 0);
        xk613.safeTransfer(address(rewardsDistributor), amount);
        rewardsDistributor.notifyReward(amount);
    }

    /// @notice Adds or removes a router from the buyback whitelist. Only DEFAULT_ADMIN_ROLE.
    /// @param router Router address to whitelist or remove.
    /// @param allowed True to allow buyback via this router, false to disallow.
    function setRouterWhitelist(address router, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert ZeroAddress();
        bool wasAllowed = routerWhitelist[router];
        routerWhitelist[router] = allowed;
        if (allowed && !wasAllowed) {
            _whitelistedRouters.push(router);
        } else if (!allowed && wasAllowed) {
            _removeRouterFromList(router);
        }
        emit RouterWhitelistUpdated(router, allowed);
    }

    /// @notice Returns the list of all whitelisted router addresses.
    function getWhitelistedRouters() external view returns (address[] memory) {
        return _whitelistedRouters;
    }

    /// @dev Removes a router from _whitelistedRouters by swapping with the last element and popping.
    function _removeRouterFromList(address router) private {
        uint256 len = _whitelistedRouters.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_whitelistedRouters[i] == router) {
                address lastRouter = _whitelistedRouters[len - 1];
                _whitelistedRouters[i] = lastRouter;
                _whitelistedRouters.pop();
                return;
            }
        }
    }

    /// @notice Executes a buyback: swaps tokenIn for K613 via a whitelisted router and optionally distributes to stakers.
    /// @dev Router must be in routerWhitelist; it receives arbitrary calldata and must be trusted.
    /// @param tokenIn Token to swap for K613.
    /// @param router DEX router address (must be whitelisted).
    /// @param amountIn Amount of tokenIn to swap.
    /// @param data Calldata for the router's swap function.
    /// @param minK613Out Minimum K613 expected; reverts if output is lower.
    /// @param distributeRewards If true, transfers K613 to RewardsDistributor and notifies reward.
    /// @return k613Out Amount of K613 received from the swap.
    function buyback(
        address tokenIn,
        address router,
        uint256 amountIn,
        bytes calldata data,
        uint256 minK613Out,
        bool distributeRewards
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused returns (uint256 k613Out) {
        if (tokenIn == address(0) || router == address(0)) {
            revert ZeroAddress();
        }
        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (!routerWhitelist[router]) revert RouterNotWhitelisted();
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
            k613.forceApprove(address(staking), k613Out);
            staking.stake(k613Out);
            k613.forceApprove(address(staking), 0);
            xk613.safeTransfer(address(rewardsDistributor), k613Out);
            rewardsDistributor.notifyReward(k613Out);
        }
        emit BuybackExecuted(tokenIn, router, amountIn, k613Out, distributeRewards);
    }

    /// @notice Withdraws any ERC20 token from the Treasury. Only callable by DEFAULT_ADMIN_ROLE.
    /// @param token Token to withdraw.
    /// @param to Recipient address.
    /// @param amount Amount to withdraw.
    function withdraw(address token, address to, uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
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

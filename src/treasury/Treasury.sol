// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "../staking/RewardsDistributor.sol";

contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error NoController();
    error NoAssets();
    error BuybackFailed();
    error InsufficientOutput();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    xK613 public immutable xk613;
    RewardsDistributor public immutable rewardsDistributor;

    event BuybackExecuted(
        address indexed tokenIn, address indexed router, uint256 amountIn, uint256 k613Out, bool distributed
    );

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

    function depositRewards(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) {
            return;
        }
        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(address(rewardsDistributor), amount);
        rewardsDistributor.notifyReward(amount);
    }

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

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

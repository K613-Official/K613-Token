// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRewardsController} from "L2-Protocol/src/contracts/rewards/interfaces/IRewardsController.sol";
import {xK613} from "../token/xK613.sol";
import {RewardsDistributor} from "../staking/RewardsDistributor.sol";

contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NoController();
    error NoAssets();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public immutable k613;
    xK613 public immutable xk613;
    RewardsDistributor public immutable rewardsDistributor;

    IRewardsController public rewardsController;
    address[] public rewardAssets;

    event RewardsControllerUpdated(address indexed controller);
    event RewardAssetsUpdated(address[] assets);
    event AaveRewardsClaimed(address[] rewardsList, uint256[] amounts);

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

    function setRewardsController(address controller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (controller == address(0)) {
            revert ZeroAddress();
        }
        rewardsController = IRewardsController(controller);
        emit RewardsControllerUpdated(controller);
    }

    function setRewardAssets(address[] calldata assets) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete rewardAssets;
        for (uint256 i = 0; i < assets.length; i++) {
            rewardAssets.push(assets[i]);
        }
        emit RewardAssetsUpdated(assets);
    }

    function claimAaveRewards()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
    {
        if (address(rewardsController) == address(0)) {
            revert NoController();
        }
        if (rewardAssets.length == 0) {
            revert NoAssets();
        }
        (rewardsList, claimedAmounts) = rewardsController.claimAllRewards(rewardAssets, address(this));
        emit AaveRewardsClaimed(rewardsList, claimedAmounts);
    }

    function depositRewards(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) {
            return;
        }
        k613.safeTransferFrom(msg.sender, address(this), amount);
        xk613.mint(address(rewardsDistributor), amount);
        rewardsDistributor.notifyReward(amount);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IRewardsController} from "L2-Lending-Protocol/src/contracts/rewards/interfaces/IRewardsController.sol";

contract RewardsPool is Ownable {
    IERC20 public immutable xk613;
    address public governanceTreasury;
    address public stakingLock;

    IRewardsController public rewardsController;
    address[] public rewardAssets;

    uint256 public stakerShareBps;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;

    uint256 public rewardPerTokenStored;
    uint256 public pendingRewards;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount);
    event RevenueDeposited(address indexed from, uint256 amount, uint256 toStakers, uint256 toGovernance);
    event PenaltyNotified(uint256 amount);
    event GovernanceTreasuryUpdated(address indexed treasury);
    event StakingLockUpdated(address indexed stakingLock);
    event StakerShareUpdated(uint256 stakerShareBps);
    event RewardsControllerUpdated(address indexed controller);
    event RewardAssetsUpdated(address[] assets);
    event AaveRewardsClaimed(address[] rewardsList, uint256[] amounts);

    modifier onlyStakingLock() {
        require(msg.sender == stakingLock, "ONLY_STAKING_LOCK");
        _;
    }

    modifier updateReward(address account) {
        _distributePending();
        if (account != address(0)) {
            rewards[account] = _earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(address xk613Token, address treasury, uint256 stakerShareBps_) Ownable(msg.sender) {
        require(xk613Token != address(0), "ZERO_ADDRESS");
        require(treasury != address(0), "ZERO_ADDRESS");
        require(stakerShareBps_ <= 10_000, "BPS");
        xk613 = IERC20(xk613Token);
        governanceTreasury = treasury;
        stakerShareBps = stakerShareBps_;
    }

    function setGovernanceTreasury(address treasury) external onlyOwner {
        require(treasury != address(0), "ZERO_ADDRESS");
        governanceTreasury = treasury;
        emit GovernanceTreasuryUpdated(treasury);
    }

    function setStakingLock(address stakingLock_) external onlyOwner {
        require(stakingLock_ != address(0), "ZERO_ADDRESS");
        stakingLock = stakingLock_;
        emit StakingLockUpdated(stakingLock_);
    }

    function setStakerShareBps(uint256 stakerShareBps_) external onlyOwner {
        require(stakerShareBps_ <= 10_000, "BPS");
        stakerShareBps = stakerShareBps_;
        emit StakerShareUpdated(stakerShareBps_);
    }

    function setRewardsController(address controller) external onlyOwner {
        rewardsController = IRewardsController(controller);
        emit RewardsControllerUpdated(controller);
    }

    function setRewardAssets(address[] calldata assets) external onlyOwner {
        delete rewardAssets;
        for (uint256 i = 0; i < assets.length; i++) {
            rewardAssets.push(assets[i]);
        }
        emit RewardAssetsUpdated(assets);
    }

    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "ZERO_AMOUNT");
        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        require(xk613.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAIL");
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "ZERO_AMOUNT");
        uint256 balance = balanceOf[msg.sender];
        require(balance >= amount, "BALANCE");
        balanceOf[msg.sender] = balance - amount;
        totalStaked -= amount;
        require(xk613.transfer(msg.sender, amount), "TRANSFER_FAIL");
        emit Withdrawn(msg.sender, amount);
    }

    function claim() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "NO_REWARD");
        rewards[msg.sender] = 0;
        require(xk613.transfer(msg.sender, reward), "TRANSFER_FAIL");
        emit RewardPaid(msg.sender, reward);
    }

    function depositRevenue(uint256 amount) external updateReward(address(0)) {
        require(amount > 0, "ZERO_AMOUNT");
        require(xk613.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAIL");
        uint256 toStakers = (amount * stakerShareBps) / 10_000;
        uint256 toGovernance = amount - toStakers;
        if (toGovernance > 0) {
            require(xk613.transfer(governanceTreasury, toGovernance), "TRANSFER_FAIL");
        }
        _notifyRewardAmount(toStakers);
        emit RevenueDeposited(msg.sender, amount, toStakers, toGovernance);
    }

    function notifyPenalty(uint256 amount) external onlyStakingLock updateReward(address(0)) {
        require(amount > 0, "ZERO_AMOUNT");
        _notifyRewardAmount(amount);
        emit PenaltyNotified(amount);
    }

    function claimAaveRewards() external returns (address[] memory rewardsList, uint256[] memory claimedAmounts) {
        require(address(rewardsController) != address(0), "NO_CONTROLLER");
        require(rewardAssets.length > 0, "NO_ASSETS");
        (rewardsList, claimedAmounts) = rewardsController.claimAllRewards(rewardAssets, address(this));
        emit AaveRewardsClaimed(rewardsList, claimedAmounts);
    }

    function earned(address account) external view returns (uint256) {
        return _earned(account);
    }

    function rewardAssetsLength() external view returns (uint256) {
        return rewardAssets.length;
    }

    function _earned(address account) internal view returns (uint256) {
        uint256 paid = userRewardPerTokenPaid[account];
        uint256 perToken = rewardPerTokenStored;
        uint256 pending = rewards[account];
        uint256 balance = balanceOf[account];
        uint256 accrued = (balance * (perToken - paid)) / 1e18;
        return pending + accrued;
    }

    function _notifyRewardAmount(uint256 amount) internal {
        if (amount == 0) return;
        if (totalStaked == 0) {
            pendingRewards += amount;
            return;
        }
        uint256 totalToDistribute = amount + pendingRewards;
        pendingRewards = 0;
        rewardPerTokenStored += (totalToDistribute * 1e18) / totalStaked;
        emit RewardNotified(totalToDistribute);
    }

    function _distributePending() internal {
        if (pendingRewards == 0 || totalStaked == 0) return;
        uint256 totalToDistribute = pendingRewards;
        pendingRewards = 0;
        rewardPerTokenStored += (totalToDistribute * 1e18) / totalStaked;
        emit RewardNotified(totalToDistribute);
    }
}

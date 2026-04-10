// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";

import {K613} from "../src/token/K613.sol";
import {xK613} from "../src/token/xK613.sol";
import {Staking} from "../src/staking/Staking.sol";
import {RewardsDistributor} from "../src/staking/RewardsDistributor.sol";
import {Treasury} from "../src/treasury/Treasury.sol";

contract FuzzMockToken is ERC20 {
    constructor() ERC20("FuzzMock", "FM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FuzzMockV3Router {
    K613 public k613;
    IERC20 public tokenInErc;
    uint256 public outAmount;
    bool public shouldFail;

    constructor(address _k613, address _tokenIn) {
        k613 = K613(_k613);
        tokenInErc = IERC20(_tokenIn);
        outAmount = 1e18;
    }

    function setOutAmount(uint256 v) external {
        outAmount = v;
    }

    function setShouldFail(bool v) external {
        shouldFail = v;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        if (shouldFail) revert("swap failed");
        tokenInErc.transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = outAmount;
        k613.transfer(p.recipient, amountOut);
    }
}

contract TreasuryFuzzTest is Test {
    uint256 private constant ONE = 1e18;
    uint24 private constant POOL_FEE = 3000;
    uint256 private constant EPOCH = 7 days;

    K613 private k613;
    xK613 private xk613;
    Staking private staking;
    RewardsDistributor private distributor;
    Treasury private treasury;
    FuzzMockToken private tokenIn;
    FuzzMockV3Router private router;

    function setUp() public {
        k613 = new K613(address(this));
        xk613 = new xK613(address(this));
        staking = new Staking(address(k613), address(xk613), 7 days, 0);
        distributor = new RewardsDistributor(address(xk613), address(xk613), address(k613), EPOCH);
        treasury = new Treasury(address(k613), address(xk613), address(staking), address(distributor));

        xk613.setMinter(address(staking));
        xk613.grantRole(xk613.MINTER_ROLE(), address(this));
        xk613.setTransferWhitelist(address(distributor), true);
        xk613.setTransferWhitelist(address(treasury), true);
        staking.setRewardsDistributor(address(distributor));
        distributor.setStaking(address(staking));
        distributor.grantRole(distributor.REWARDS_NOTIFIER_ROLE(), address(treasury));

        tokenIn = new FuzzMockToken();
        router = new FuzzMockV3Router(address(k613), address(tokenIn));
        treasury.setRouterWhitelist(address(router), true);
    }

    /// @notice testFuzzBuybackAllowanceAlwaysReset: after buyback, tokenIn allowance to router is always zero.
    function testFuzzBuybackAllowanceAlwaysReset(uint256 rawAmountIn, uint256 rawOutAmount) public {
        uint256 amountIn = bound(rawAmountIn, 1, 1_000_000 * ONE);
        uint256 outAmount = bound(rawOutAmount, 1, 1_000_000 * ONE);

        tokenIn.mint(address(treasury), amountIn);
        k613.mint(address(router), outAmount);
        router.setOutAmount(outAmount);

        treasury.buybackV3ExactInputSingle(address(tokenIn), address(router), amountIn, 1, POOL_FEE, false);

        assertEq(tokenIn.allowance(address(treasury), address(router)), 0);
    }

    /// @notice testFuzzBuybackWhitelistGate: buyback reverts for routers that are not whitelisted.
    function testFuzzBuybackWhitelistGate(address randomRouter, uint256 amountIn) public {
        vm.assume(randomRouter != address(0));
        vm.assume(randomRouter != address(router));

        uint256 boundedAmount = bound(amountIn, 1, 1000 * ONE);
        tokenIn.mint(address(treasury), boundedAmount);

        vm.expectRevert(Treasury.RouterNotWhitelisted.selector);
        treasury.buybackV3ExactInputSingle(address(tokenIn), randomRouter, boundedAmount, 1, POOL_FEE, false);
    }
}

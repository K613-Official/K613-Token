// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {K613} from "../src/token/K613.sol";
import {PremintK613} from "../script/deploy/PremintK613.s.sol";
import {ERC20Capped} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Capped.sol";

contract PremintK613Test is Test {
    K613 private token;
    PremintK613 private script;

    uint256 private constant DEPLOYER_PK = 0xA11CE;
    address private deployer;
    address private governance = address(0x6066E12);

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        vm.startPrank(deployer);
        token = new K613(deployer);
        vm.stopPrank();
        script = new PremintK613();
    }

    /// @notice testRunWith_MintsMaxSupplyToGovernance: full premint lands MAX_SUPPLY at governance, totalSupply == cap.
    function testRunWith_MintsMaxSupplyToGovernance() public {
        script.runWith(address(token), governance, DEPLOYER_PK);
        assertEq(token.balanceOf(governance), token.MAX_SUPPLY());
        assertEq(token.totalSupply(), token.cap());
    }

    /// @notice testRunWith_FurtherMintRevertsByCap: after premint, any mint reverts with ERC20ExceededCap.
    function testRunWith_FurtherMintRevertsByCap() public {
        script.runWith(address(token), governance, DEPLOYER_PK);
        uint256 cap = token.MAX_SUPPLY();
        vm.startPrank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, cap + 1, cap));
        token.mint(governance, 1);
        vm.stopPrank();
    }

    /// @notice testRunWith_AlreadyMintedReverts: second invocation fails with AlreadyMinted, not a generic cap error.
    function testRunWith_AlreadyMintedReverts() public {
        script.runWith(address(token), governance, DEPLOYER_PK);
        vm.expectRevert(abi.encodeWithSelector(PremintK613.AlreadyMinted.selector, token.MAX_SUPPLY()));
        script.runWith(address(token), governance, DEPLOYER_PK);
    }

    /// @notice testRunWith_CallerLacksMinterRoleReverts: if pk doesn't hold MINTER_ROLE, script reverts pre-broadcast.
    function testRunWith_CallerLacksMinterRoleReverts() public {
        uint256 randomPk = 0xDEADBEEF;
        vm.expectRevert(abi.encodeWithSelector(PremintK613.CallerLacksMinterRole.selector, vm.addr(randomPk)));
        script.runWith(address(token), governance, randomPk);
    }

    /// @notice testRun_RevertsOnWrongChain: env-based run() entrypoint refuses to broadcast on non-Monad chains.
    /// @dev Default Foundry chainid is 31337 (Anvil). Monad mainnet is 143.
    function testRun_RevertsOnWrongChain() public {
        vm.setEnv("K613_ADDRESS", vm.toString(address(token)));
        vm.setEnv("GOVERNANCE_ADDRESS", vm.toString(governance));
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.expectRevert(abi.encodeWithSelector(PremintK613.WrongNetwork.selector, block.chainid));
        script.run();
    }
}

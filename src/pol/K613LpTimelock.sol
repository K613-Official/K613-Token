// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC721Receiver} from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

/// @title K613LpTimelock
/// @notice Time-locks the protocol-owned Uniswap V3 LP NFT (K613/USDC). While the NFT is held here
///         liquidity CANNOT be withdrawn (the contract exposes no decreaseLiquidity path), which is
///         the on-chain rug-pull guarantee promised by the tokenomics. The beneficiary (governance
///         Safe) can still collect accrued trading fees at any time, and can withdraw the NFT itself
///         only after `unlockTime`.
/// @dev Transfer the LP NFT here via `NPM.safeTransferFrom(owner, timelock, tokenId)` after minting.
///      Holds any number of positions; each is withdrawable only after the shared `unlockTime`.
contract K613LpTimelock is IERC721Receiver {
    /// @notice Thrown when the caller is not the beneficiary.
    error NotBeneficiary();
    /// @notice Thrown when withdrawing before the unlock time.
    error StillLocked(uint256 unlockTime);
    /// @notice Thrown when a zero address is passed as a constructor parameter.
    error ZeroAddress();
    /// @notice Thrown when a zero duration is passed as a constructor parameter.
    error ZeroDuration();

    /// @notice Uniswap V3 NonfungiblePositionManager whose NFTs this vault holds.
    address public immutable npm;
    /// @notice Address allowed to collect fees and, after unlock, withdraw positions (governance Safe).
    address public immutable beneficiary;
    /// @notice Timestamp after which positions can be withdrawn.
    uint256 public immutable unlockTime;

    /// @notice Emitted when trading fees are collected to the beneficiary.
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    /// @notice Emitted when a position NFT is withdrawn after unlock.
    event PositionWithdrawn(uint256 indexed tokenId, address indexed to);

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    /// @param npm_ NonfungiblePositionManager address.
    /// @param beneficiary_ Governance Safe that collects fees and withdraws after unlock.
    /// @param lockDuration Lock length in seconds from deployment (e.g. 365 days).
    constructor(address npm_, address beneficiary_, uint256 lockDuration) {
        if (npm_ == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        if (lockDuration == 0) revert ZeroDuration();
        npm = npm_;
        beneficiary = beneficiary_;
        unlockTime = block.timestamp + lockDuration;
    }

    /// @notice Collects accrued trading fees of a locked position straight to the beneficiary.
    ///         Does not touch principal liquidity; callable at any time.
    function collectFees(uint256 tokenId) external onlyBeneficiary returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = INonfungiblePositionManager(npm)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: beneficiary,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        emit FeesCollected(tokenId, amount0, amount1);
    }

    /// @notice Withdraws a position NFT to the beneficiary. Only after `unlockTime`.
    function withdraw(uint256 tokenId) external onlyBeneficiary {
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);
        IERC721(npm).safeTransferFrom(address(this), beneficiary, tokenId);
        emit PositionWithdrawn(tokenId, beneficiary);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        // Accept only LP NFTs from the configured position manager.
        if (msg.sender != npm) revert NotBeneficiary();
        return IERC721Receiver.onERC721Received.selector;
    }
}

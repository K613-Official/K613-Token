// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import {K613S1} from "../token/K613S1.sol";

/// @title K613SeasonClaim
/// @notice Post-TGE Merkle-based claim contract for K613 Points Campaign Season 1. Holders convert their K613S1 allocation to K613 1:1 across a step-vesting schedule (20% TGE + 4 × 20% every 15 days). Each claim burns K613S1 from the caller equal to the K613 paid out.
/// @dev Funded once by governance via direct K613 transfer to this contract before TGE. Unclaimed K613 is recoverable by `DEFAULT_ADMIN_ROLE` after `claimDeadline` (TGE + 365 days). The Merkle root is immutable; redeploy is required to fix a bad root.
contract K613SeasonClaim is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a zero address is passed as a constructor argument or recovery target.
    error ZeroAddress();
    /// @notice Thrown if the constructor is given a zero Merkle root.
    error EmptyMerkleRoot();
    /// @notice Thrown when a Merkle proof does not validate against `merkleRoot`.
    error InvalidProof();
    /// @notice Thrown when the caller has already claimed at least the currently vested portion.
    error NothingToClaim();
    /// @notice Thrown when `claim` is called after `claimDeadline`.
    error ClaimWindowClosed();
    /// @notice Thrown when `recoverUnclaimedK613` is called before `claimDeadline`.
    error ClaimsStillOpen();

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Length of the claim window after TGE. After this, claims revert and governance can recover unclaimed K613.
    uint256 public constant CLAIM_WINDOW = 365 days;
    /// @notice Basis-points denominator used for the vesting schedule (10_000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice K613 token paid out to claimers on the vesting schedule.
    IERC20 public immutable k613;
    /// @notice K613S1 token burned 1:1 with K613 paid out.
    K613S1 public immutable k613s1;
    /// @notice Final Merkle root over `keccak256(bytes.concat(keccak256(abi.encode(account, totalAllocation))))` leaves.
    bytes32 public immutable merkleRoot;
    /// @notice TGE timestamp. Vesting curve is anchored here.
    uint256 public immutable tgeTimestamp;
    /// @notice Timestamp after which claims revert and governance can recover. Equals `tgeTimestamp + CLAIM_WINDOW`.
    uint256 public immutable claimDeadline;

    /// @notice Cumulative K613 paid to each user. Equals cumulative K613S1 burned from them.
    mapping(address => uint256) public claimed;

    /// @notice Emitted on each successful claim.
    event Claimed(address indexed account, uint256 payout, uint256 cumulativeVested);
    /// @notice Emitted when admin recovers unclaimed K613 after the claim window closes.
    event UnclaimedK613Recovered(address indexed to, uint256 amount);

    /// @param _k613 Address of the K613 token (transferred out on claim).
    /// @param _k613s1 Address of the K613S1 token (burned 1:1 on claim). This contract must be granted `K613S1.BURNER_ROLE` post-deployment.
    /// @param _merkleRoot Final Season 1 K613-allocation Merkle root.
    /// @param _tgeTimestamp Anchor of the vesting curve.
    /// @param _admin Address granted `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` (typically the governance Safe).
    constructor(address _k613, address _k613s1, bytes32 _merkleRoot, uint256 _tgeTimestamp, address _admin) {
        if (_k613 == address(0) || _k613s1 == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        if (_merkleRoot == bytes32(0)) {
            revert EmptyMerkleRoot();
        }
        k613 = IERC20(_k613);
        k613s1 = K613S1(_k613s1);
        merkleRoot = _merkleRoot;
        tgeTimestamp = _tgeTimestamp;
        claimDeadline = _tgeTimestamp + CLAIM_WINDOW;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    /// @notice Returns the vested fraction of an allocation at timestamp `ts`, in basis points (`BPS_DENOMINATOR` = 100%). Step schedule: 0% pre-TGE, 20% at TGE, +20% every 15 days, 100% at TGE+60 days.
    function vestedFraction(uint256 ts) public view returns (uint256 bps) {
        if (ts < tgeTimestamp) {
            return 0;
        }
        uint256 elapsed = ts - tgeTimestamp;
        if (elapsed >= 60 days) {
            return BPS_DENOMINATOR;
        }
        if (elapsed >= 45 days) {
            return 8_000;
        }
        if (elapsed >= 30 days) {
            return 6_000;
        }
        if (elapsed >= 15 days) {
            return 4_000;
        }
        return 2_000;
    }

    /// @notice Claims the vested portion of caller's allocation. Burns K613S1 1:1 and transfers K613.
    /// @dev Reverts with `ERC20InsufficientBalance` if the caller has not yet claimed enough K613S1 from `K613S1Distributor` to cover the payout.
    /// @param totalAllocation Total K613 the caller is authorised to receive across the full vesting period.
    /// @param proof Merkle proof for `keccak256(bytes.concat(keccak256(abi.encode(msg.sender, totalAllocation))))` against `merkleRoot`.
    function claim(uint256 totalAllocation, bytes32[] calldata proof) external nonReentrant whenNotPaused {
        if (block.timestamp >= claimDeadline) {
            revert ClaimWindowClosed();
        }

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, totalAllocation))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
            revert InvalidProof();
        }

        uint256 vested = totalAllocation * vestedFraction(block.timestamp) / BPS_DENOMINATOR;
        uint256 alreadyPaid = claimed[msg.sender];
        if (vested <= alreadyPaid) {
            revert NothingToClaim();
        }
        uint256 payout = vested - alreadyPaid;

        // CEI: state mutation before any external interactions. K613S1 burnFrom reverts with ERC20InsufficientBalance if the caller has not pre-claimed enough K613S1 from the Distributor.
        claimed[msg.sender] = vested;
        k613s1.burnFrom(msg.sender, payout);
        k613.safeTransfer(msg.sender, payout);

        emit Claimed(msg.sender, payout, vested);
    }

    /// @notice After `claimDeadline`, governance recovers any K613 still held by the contract (unclaimed allocations + accidental sends). Only callable by `DEFAULT_ADMIN_ROLE`.
    function recoverUnclaimedK613(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (block.timestamp < claimDeadline) {
            revert ClaimsStillOpen();
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        k613.safeTransfer(to, amount);
        emit UnclaimedK613Recovered(to, amount);
    }

    /// @notice Pauses claims. Only callable by `PAUSER_ROLE`.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes claims. Only callable by `PAUSER_ROLE`.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

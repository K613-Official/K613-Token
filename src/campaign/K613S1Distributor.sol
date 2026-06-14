// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import {K613S1} from "../token/K613S1.sol";

/// @title K613S1Distributor
/// @notice Cumulative Merkle distributor that mints K613S1 to participants of the K613 Points Campaign Season 1.
/// @dev Each weekly snapshot publishes a Merkle root over `keccak256(bytes.concat(keccak256(abi.encode(account, cumulativeAmount))))` leaves; users may claim at any time, and the contract mints only the delta `cumulativeAmount - claimed[user]`. Operator-key blast radius is bounded by `weeklyMintCap`, the maximum increase in cumulative supply allowed per `setMerkleRoot` call. `weeklyMintCap` itself is hard-bounded by `MAX_WEEKLY_MINT_CAP` so a compromised admin cannot disable the cap.
contract K613S1Distributor is AccessControl, Pausable, ReentrancyGuard {
    /// @notice Thrown when a zero address is passed to the constructor.
    error ZeroAddress();
    /// @notice Thrown when a zero Merkle root is posted; would brick all claims until next update.
    error EmptyMerkleRoot();
    /// @notice Thrown when a Merkle proof does not validate against the active root.
    error InvalidProof();
    /// @notice Thrown when the caller has already claimed at least the proved cumulative amount.
    error NothingToClaim();
    /// @notice Thrown when the new cumulative supply is less than the previous one.
    error NonMonotonicSupply();
    /// @notice Thrown when the increase in cumulative supply exceeds the configured `weeklyMintCap`.
    error WeeklyCapExceeded();
    /// @notice Thrown when an admin attempts to set `weeklyMintCap` above `MAX_WEEKLY_MINT_CAP`.
    error CapExceedsMaximum();

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Hard upper bound on `weeklyMintCap`. Bounds the worst case even if `DEFAULT_ADMIN_ROLE` is compromised; a malicious admin cannot raise the cap beyond this value to drain the campaign.
    uint256 public constant MAX_WEEKLY_MINT_CAP = 100_000_000e18;

    /// @notice K613S1 token minted on claim. The distributor must hold `MINTER_ROLE` on this token.
    K613S1 public immutable k613s1;

    /// @notice Active Merkle root. Operator updates this each week.
    bytes32 public merkleRoot;

    /// @notice Most recent week index posted via `setMerkleRoot`. Stored for off-chain audit; not enforced on-chain.
    uint256 public currentWeek;

    /// @notice Sum of all `cumulativeAmount` leaves under the active Merkle root. Tracks the maximum total K613S1 the current root authorises.
    uint256 public lastRootCumulativeSupply;

    /// @notice Maximum allowed increase in `lastRootCumulativeSupply` per `setMerkleRoot` call. Bounds operator-key blast radius if the operator EOA is compromised.
    uint256 public weeklyMintCap;

    /// @notice Cumulative K613S1 minted to each user across all weeks. Equals the highest `cumulativeAmount` they have proved.
    mapping(address => uint256) public claimed;

    /// @notice Emitted when the operator posts a new Merkle root.
    event MerkleRootUpdated(bytes32 indexed newRoot, uint256 newCumulativeSupply, uint256 weekNumber);
    /// @notice Emitted when admin updates the weekly mint cap.
    event WeeklyMintCapSet(uint256 newCap);
    /// @notice Emitted on each successful claim.
    event Claimed(address indexed account, uint256 mintAmount, uint256 cumulativeAmount, uint256 weekNumber);

    /// @notice Deploys the distributor.
    /// @param k613s1Token Address of the K613S1 token. Admin must subsequently grant `MINTER_ROLE` on K613S1 to this contract.
    /// @param initialWeeklyMintCap Starting value for `weeklyMintCap`.
    /// @dev Grants `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, and `OPERATOR_ROLE` to the deployer. Admin grants/revokes `OPERATOR_ROLE` to migrate from EOA to multisig later.
    constructor(address k613s1Token, uint256 initialWeeklyMintCap) {
        if (k613s1Token == address(0)) {
            revert ZeroAddress();
        }
        if (initialWeeklyMintCap > MAX_WEEKLY_MINT_CAP) {
            revert CapExceedsMaximum();
        }
        k613s1 = K613S1(k613s1Token);
        weeklyMintCap = initialWeeklyMintCap;
        emit WeeklyMintCapSet(initialWeeklyMintCap);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /// @notice Posts a new Merkle root with cumulative K613S1 allocation totals across all participants.
    /// @param newRoot The new Merkle root.
    /// @param newCumulativeSupply Sum of all `cumulativeAmount` leaves under `newRoot`. Must be >= the previous value, and the increase must not exceed `weeklyMintCap`.
    /// @param weekNumber Operator-controlled week index for off-chain audit; not enforced on-chain.
    function setMerkleRoot(bytes32 newRoot, uint256 newCumulativeSupply, uint256 weekNumber)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        if (newRoot == bytes32(0)) {
            revert EmptyMerkleRoot();
        }
        if (newCumulativeSupply < lastRootCumulativeSupply) {
            revert NonMonotonicSupply();
        }
        if (newCumulativeSupply - lastRootCumulativeSupply > weeklyMintCap) {
            revert WeeklyCapExceeded();
        }
        merkleRoot = newRoot;
        lastRootCumulativeSupply = newCumulativeSupply;
        currentWeek = weekNumber;
        emit MerkleRootUpdated(newRoot, newCumulativeSupply, weekNumber);
    }

    /// @notice Updates `weeklyMintCap`. Only callable by `DEFAULT_ADMIN_ROLE`. Hard-bounded by `MAX_WEEKLY_MINT_CAP`.
    function setWeeklyMintCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap > MAX_WEEKLY_MINT_CAP) {
            revert CapExceedsMaximum();
        }
        weeklyMintCap = newCap;
        emit WeeklyMintCapSet(newCap);
    }

    /// @notice Claims the difference between the caller's authorised cumulative allocation and what they have already minted.
    /// @param cumulativeAmount Total K613S1 the caller is authorised to have minted up to and including the active root.
    /// @param proof Merkle proof for `keccak256(bytes.concat(keccak256(abi.encode(msg.sender, cumulativeAmount))))` against `merkleRoot`.
    function claim(uint256 cumulativeAmount, bytes32[] calldata proof) external nonReentrant whenNotPaused {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, cumulativeAmount))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) {
            revert InvalidProof();
        }
        uint256 alreadyClaimed = claimed[msg.sender];
        if (cumulativeAmount <= alreadyClaimed) {
            revert NothingToClaim();
        }
        uint256 mintAmount = cumulativeAmount - alreadyClaimed;
        claimed[msg.sender] = cumulativeAmount;
        k613s1.mint(msg.sender, mintAmount);
        emit Claimed(msg.sender, mintAmount, cumulativeAmount, currentWeek);
    }

    /// @notice Pauses claims and root updates. Only callable by `PAUSER_ROLE`.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes claims and root updates. Only callable by `PAUSER_ROLE`.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}

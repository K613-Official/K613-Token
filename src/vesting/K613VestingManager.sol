// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {K613VestingWallet} from "./K613VestingWallet.sol";

/// @title K613VestingManager
/// @notice Ownable factory and registry for `K613VestingWallet` instances funded with a single ERC20 token.
/// @dev Creates wallets, pulls the configured token from the owner (or approved funder) via `safeTransferFrom`, and tracks vesting metadata. Additional funding can be sent to existing managed wallets.
contract K613VestingManager is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Caller passed a zero address where a non-zero address is required.
    error ZeroAddress();
    /// @notice Amount was zero where a positive amount is required.
    error ZeroAmount();
    /// @notice `fundVestingWallet` was called for an address not created by this manager.
    error WalletNotManaged();

    /// @notice Snapshot of a managed vesting wallet at creation / last funding bookkeeping.
    /// @param beneficiary Beneficiary of the vesting wallet.
    /// @param vestingWallet Address of the deployed `K613VestingWallet`.
    /// @param startTimestamp Vesting schedule start (see `K613VestingWallet`).
    /// @param durationSeconds Vesting duration after cliff.
    /// @param cliffSeconds Cliff length.
    /// @param initialAmount Tokens moved in at creation.
    /// @param totalFunded Cumulative tokens transferred to the wallet through this manager.
    /// @param createdAt `block.timestamp` when the wallet was created.
    struct VestingRecord {
        address beneficiary;
        address vestingWallet;
        uint64 startTimestamp;
        uint64 durationSeconds;
        uint64 cliffSeconds;
        uint256 initialAmount;
        uint256 totalFunded;
        uint256 createdAt;
    }

    /// @notice Emitted when a new vesting wallet is deployed and initially funded.
    event VestingWalletCreated(
        address indexed creator,
        address indexed beneficiary,
        address indexed vestingWallet,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint256 amount
    );
    /// @notice Emitted when extra tokens are sent to an existing managed vesting wallet.
    event VestingFunded(address indexed funder, address indexed vestingWallet, uint256 amount, uint256 totalFunded);

    /// @notice ERC20 token used for all `createVestingWallet` and `fundVestingWallet` transfers.
    IERC20 public immutable token;
    /// @notice Whether `vestingWallet` was created by this manager.
    mapping(address vestingWallet => bool isManagedWallet) public isManagedWallet;
    mapping(address beneficiary => address[]) private _walletsByBeneficiary;
    mapping(address vestingWallet => VestingRecord) private _vestingRecords;
    address[] private _allWallets;

    /// @param initialOwner Owner allowed to create and fund vesting wallets.
    /// @param tokenAddress ERC20 token pulled to vesting wallets (must match the token the wallets will hold).
    constructor(address initialOwner, address tokenAddress) Ownable(initialOwner) {
        if (initialOwner == address(0) || tokenAddress == address(0)) {
            revert ZeroAddress();
        }
        token = IERC20(tokenAddress);
    }

    /// @notice Deploys a `K613VestingWallet` for `beneficiary`, registers it, and transfers `amount` of `token` from the caller into the wallet.
    /// @param beneficiary Recipient of vested releases (must be non-zero).
    /// @param startTimestamp Vesting start time.
    /// @param durationSeconds Linear vesting length after cliff.
    /// @param cliffSeconds No releases before `startTimestamp + cliffSeconds`.
    /// @param amount Initial funding; caller must have approved this contract.
    /// @return vestingWallet Address of the new vesting wallet.
    function createVestingWallet(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint256 amount
    ) external onlyOwner returns (address vestingWallet) {
        if (beneficiary == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        K613VestingWallet wallet = new K613VestingWallet(beneficiary, startTimestamp, durationSeconds, cliffSeconds);
        vestingWallet = address(wallet);

        isManagedWallet[vestingWallet] = true;
        _walletsByBeneficiary[beneficiary].push(vestingWallet);
        _allWallets.push(vestingWallet);
        _vestingRecords[vestingWallet] = VestingRecord({
            beneficiary: beneficiary,
            vestingWallet: vestingWallet,
            startTimestamp: startTimestamp,
            durationSeconds: durationSeconds,
            cliffSeconds: cliffSeconds,
            initialAmount: amount,
            totalFunded: amount,
            createdAt: block.timestamp
        });

        token.safeTransferFrom(_msgSender(), vestingWallet, amount);

        emit VestingWalletCreated(
            _msgSender(), beneficiary, vestingWallet, startTimestamp, durationSeconds, cliffSeconds, amount
        );
    }

    /// @notice Sends additional `token` from the caller to a vesting wallet created by this manager.
    /// @param vestingWallet Managed vesting wallet address.
    /// @param amount Extra amount; caller must have approved this contract.
    function fundVestingWallet(address vestingWallet, uint256 amount) external onlyOwner {
        if (vestingWallet == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (!isManagedWallet[vestingWallet]) {
            revert WalletNotManaged();
        }

        token.safeTransferFrom(_msgSender(), vestingWallet, amount);
        _vestingRecords[vestingWallet].totalFunded += amount;

        emit VestingFunded(_msgSender(), vestingWallet, amount, _vestingRecords[vestingWallet].totalFunded);
    }

    /// @notice Returns all managed vesting wallet addresses for a beneficiary.
    /// @param beneficiary Beneficiary to query.
    /// @return List of vesting wallet addresses (may be empty).
    function getWalletsByBeneficiary(address beneficiary) external view returns (address[] memory) {
        return _walletsByBeneficiary[beneficiary];
    }

    /// @notice Returns stored metadata for a vesting wallet.
    /// @param vestingWallet Address of the vesting wallet.
    /// @return record `VestingRecord` or zeroed struct if unknown.
    function getVestingRecord(address vestingWallet) external view returns (VestingRecord memory) {
        return _vestingRecords[vestingWallet];
    }

    /// @notice Returns every managed vesting wallet address in creation order.
    /// @return Full array; can be large—prefer `getWalletsSlice` for pagination.
    function getAllWallets() external view returns (address[] memory) {
        return _allWallets;
    }

    /// @notice Number of managed vesting wallets.
    /// @return Length of the internal wallet list.
    function totalWallets() external view returns (uint256) {
        return _allWallets.length;
    }

    /// @notice Vesting wallet at index in the global creation order.
    /// @param index Position in `_allWallets`.
    /// @return Wallet address at `index`.
    function getWalletAt(uint256 index) external view returns (address) {
        return _allWallets[index];
    }

    /// @notice Paginated view over `getAllWallets`.
    /// @param offset Start index in `_allWallets`.
    /// @param limit Maximum number of addresses to return.
    /// @return wallets Empty if `offset` is out of range or `limit` is zero.
    function getWalletsSlice(uint256 offset, uint256 limit) external view returns (address[] memory wallets) {
        uint256 total = _allWallets.length;
        if (offset >= total || limit == 0) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        wallets = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            wallets[i - offset] = _allWallets[i];
        }
    }
}

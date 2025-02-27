// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Owned} from "@solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/// @title BoringSafe
/// @notice Lightweight middleware contract for holding funds that have been committed to reward campaigns in BoringChef.
contract BoringSafe is Owned(msg.sender) {
    using SafeTransferLib for ERC20;

    /// @notice Transfers funds from this contract.
    /// @notice Only callable by the owner (BoringChef).
    /// @param token The address of the ERC20 token to transfer.
    /// @param to The recipient address.
    /// @param amount The amount of tokens  to transfer.
    function transfer(address token, address to, uint256 amount) external onlyOwner {
        // Transfer ERC20 tokens
        ERC20(token).safeTransfer(to, amount);
    }
}

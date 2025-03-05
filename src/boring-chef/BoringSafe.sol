// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Owned} from "@solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/// @title BoringSafe
/// @notice Lightweight middleware contract for holding funds that have been committed to reward campaigns in BoringChef.
contract BoringSafe is Owned(msg.sender) {
    using SafeTransferLib for ERC20;

    error ArrayLengthMismatch();

    /// @notice Transfers tokens from this contract.
    /// @notice Only callable by the owner (BoringChef).
    /// @param tokens The addresses of the ERC20 tokens to transfer.
    /// @param amounts The amounts of each token to transfer.
    /// @param to The recipient address.
    function transfer(address[] memory tokens, uint256[] memory amounts, address to) external onlyOwner {
        // Make sure each token has a corresponding amount
        uint256 numTokens = tokens.length;
        if (numTokens != amounts.length) {
            revert ArrayLengthMismatch();
        }
        // Transfer all tokens to the specified address
        for (uint256 i = 0; i < numTokens; ++i) {
            // Transfer ERC20 tokens
            ERC20(tokens[i]).safeTransfer(to, amounts[i]);
        }
    }
}

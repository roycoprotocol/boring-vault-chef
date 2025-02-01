// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {BoringVault} from "src/base/BoringVault.sol";
import {BoringChef} from "src/boring-chef/BoringChef.sol";

import {Test, stdStorage, StdStorage, stdError, console} from "@forge-std/Test.sol";

contract BoringVaultTest is Test, MerkleTreeHelper {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using stdStorage for StdStorage;

    BoringVault public boringVault;
    BoringChef public boringChef;

    function setUp() external {}

    // Basic Deposit & Withdraw Logic
    function testSingleDeposit() external {}
    function testMultipleDeposits() external {}
    function testWithdrawPartial() external {}
    function testWithdrawAll() external {}
    function testFailWithdrawExceedingBalance() external {}
    function testDepositZero() external {}
    function testWithdrawZero() external {}

    // Transfer & TransferFrom Logic
    function testBasicTransfer() external {}
    function testZeroTransfer() external {}
    function testTransferSelf() external {}
    function testFailTransferFromInsufficientAllowance() external {}
    function testTransferFromWithSufficientAllowance() external {}

    // Epoch Rolling Logic
    function testManualEpochRollover() external {}
    function testMultipleEpochRollovers() external {}
    function testRolloverNoUsers() external {}

    // Distributing Rewards
    function testDistributeRewardsValidRange() external {}
    function testFailDistributeRewardsStartEpochGreaterThanEndEpoch() external {}
    function testFailDistributeRewardsEndEpochInFuture() external {}
    function testFailDistributeRewardsInsufficientTokenBalance() external {}
    function testSingleEpochRewardDistribution() external {}

    // Claiming Rewards
    function testClaimFullRange() external {}
    function testClaimPartialEpochParticipation() external {}
    function testClaimZeroTotalShares() external {}
    function testClaimAlreadyClaimed() external {}
    function testClaimMultipleRewards() external {}

    // _findUserBalanceAtEpoch Logic
    function testFindUserBalanceAtEpochNoDeposits() external {}
    function testFindUserBalanceAtEpochAllUpdatesAfter() external {}
    function testFindUserBalanceAtEpochExactMatch() external {}
    function testFindUserBalanceAtEpochMultipleUpdates() external {}

    // _updateUserShareAccounting Logic
    function testUpdateUserShareAccountingSameEpochMultipleTimes() external {}
    function testUpdateUserShareAccountingBrandNewEpoch() external {}
    function testUpdateUserShareAccountingEmpty() external {}

    // Role-Based Security
    function testFailDistributeRewardsUnauthorized() external {}
    function testDistributeRewardsByOwner() external {}

    // Overall Integration & Edge Cases
    function testMultipleUsersIntegration() external {}
    function testZeroDurationEpoch() external {}
    function testLargeRewards() external {}
    function testFractionalDivisionsRounding() external {}
    function testStressManyEpochs() external {}
}
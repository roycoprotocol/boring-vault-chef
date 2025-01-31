// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/// @title BoringChef
contract BoringChef is ERC20, Auth {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error NoFutureEpochRewards();
    error StartEpochMustBeBeforeEndEpoch();
    error UserDoesNotHaveEnoughSharesToWithdraw();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event UserSharesUpdated(address indexed user, uint256 epoch, uint256 newShares);
    event EpochUpdated(uint256 indexed epoch, uint256 eligibleShares, uint256 startTimestamp, uint256 endTimestamp);
    event RewardDistributed(address indexed token, uint256 amount, uint256 startEpoch, uint256 endEpoch);
    event UserRewardsClaimed(address indexed user, uint256 startEpoch, uint256 endEpoch, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @dev A record of a user's balance changing at a specific epoch
    struct BalanceChangeUpdate {
        /// @dev The epoch in which the deposit was made
        uint256 epoch;

        /// @dev The total number of shares the user has at this epoch
        uint256 totalSharesBalance;
    }
    
    /// @dev A record of an epoch
    struct Epoch {
        /// @dev The total number of shares eligible for rewards at this epoch
        /// This is not the total number of shares deposited, but the total number 
        /// of shares that have been deposited and are eligible for rewards
        uint256 eligibleShares;

        /// @dev The timestamp at which the epoch starts
        uint256 startTimestamp;

        /// @dev The timestamp at which the epoch ends
        /// This is set to 0 if the epoch is not over
        uint256 endTimestamp;
    }

    /// @dev A record of a reward
    struct Reward {
        /// @dev The token being rewarded
        address token;

        /// @dev The rate at which the reward token is distributed per second
        uint256 rewardTokenDistributionRate;

        /// @dev The epoch at which the reward starts
        uint256 startEpoch;

        /// @dev The epoch at which the reward ends
        uint256 endEpoch;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev The share token.
    address public immutable shareToken;

    /// @dev The current epoch
    uint256 public currentEpoch;

    /// @dev A record of all epochs
    mapping(uint256 => Epoch) public epochs;

    /// @dev Maps users to an array of their balance changes
    mapping(address user => BalanceChangeUpdate[]) public userToBalanceChanges;

    /// @dev Maps rewards to reward IDs
    mapping(uint256 rewardId => Reward) public rewards;
    uint256 public maxRewardId;

    /// @dev Maps users to an array of booleans representing whether they have claimed rewards for a given epoch
    /// TODO let's pack this into an array of uint256s or whatever is most efficient
    mapping(address user => mapping(uint256 rewardId => bool)) public userToClaimedEpochs;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the contract.
    /// @dev We do this by setting the share token and initializing the first epoch.
    /// @param _owner The address of the owner.
    /// @param _name The name of the share token.
    /// @param _symbol The symbol of the share token.
    /// @param _decimals The decimals of the share token.
    constructor(address _shareToken, address _owner, string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol, _decimals)
        Auth(_owner, Authority(address(0)))
    {
        shareToken = _shareToken;
    }

    // constructor(address _shareToken) {
    //     shareToken = _shareToken;
    // }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT/WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit share tokens into the contract.
    /// @dev We do this by increasing the user's balance for the next epoch.
    /// @param amount The amount of tokens to deposit.
    function deposit(uint256 amount) external {
        // Increase the user's balance for the next epoch.
        // We don't want to do this on the current epoch as it is not over yet.
        _increaseUpcomingEpochParticipation(msg.sender, amount);

        // Transfer the tokens to the contract.
        ERC20(shareToken).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw tokens from the contract.
    /// @dev We do this by decreasing the user's balance for the current epoch.
    /// @param amount The amount of tokens to withdraw.
    function withdraw(uint256 amount) external {
        // Decrease the user's balance for the current epoch.
        _decreaseCurrentEpochParticipation(msg.sender, amount);

        // Transfer the tokens to the user.
        ERC20(shareToken).safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD DISTRIBUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Distribute rewards retroactively to users deposited during a given epoch range.
    /// @dev We do this by creating a new Reward object and storing it in the rewards mapping.
    /// @dev We also transfer the reward tokens to the contract.
    /// @param token The address of the reward token.
    /// @param amount The amount of reward tokens to distribute.
    /// @param startEpoch The start epoch.
    /// @param endEpoch The end epoch.
    function distributeRewards(
        address token,
        uint256 amount,
        uint256 startEpoch,
        uint256 endEpoch
    ) external requiresAuth {
        // Check that this epoch range is in the past as rewards are distributed retroactively.
        // We also don't want to distribute rewards on the current epoch as it is not over yet.
        // TODO: check if this is the correct logic ^^^^^^
        require (endEpoch < currentEpoch, "No rewards on future epochs");

        // Check that the start and end epochs are valid.
        require (startEpoch <= endEpoch, "Start epoch must be before end epoch");

        // Get the start and end epoch data.
        Epoch storage startEpochData = epochs[startEpoch];
        Epoch storage endEpochData = epochs[endEpoch];

        // Create a new reward and update the max reward ID
        uint256 rewardId = maxRewardId;
        rewards[rewardId] = Reward({
            token: token,
            // TODO prevent 2x epochs in one block, zeroing this
            // ^^^^ jack what did u mean by this?
            rewardTokenDistributionRate: amount.divWadDown(endEpochData.endTimestamp - startEpochData.startTimestamp),
            startEpoch: startEpoch,
            endEpoch: endEpoch
        });

        // Update the max reward ID
        maxRewardId = rewardId + 1;

        // Transfer the reward tokens to the contract.
        ERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim rewards for a given array of tokens and epoch ranges.
    /// @dev We do this by calculating the rewards owed to the user for each token and epoch range.
    /// @param rewardIDs The IDs of the rewards to claim.
    function claimRewards(
        uint256[] calldata rewardIDs
    ) external {
        // Fetch all balance change updates for the caller.
        BalanceChangeUpdate[] memory balanceChangeUpdates = userToBalanceChanges[msg.sender];

        // For each reward ID, we’ll calculate how many tokens are owed.
        for (uint256 i = 0; i < rewardIDs.length; i++) {
            // Retrieve the reward ID, start epoch, and end epoch.
            uint256 rewardId = rewardIDs[i];
            uint256 startEpoch = rewards[rewardId].startEpoch;
            uint256 endEpoch   = rewards[rewardId].endEpoch;

            // Initialize a local accumulator for the total reward owed.
            uint256 rewardsOwed = 0;

            // We want to iterate over the epoch range [startEpoch..endEpoch],
            // summing up the user’s share of tokens from each epoch.
            for (uint256 epoch = startEpoch; epoch <= endEpoch; epoch++) {
                // Determine the user’s share balance during this epoch.
                // TODO: OPTIMIZE THIS HELLA 
                uint256 userBalanceAtEpoch = _findUserBalanceAtEpoch(
                    msg.sender,
                    epoch,
                    balanceChangeUpdates
                );

                // Calculate total shares in that epoch (i.e. epochs[epoch].eligibleShares).
                uint256 totalSharesAtEpoch = epochs[epoch].eligibleShares;

                // Compute user fraction = userBalance / totalShares.
                uint256 userFraction = userBalanceAtEpoch.divWadDown(totalSharesAtEpoch);

                // Figure out how many tokens were distributed in this epoch
                // for the specified reward ID:
                uint256 epochDuration = epochs[epoch].endTimestamp - epochs[epoch].startTimestamp;
                uint256 epochReward = rewards[rewardId].rewardTokenDistributionRate.mulWadDown(epochDuration);
                
                // Multiply epochReward * fraction = userRewardThisEpoch.
                // Add that to rewardsOwed.
                rewardsOwed += epochReward.mulWadDown(userFraction);
            }

        // After we finish summing the user’s share across all epochs in the given range,
        // we have the total reward for that rewardId. Now we can do two things:
        // - Mark that the user has claimed [startEpoch..endEpoch] for this reward (if needed).
        // - Transfer tokens to the user.

        // Transfer the tokens to the user.
        ERC20(rewards[rewardId].token).safeTransfer(msg.sender, rewardsOwed);

        // Mark that the user has claimed this rewardID.
        userToClaimedEpochs[msg.sender][rewardId] = true;

        // Emit an event for clarity
            emit UserRewardsClaimed(msg.sender, startEpoch, endEpoch, rewardsOwed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Find the user’s share balance at a specific epoch.
    /// @dev This can be done via binary search over balanceChangeUpdates if the list is large.
    ///      For simplicity, you can also do a linear scan if the array is short.
    function _findUserBalanceAtEpoch(
        address user,
        uint256 epoch,
        BalanceChangeUpdate[] memory balanceChanges
    )
        internal
        view
        returns (uint256)
    {
        // Just iterate backwards until we find the epoch.
        uint256 i = balanceChanges.length - 1;
        while (balanceChanges[i].epoch > epoch) {
            i--;
        }

        // Return the user's balance at the most recent epoch before the target epoch.
        return balanceChanges[currentEpoch].totalSharesBalance;
    }

    /// @notice Optionally break out logic for how many tokens are minted to the entire vault in a given epoch
    function _epochRewardAmount(uint256 rewardId, uint256 epoch) internal view returns (uint256) {
        // 1. Access rewards[rewardId].rewardTokenDistributionRate
        // 2. Multiply by the number of seconds in that epoch
        //    e.g. epochs[epoch].endTimestamp - epochs[epoch].startTimestamp
        // 3. Return the total minted to that epoch for that reward
        // (That’s your “epochReward” in the example calculation.)
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Roll over to the next epoch.
    function _rollOverEpoch() internal {
        // Get the current and next epoch data.
        Epoch storage currentEpochData = epochs[currentEpoch];
        Epoch storage nextEpoch = epochs[currentEpoch + 1];

        // Update the current epoch's end timestamp and the next epoch's start timestamp.
        currentEpochData.endTimestamp = block.timestamp;
        nextEpoch.startTimestamp = block.timestamp;

        // Update the eligible shares for the next epoch if necessary.
        // This just means setting the eligible shares to the current epoch's eligible shares.
        if (nextEpoch.eligibleShares == 0) {
            nextEpoch.eligibleShares = currentEpochData.eligibleShares;
        }
        
        // Increment the current epoch.
        currentEpoch++;
    }

    /// @dev Increase the eligible shares for the next epoch.
    /// We do this because when a user deposits, we don't recognize their deposit until the next epoch.
    function _increaseUpcomingEpochParticipation(
        address user,
        uint256 amount
    ) internal {
        // Get the current and next epoch data.
        Epoch storage currentEpochData = epochs[currentEpoch];
        Epoch storage nextEpoch = epochs[currentEpoch + 1];

        // Update the next epoch's eligible shares.
        // If the next epoch's eligible shares haven't been set yet, we use the current epoch's eligible shares.
        // Otherwise, we add the amount to the next epoch's eligible shares.
        nextEpoch.eligibleShares = nextEpoch.eligibleShares > 0 ? nextEpoch.eligibleShares + amount : currentEpochData.eligibleShares + amount;

        // Now we need to update the user's balance for the next epoch.
        // First, we need to calculate their current balance at this epoch.
        uint256 userBalance = userToBalanceChanges[user].length > 0 
            ? userToBalanceChanges[user][userToBalanceChanges[user].length - 1].totalSharesBalance 
            : 0;

        // Next, we need to calculate their new balance at this epoch.
        uint256 newBalance = userBalance + amount;

        // Now we update the user's balance change for the next epoch.
        userToBalanceChanges[user].push(BalanceChangeUpdate({
            epoch: currentEpoch + 1,
            totalSharesBalance: newBalance
        }));
    }

    /// @dev Decrease the eligible shares for the current epoch.
    /// We do this because when a user withdraws, we cut their shares from the current epoch's eligible shares.
    function _decreaseCurrentEpochParticipation(
        address user,
        uint256 amount
    ) internal {
        // Get the current epoch data.
        Epoch storage currentEpochData = epochs[currentEpoch];

        // Decrease the current epoch's eligible shares.
        currentEpochData.eligibleShares -= amount;

        // Now we need to update the user's balance for the current epoch.
        // First, we need to calculate their current balance at this epoch.
        uint256 userBalance = userToBalanceChanges[user].length > 0 
            ? userToBalanceChanges[user][userToBalanceChanges[user].length - 1].totalSharesBalance 
            : 0;

        // Raise an error if the user's balance is less than the amount they are withdrawing.
        if (userBalance < amount) {
            revert UserDoesNotHaveEnoughSharesToWithdraw();
        }

        // Next, we need to calculate their new balance at this epoch.
        uint256 newBalance = userBalance - amount;

        // Now we update the user's balance change for the current epoch.
        userToBalanceChanges[user].push(BalanceChangeUpdate({
            epoch: currentEpoch,
            totalSharesBalance: newBalance
        }));
    }
}
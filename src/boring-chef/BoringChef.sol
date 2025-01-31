// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/// @title BoringChef
contract BoringChef is ERC20 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoFutureEpochRewards();
    error StartEpochMustBeBeforeEndEpoch();
    error UserDoesNotHaveEnoughSharesToWithdraw();
    error InvalidRewardCampaignDuration();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event UserSharesUpdated(address indexed user, uint256 epoch, uint256 newShares);
    event EpochStarted(uint256 indexed epoch, uint256 eligibleShares, uint256 startTimestamp);
    event RewardDistributed(address indexed token, uint256 amount, uint256 startEpoch, uint256 endEpoch);
    event UserRewardsClaimed(address indexed user, uint256 startEpoch, uint256 endEpoch, uint256 amount);

    event RewardsDistributed(
        address indexed token, uint256 indexed startEpoch, uint256 indexed endEpoch, uint256 amount
    );
    event UserDepositedIntoEpoch(address indexed user, uint256 indexed epoch, uint256 shareAmount);
    event UserWithdrawnFromEpoch(address indexed user, uint256 indexed epoch, uint256 shareAmount);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @dev A record of a user's balance changing at a specific epoch
    struct BalanceUpdate {
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
        uint256 rewardRate;
        /// @dev The epoch at which the reward starts
        uint256 startEpoch;
        /// @dev The epoch at which the reward ends
        uint256 endEpoch;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev The current epoch
    uint256 public currentEpoch;

    /// @dev A record of all epochs
    mapping(uint256 => Epoch) public epochs;

    /// @dev Maps users to an array of their balance changes
    mapping(address user => BalanceUpdate[]) public balanceUpdates;

    /// @dev Maps rewards to reward IDs
    mapping(uint256 rewardId => Reward) public rewards;
    uint256 public maxRewardId;

    /// @dev Maps users to an array of booleans representing whether they have claimed rewards for each epochID.
    /// @dev Each bit in userToClaimedEpochs[user][rewardIds] corresponds to one reward ID.
    mapping(address user => mapping(uint256 rewardIds => uint256 claimedEpochBitMask)) public userToClaimedEpochs;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the contract.
    /// @dev We do this by setting the share token and initializing the first epoch.
    /// @param _name The name of the share token.
    /// @param _symbol The symbol of the share token.
    /// @param _decimals The decimals of the share token.
    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol, _decimals) {}

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
    function distributeRewards(address token, uint256 amount, uint256 startEpoch, uint256 endEpoch) external {
        // Check that the start and end epochs are valid.
        if (startEpoch > endEpoch) {
            revert InvalidRewardCampaignDuration();
        }
        if (endEpoch >= currentEpoch) {
            revert NoFutureEpochRewards();
        }

        // Get the start and end epoch data.
        Epoch storage startEpochData = epochs[startEpoch];
        Epoch storage endEpochData = epochs[endEpoch];

        // Create a new reward and update the max reward ID
        uint256 rewardId = maxRewardId;
        rewards[rewardId] = Reward({
            token: token,
            // TODO prevent 2x epochs in one block, zeroing this
            // ^^^^ jack what did u mean by this?
            rewardRate: amount.divWadDown(endEpochData.endTimestamp - startEpochData.startTimestamp),
            startEpoch: startEpoch,
            endEpoch: endEpoch
        });

        // Update the max reward ID
        maxRewardId = rewardId + 1;

        // Transfer the reward tokens to the contract.
        ERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Emit rewards distributed event
        emit RewardsDistributed(token, startEpoch, endEpoch, amount);
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim rewards for a given array of tokens and epoch ranges.
    /// @dev We do this by calculating the rewards owed to the user for each token and epoch range.
    /// @param rewardIDs The IDs of the rewards to claim.
    function claimRewards(uint256[] calldata rewardIDs) external {
        // Fetch all balance change updates for the caller.
        BalanceUpdate[] memory userBalanceUpdates = balanceUpdates[msg.sender];

        // For each reward ID, we’ll calculate how many tokens are owed.
        for (uint256 i = 0; i < rewardIDs.length; i++) {
            // Retrieve the reward ID, start epoch, and end epoch.
            uint256 rewardId = rewardIDs[i];
            uint256 startEpoch = rewards[rewardId].startEpoch;
            uint256 endEpoch = rewards[rewardId].endEpoch;

            // Initialize a local accumulator for the total reward owed.
            uint256 rewardsOwed = 0;

            // We want to iterate over the epoch range [startEpoch..endEpoch],
            // summing up the user’s share of tokens from each epoch.
            for (uint256 epoch = startEpoch; epoch <= endEpoch; epoch++) {
                // Determine the user’s share balance during this epoch.
                // TODO: OPTIMIZE THIS HELLA
                uint256 userBalanceAtEpoch = _findUserBalanceAtEpoch(epoch, userBalanceUpdates);

                // Calculate total shares in that epoch (i.e. epochs[epoch].eligibleShares).
                uint256 totalSharesAtEpoch = epochs[epoch].eligibleShares;

                // Compute user fraction = userBalance / totalShares.
                uint256 userFraction = userBalanceAtEpoch.divWadDown(totalSharesAtEpoch);

                // Figure out how many tokens were distributed in this epoch
                // for the specified reward ID:
                uint256 epochDuration = epochs[epoch].endTimestamp - epochs[epoch].startTimestamp;
                uint256 epochReward = rewards[rewardId].rewardRate.mulWadDown(epochDuration);

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

    /// @notice Find the user’s share balance at a specific epoch.
    /// @dev This can be done via binary search over balanceUpdates if the list is large.
    ///      For simplicity, you can also do a linear scan if the array is short.
    function _findUserBalanceAtEpoch(uint256 epoch, BalanceUpdate[] memory balanceChanges)
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

    /*//////////////////////////////////////////////////////////////
                                TRANSFER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer shares
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function transfer(address to, uint256 amount) public virtual override(ERC20) returns (bool success) {
        // Transfer shares from msg.sender to "to"
        success = super.transfer(to, amount);

        // Account for withdrawal and forfeit incentives for current epoch for msg.sender
        _decreaseCurrentEpochParticipation(msg.sender, amount);

        // Mark this deposit eligible for incentives earned from the next epoch onwards for "to"
        _increaseUpcomingEpochParticipation(to, amount);
    }

    /// @notice Transfer shares from one user to another
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override(ERC20)
        returns (bool success)
    {
        // Transfer shares from "from" to "to"
        success = super.transferFrom(from, to, amount);

        // Account for withdrawal and forfeit incentives for current epoch for "from"
        _decreaseCurrentEpochParticipation(from, amount);

        // Mark this deposit eligible for incentives earned from the next epoch onwards for "to"
        _increaseUpcomingEpochParticipation(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint shares
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function _mint(address to, uint256 amount) internal override {
        // Mint the shares to the depositor
        super._mint(to, amount);

        // Mark this deposit eligible for incentives earned from the next epoch onwards
        _increaseUpcomingEpochParticipation(to, amount);
    }

    /// @notice Burn shares
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function _burn(address from, uint256 amount) internal override {
        // Burn the shares from the depositor
        super._burn(from, amount);

        // Account for withdrawal and forfeit incentives for current epoch
        _decreaseCurrentEpochParticipation(from, amount);
    }

    /// @dev Roll over to the next epoch.
    /// @dev Should be called on every boring vault rebalance.
    function _rollOverEpoch() internal {
        // Cache currentEpoch for gas savings
        uint256 ongoingEpoch = currentEpoch;

        // Get the current and next epoch data.
        Epoch storage currentEpochData = epochs[ongoingEpoch];
        Epoch storage upcomingEpochData = epochs[ongoingEpoch++];

        // Update the current epoch's end timestamp and the next epoch's start timestamp.
        currentEpochData.endTimestamp = block.timestamp;
        upcomingEpochData.startTimestamp = block.timestamp;

        // Update the eligible shares for the next epoch if necessary by rolling them over.
        if (upcomingEpochData.eligibleShares == 0) {
            upcomingEpochData.eligibleShares = currentEpochData.eligibleShares;
        }

        // Emit event for epoch start
        emit EpochStarted(++currentEpoch, currentEpochData.eligibleShares, block.timestamp);
    }

    /// @notice Increase the user's share balance for the next epoch
    function _increaseUpcomingEpochParticipation(address user, uint256 amount) internal {
        // Cache currentEpoch for gas savings
        uint256 ongoingEpoch = currentEpoch;
        uint256 upcomingEpoch = ongoingEpoch + 1;

        // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
        Epoch storage currentEpochData = epochs[ongoingEpoch];
        Epoch storage upcomingEpochData = epochs[upcomingEpoch];

        // Deposit into the next epoch
        // If the next epoch shares have been initialized, increment them by the shares minted on entry
        // else rollover current shares plus the shares minted on entry
        upcomingEpochData.eligibleShares = upcomingEpochData.eligibleShares > 0
            ? upcomingEpochData.eligibleShares + amount
            : currentEpochData.eligibleShares + amount;

        // Get the post-deposit share balance of the user
        uint256 resultingShareBalance = balanceOf[user];

        // Account for the deposit for the user
        _updateUserShareAccounting(user, upcomingEpoch, resultingShareBalance);

        // Emit event for this deposit
        emit UserDepositedIntoEpoch(user, upcomingEpoch, amount);
    }

    /// @notice Decrease the user's share balance for the current epoch
    function _decreaseCurrentEpochParticipation(address user, uint256 amount) internal {
        // Cache currentEpoch for gas savings
        uint256 ongoingEpoch = currentEpoch;

        // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
        Epoch storage currentEpochData = epochs[ongoingEpoch];

        // Account for withdrawal from the current epoch
        currentEpochData.eligibleShares -= amount;

        // Get the post-withdraw share balance of the user
        uint256 resultingShareBalance = balanceOf[user];

        // Account for the withdrawal for the user
        _updateUserShareAccounting(user, ongoingEpoch, resultingShareBalance);

        // Emit event for this withdrawal
        emit UserWithdrawnFromEpoch(user, ongoingEpoch, amount);
    }

    /// @notice Update the user's share balance for a given epoch
    function _updateUserShareAccounting(address user, uint256 epoch, uint256 updatedBalance) internal {
        // Get the balance update data for the user
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];
        BalanceUpdate storage lastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 1];

        // Ensure no duplicate entries
        if (lastBalanceUpdate.epoch == epoch) {
            lastBalanceUpdate.totalSharesBalance = updatedBalance;

            // If the last balance update is not for the current epoch, add a new balance update
        } else {
            userBalanceUpdates.push(BalanceUpdate({epoch: epoch, totalSharesBalance: updatedBalance}));
        }
    }

/// @notice Sets the boolean “claimed” flag for `rewardId` in user’s bitmask.
/// @dev `isClaimed = true` sets the bit; `isClaimed = false` clears the bit.
function _setUserClaimedEpochs(
    address user,
    uint256 rewardId,
    bool isClaimed
)
    internal
{
    // Determine which 256-bit word (the “block”) we need
    uint256 wordIndex = rewardId / 256;

    // The bit offset inside that 256-bit word
    uint256 bitOffset = rewardId % 256;

    // Read the current word (256 bits) from storage
    uint256 currentWord = userToClaimedEpochs[user][wordIndex];

    if (isClaimed) {
        // Set the bit
        currentWord |= (1 << bitOffset);
    } else {
        // Clear the bit
        currentWord &= ~(1 << bitOffset);
    }

    // Write back the updated word
    userToClaimedEpochs[user][wordIndex] = currentWord;
}

    /// @notice Returns whether `user` has claimed `rewardId` (true/false).
    function _getUserClaimedEpochs(address user, uint256 rewardId)
        internal
        view
        returns (bool claimed)
    {
        // Determine the word/block index
        uint256 wordIndex = rewardId / 256;
        // The bit offset within that block
        uint256 bitOffset = rewardId % 256;

        // Read the 256-bit word
        uint256 currentWord = userToClaimedEpochs[user][wordIndex];

        // Shift right so that the target bit is in the least significant position,
        // then check if it’s 1
        claimed = ((currentWord >> bitOffset) & 1) == 1;
    }
}

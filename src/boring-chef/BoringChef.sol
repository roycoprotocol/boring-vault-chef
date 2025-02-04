// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {BoringSafe} from "./BoringSafe.sol";

/// @title BoringChef
contract BoringChef is Auth, ERC20 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ArrayLengthMismatch();
    error NoFutureEpochRewards();
    error InvalidRewardCampaignDuration();
    error RewardClaimedAlready(uint256 rewardId);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event EpochStarted(uint256 indexed epoch, uint256 eligibleShares, uint256 startTimestamp);
    event UserRewardsClaimed(address indexed user, uint256 rewardId, uint256 amount);
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
        uint128 epoch;
        /// @dev The total number of shares the user has at this epoch
        uint128 totalSharesBalance;
    }

    /// @dev A record of an epoch
    struct Epoch {
        /// @dev The total number of shares eligible for rewards at this epoch
        /// This is not the total number of shares deposited, but the total number
        /// of shares that have been deposited and are eligible for rewards
        uint128 eligibleShares;
        /// @dev The timestamp at which the epoch starts
        uint64 startTimestamp;
        /// @dev The timestamp at which the epoch ends
        /// This is set to 0 if the epoch is not over
        uint64 endTimestamp;
    }

    /// @dev A record of a reward
    struct Reward {
        /// @dev The token being rewarded
        address token;
        /// @dev The rate at which the reward token is distributed per second
        uint256 rewardRate;
        /// @dev The epoch at which the reward starts
        uint128 startEpoch;
        /// @dev The epoch at which the reward ends
        uint128 endEpoch;
    }

    /// @dev A record of a user's balance changing at a specific epoch
    struct RewardClaimInfo {
        /// @dev The epoch in which the deposit was made
        uint128 epoch;
        /// @dev The total number of shares the user has at this epoch
        uint128 totalSharesBalance;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev A contract to hold rewards to make sure the BoringVault doesn't spend them
    BoringSafe public immutable boringSafe;

    /// @dev The current epoch
    uint128 public currentEpoch;

    /// @dev A record of all epochs
    mapping(uint256 => Epoch) public epochs;

    /// @dev Maps users to an array of their balance changes
    mapping(address user => BalanceUpdate[]) public balanceUpdates;

    /// @dev Maps rewards to reward IDs
    mapping(uint256 rewardId => Reward) public rewards;
    uint256 public maxRewardId;

    /// @dev Nested mapping to efficiently keep track of claimed rewards per user
    /// @dev A rewardBucket contains batches of 256 contiguous rewardIds (Bucket 0: rewardIds 0-255, Bucket 1: rewardIds 256-527, ...)
    /// @dev claimedRewards is a 256 bit bit-field where each bit represents if a rewardId in that bucket (monotonically increasing) has been claimed.
    mapping(address user => mapping(uint256 rewardBucket => uint256 claimedRewards)) public
        userToRewardBucketToClaimedRewards;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the contract.
    /// @dev We do this by setting the share token and initializing the first epoch.
    /// @param _owner The owner of the BoringVault.
    /// @param _name The name of the share token.
    /// @param _symbol The symbol of the share token.
    /// @param _decimals The decimals of the share token.
    constructor(address _owner, string memory _name, string memory _symbol, uint8 _decimals)
        Auth(_owner, Authority(address(0)))
        ERC20(_name, _symbol, _decimals)
    {
        boringSafe = new BoringSafe();
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD DISTRIBUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Roll over to the next epoch.
    /// @dev Can only be called by an authorized address.
    function rollOverEpoch() external requiresAuth {
        _rollOverEpoch();
    }

    /// @notice Distribute rewards retroactively to users deposited during a given epoch range for multiple campaigns.
    /// @dev Creates new Reward objects and stores them in the rewards mapping, and transfers the reward tokens to the BoringSafe.
    /// @param tokens Array of addresses for the reward tokens.
    /// @param amounts Array of reward token amounts to distribute.
    /// @param startEpochs Array of start epochs for each reward distribution.
    /// @param endEpochs Array of end epochs for each reward distribution.
    function distributeRewards(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint128[] calldata startEpochs,
        uint128[] calldata endEpochs
    ) external requiresAuth {
        // Ensure that all arrays are the same length.
        if (tokens.length != amounts.length || tokens.length != startEpochs.length || tokens.length != endEpochs.length)
        {
            revert ArrayLengthMismatch();
        }

        // Loop over each set of parameters.
        for (uint256 i = 0; i < tokens.length; i++) {
            // Check that the start and end epochs are valid.
            if (startEpochs[i] > endEpochs[i]) {
                revert InvalidRewardCampaignDuration();
            }
            if (endEpochs[i] >= currentEpoch) {
                revert NoFutureEpochRewards();
            }

            // Get the start and end epoch data.
            Epoch storage startEpochData = epochs[startEpochs[i]];
            Epoch storage endEpochData = epochs[endEpochs[i]];

            // Create a new reward and update the max reward ID.
            rewards[maxRewardId++] = Reward({
                token: tokens[i],
                // Calculate the reward rate over the epoch period.
                // Consider the case where endEpochData.endTimestamp == startEpochData.startTimestamp
                rewardRate: amounts[i].divWadDown(endEpochData.endTimestamp - startEpochData.startTimestamp),
                startEpoch: startEpochs[i],
                endEpoch: endEpochs[i]
            });

            // Transfer the reward tokens to the BoringSafe.
            ERC20(tokens[i]).safeTransferFrom(msg.sender, address(boringSafe), amounts[i]);

            // Emit an event for this reward distribution.
            emit RewardsDistributed(tokens[i], startEpochs[i], endEpochs[i], amounts[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim rewards for a given array of tokens and epoch ranges.
    /// @dev We do this by calculating the rewards owed to the user for each token and epoch range.
    /// @param rewardIds The IDs of the rewards to claim.
    function claimRewards(uint256[] calldata rewardIds) external {
        // Get the epoch range for all rewards to claim and the corresponding Reward structs.
        (uint128 minEpoch, uint128 maxEpoch, Reward[] memory rewardsToClaim) = _getEpochRangeForRewards(rewardIds);

        // Fetch the caller's balance update history.
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[msg.sender];
        uint128 firstEpochDeposited = userBalanceUpdates[0].epoch;
        // Use the later of the minEpoch from rewards or the user's first deposit epoch.
        if (firstEpochDeposited > minEpoch) {
            minEpoch = firstEpochDeposited;
        }

        // Precompute the user's share ratios and epoch durations from minEpoch to maxEpoch.
        (uint256[] memory userShareRatios, uint256[] memory epochDurations) =
            _computeUserShareRatiosAndDurations(minEpoch, maxEpoch, userBalanceUpdates);

        // For each reward, calculate the reward amount owed and transfer tokens if necessary.
        for (uint256 i = 0; i < rewardIds.length; ++i) {
            uint256 rewardsOwed = _calculateRewardsOwed(rewardsToClaim[i], minEpoch, userShareRatios, epochDurations);

            if (rewardsOwed > 0) {
                boringSafe.transfer(rewardsToClaim[i].token, msg.sender, rewardsOwed);
                emit UserRewardsClaimed(msg.sender, rewardIds[i], rewardsOwed);
            }
        }
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
        _decreaseCurrentEpochParticipation(msg.sender, uint128(amount));

        // Mark this deposit eligible for incentives earned from the next epoch onwards for "to"
        _increaseUpcomingEpochParticipation(to, uint128(amount));
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
        _decreaseCurrentEpochParticipation(from, uint128(amount));

        // Mark this deposit eligible for incentives earned from the next epoch onwards for "to"
        _increaseUpcomingEpochParticipation(to, uint128(amount));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get a user's reward balance for a given reward ID.
    /// @param user The user to get the reward balance for.
    /// @param rewardId The ID of the reward to get the balance for.
    function getUserRewardBalance(address user, uint256 rewardId) external view returns (uint256) {
        // Fetch all balance change updates for the caller.
        BalanceUpdate[] memory userBalanceUpdates = balanceUpdates[user];

        // Retrieve the reward ID, start epoch, and end epoch.
        Reward storage reward = rewards[rewardId];

        // Initialize a local accumulator for the total reward owed.
        uint256 rewardsOwed = 0;

        // We want to iterate over the epoch range [startEpoch..endEpoch],
        // summing up the user's share of tokens from each epoch.
        for (uint256 epoch = reward.startEpoch; epoch <= reward.endEpoch; epoch++) {
            // Determine the user's share balance during this epoch.
            uint256 userBalanceAtEpoch = _findUserBalanceAtEpoch(epoch, userBalanceUpdates);

            // If the user is owed rewards for this epoch, remit them
            if (userBalanceAtEpoch > 0) {
                Epoch storage epochData = epochs[epoch];
                // Compute user fraction = userBalance / totalShares.
                uint256 userFraction = userBalanceAtEpoch.divWadDown(epochData.eligibleShares);

                // Figure out how many tokens were distributed in this epoch
                // for the specified reward ID:
                uint256 epochDuration = epochData.endTimestamp - epochData.startTimestamp;
                uint256 epochReward = reward.rewardRate.mulWadDown(epochDuration);

                // Multiply epochReward * fraction = userRewardThisEpoch.
                // Add that to rewardsOwed.
                rewardsOwed += epochReward.mulWadDown(userFraction);
            }
        }

        return rewardsOwed;
    }

    /// @notice Get the user's current eligible balance.
    /// @dev Returns the user's eligible balance for the current epoch, not the upcoming epoch
    function getUserEligibleBalance(address user) external view returns (uint256) {
        // Find the user's balance at the current epoch
        return _findUserBalanceAtEpoch(currentEpoch, balanceUpdates[user]);
    }

    /// @notice Get the array of balance updates for a user.
    /// @param user The user to get the balance updates for.
    function getTotalBalanceUpdates(address user) public view returns (uint256) {
        return balanceUpdates[user].length;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint shares
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function _mint(address to, uint256 amount) internal override(ERC20) {
        // Mint the shares to the depositor
        super._mint(to, amount);

        // Mark this deposit eligible for incentives earned from the next epoch onwards
        _increaseUpcomingEpochParticipation(to, uint128(amount));
    }

    /// @notice Burn shares
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function _burn(address from, uint256 amount) internal override(ERC20) {
        // Burn the shares from the depositor
        super._burn(from, amount);

        // Account for withdrawal and forfeit incentives for current epoch
        _decreaseCurrentEpochParticipation(from, uint128(amount));
    }

    /// @dev Roll over to the next epoch.
    /// @dev Should be called on every boring vault rebalance.
    function _rollOverEpoch() internal {
        // Cache currentEpoch for gas savings
        uint128 ongoingEpoch = currentEpoch;

        // Get the current and next epoch data.
        Epoch storage currentEpochData = epochs[ongoingEpoch];
        Epoch storage upcomingEpochData = epochs[++ongoingEpoch];

        // Update the current epoch's end timestamp and the next epoch's start timestamp.
        currentEpochData.endTimestamp = uint64(block.timestamp);
        upcomingEpochData.startTimestamp = uint64(block.timestamp);

        // Update the eligible shares for the next epoch if necessary by rolling them over.
        if (upcomingEpochData.eligibleShares == 0) {
            upcomingEpochData.eligibleShares = currentEpochData.eligibleShares;
        }

        // Emit event for epoch start
        emit EpochStarted(++currentEpoch, upcomingEpochData.eligibleShares, block.timestamp);
    }

    /// @notice Increase the user's share balance for the next epoch
    function _increaseUpcomingEpochParticipation(address user, uint128 amount) internal {
        // Cache currentEpoch for gas savings
        uint128 ongoingEpoch = currentEpoch;
        uint128 upcomingEpoch = ongoingEpoch + 1;

        // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
        Epoch storage currentEpochData = epochs[ongoingEpoch];
        Epoch storage upcomingEpochData = epochs[upcomingEpoch];

        // Deposit into the next epoch
        // If the next epoch shares have been initialized, increment them by the shares minted on entry
        // else rollover current shares plus the shares minted on entry
        upcomingEpochData.eligibleShares = upcomingEpochData.eligibleShares > 0
            ? upcomingEpochData.eligibleShares + amount
            : currentEpochData.eligibleShares + amount;

        // Account for the deposit for the user
        _updateUserShareAccounting(user, upcomingEpoch);

        // Emit event for this deposit
        emit UserDepositedIntoEpoch(user, upcomingEpoch, amount);
    }

    /// @notice Decrease the user's share balance for the current epoch
    function _decreaseCurrentEpochParticipation(address user, uint128 amount) internal {
        // Cache currentEpoch for gas savings
        uint128 ongoingEpoch = currentEpoch;

        // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
        Epoch storage currentEpochData = epochs[ongoingEpoch];

        // Account for withdrawal from the current epoch
        currentEpochData.eligibleShares -= amount;

        // Account for the withdrawal for the user
        _updateUserShareAccounting(user, ongoingEpoch);

        // Emit event for this withdrawal
        emit UserWithdrawnFromEpoch(user, ongoingEpoch, amount);
    }

    /// @notice Update the user's share balance for a given epoch
    function _updateUserShareAccounting(address user, uint128 epoch) internal {
        // Get the balance update data for the user
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];

        // If there are no balance updates, create a new one
        if (userBalanceUpdates.length == 0) {
            userBalanceUpdates.push(BalanceUpdate({epoch: epoch, totalSharesBalance: uint128(balanceOf[user])}));
        }
    
        // Get the last balance update
        BalanceUpdate storage lastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 1];

        // If there are no balance updates, create a new one
        if (userBalanceUpdates.length == 0) {
            userBalanceUpdates.push(BalanceUpdate({epoch: epoch, totalSharesBalance: uint128(balanceOf[user])}));
        } else if (userBalanceUpdates.length == 1) {
            // Ensure no duplicate entries
            if (lastBalanceUpdate.epoch == epoch) {
                lastBalanceUpdate.totalSharesBalance = uint128(balanceOf[user]);
            } else {
                // If the last balance update is not for the current epoch, add a new balance update
                userBalanceUpdates.push(BalanceUpdate({epoch: epoch, totalSharesBalance: uint128(balanceOf[user])}));
            }
        } else {
            // Get the second last balance update
            BalanceUpdate storage secondLastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 2];
            // Ensure no duplicate entries
            if (secondLastBalanceUpdate.epoch == epoch) {
                uint128 sharesBalance = uint128(balanceOf[user]);
                // Modify existing entries
                secondLastBalanceUpdate.totalSharesBalance = sharesBalance;
                lastBalanceUpdate.totalSharesBalance = sharesBalance;
            } else if (lastBalanceUpdate.epoch == epoch) {
                // Modify existing entry
                lastBalanceUpdate.totalSharesBalance = uint128(balanceOf[user]);
            } else {
                // If the last balance update is not for the current epoch, add a new balance update
                userBalanceUpdates.push(BalanceUpdate({epoch: epoch, totalSharesBalance: uint128(balanceOf[user])}));
            }
        }
    }

    /// @notice Get the epoch range for a given array of reward IDs.
    /// @param rewardIds The IDs of the rewards to get the epoch range for.
    /// @return minEpoch The minimum epoch for the given rewards.
    /// @return maxEpoch The maximum epoch for the given rewards.
    /// @return rewardsToClaim The rewards to claim for the given reward IDs.
    function _getEpochRangeForRewards(uint256[] calldata rewardIds)
        internal
        returns (uint128 minEpoch, uint128 maxEpoch, Reward[] memory rewardsToClaim)
    {
        uint256 rewardsLength = rewardIds.length;
        rewardsToClaim = new Reward[](rewardsLength);

        // Initialize the epoch range.
        minEpoch = type(uint128).max;
        maxEpoch = 0;

        // Variables to cache reward claim data.
        uint256 cachedRewardBucket;
        uint256 cachedClaimedRewards;

        for (uint256 i = 0; i < rewardsLength; ++i) {
            uint256 rewardBucket = rewardIds[i] / 256;
            if (i == 0) {
                cachedClaimedRewards = userToRewardBucketToClaimedRewards[msg.sender][rewardBucket];
                cachedRewardBucket = rewardBucket;
            } else if (cachedRewardBucket != rewardBucket) {
                userToRewardBucketToClaimedRewards[msg.sender][cachedRewardBucket] = cachedClaimedRewards;
                cachedRewardBucket = rewardBucket;
                cachedClaimedRewards = userToRewardBucketToClaimedRewards[msg.sender][rewardBucket];
            }
            uint256 bitOffset = rewardIds[i] % 256;
            bool claimed = ((cachedClaimedRewards >> bitOffset) & 1) == 1;
            if (claimed) {
                revert RewardClaimedAlready(rewardIds[i]);
            } else {
                cachedClaimedRewards |= (1 << bitOffset);
            }

            Reward storage reward = rewards[rewardIds[i]];
            uint128 startEpochValue = reward.startEpoch;
            uint128 endEpochValue = reward.endEpoch;

            if (startEpochValue < minEpoch) {
                minEpoch = startEpochValue;
            }
            if (endEpochValue > maxEpoch) {
                maxEpoch = endEpochValue;
            }
            
            rewardsToClaim[i] = Reward({
                token: reward.token,
                rewardRate: reward.rewardRate,
                startEpoch: startEpochValue,
                endEpoch: endEpochValue
            });
        }
        userToRewardBucketToClaimedRewards[msg.sender][cachedRewardBucket] = cachedClaimedRewards;
    }


    /// @notice Find the user's share balance at a specific epoch via binary search.
    /// @dev Assumes `balanceChanges` is sorted in ascending order by `epoch`.
    /// @param epoch The epoch for which we want the user's balance.
    /// @param balanceChanges The historical balance updates for a user, sorted ascending by epoch.
    /// @return The user's shares at the given epoch.
    function _findUserBalanceAtEpoch(uint256 epoch, BalanceUpdate[] memory balanceChanges)
        internal
        pure
        returns (uint256)
    {
        // Edge case: no balance changes at all
        if (balanceChanges.length == 0) {
            return 0;
        }

        // If the requested epoch is before the first recorded epoch,
        // assume the user had 0 shares.
        if (epoch < balanceChanges[0].epoch) {
            return 0;
        }

        // If the requested epoch is beyond the last recorded epoch,
        // return the most recent known balance.
        uint256 lastIndex = balanceChanges.length - 1;
        if (epoch >= balanceChanges[lastIndex].epoch) {
            return balanceChanges[lastIndex].totalSharesBalance;
        }

        // Standard binary search:
        // We want the highest index where balanceChanges[index].epoch <= epoch
        uint256 low = 0;
        uint256 high = lastIndex;

        // Perform the binary search in the range [low, high]
        while (low < high) {
            // Midpoint (biased towards the higher index when (low+high) is even)
            uint256 mid = (low + high + 1) >> 1; // same as (low + high + 1) / 2

            if (balanceChanges[mid].epoch <= epoch) {
                // If mid's epoch is <= target, we move `low` up to mid
                low = mid;
            } else {
                // If mid's epoch is > target, we move `high` down to mid - 1
                high = mid - 1;
            }
        }

        // Now `low == high`, which should be the index where epoch <= balanceChanges[low].epoch
        // and balanceChanges[low].epoch is the largest epoch not exceeding `epoch`.
        return balanceChanges[low].totalSharesBalance;
    }

    /// @dev Computes the user's share ratios and epoch durations for every epoch between minEpoch and maxEpoch.
    /// @param minEpoch The starting epoch.
    /// @param maxEpoch The ending epoch.
    /// @param userBalanceUpdates The user's balance update history.
    /// @return userShareRatios An array of the user’s fraction of shares for each epoch.
    /// @return epochDurations An array of the epoch durations (endTimestamp - startTimestamp) for each epoch.
    function _computeUserShareRatiosAndDurations(
        uint128 minEpoch,
        uint128 maxEpoch,
        BalanceUpdate[] storage userBalanceUpdates
    ) internal view returns (uint256[] memory userShareRatios, uint256[] memory epochDurations) {
        uint256 epochCount = maxEpoch - minEpoch + 1;
        userShareRatios = new uint256[](epochCount);
        epochDurations = new uint256[](epochCount);

        uint256 userBalanceUpdatesLength = userBalanceUpdates.length;
        // Get the user's share balance at minEpoch.
        (uint256 balanceIndex, uint256 currEpochSharesBalance) =
            _findLatestBalanceUpdateForEpoch(minEpoch, userBalanceUpdates);
        // Cache the next balance update if it exists.
        BalanceUpdate memory nextUserBalanceUpdate;
        if (balanceIndex < userBalanceUpdatesLength - 1) {
            nextUserBalanceUpdate = userBalanceUpdates[balanceIndex + 1];
        }

        // Loop over each epoch from minEpoch to maxEpoch.
        for (uint256 currEpoch = minEpoch; currEpoch <= maxEpoch; ++currEpoch) {
            // Update the user's share balance if a new balance update occurs at the current epoch.
            if (balanceIndex < userBalanceUpdatesLength - 1 && currEpoch == nextUserBalanceUpdate.epoch) {
                currEpochSharesBalance = userBalanceUpdates[++balanceIndex].totalSharesBalance;
                if (balanceIndex < userBalanceUpdatesLength - 1) {
                    nextUserBalanceUpdate = userBalanceUpdates[balanceIndex + 1];
                }
            }

            // Retrieve the epoch data.
            Epoch storage currEpochData = epochs[currEpoch];
            uint256 currEpochIndex = currEpoch - minEpoch;
            // Calculate the user's fraction of shares for this epoch.
            userShareRatios[currEpochIndex] = currEpochSharesBalance.divWadDown(currEpochData.eligibleShares);
            // Calculate the epoch duration.
            epochDurations[currEpochIndex] = currEpochData.endTimestamp - currEpochData.startTimestamp;
        }
    }

    /// @dev Calculates the total rewards owed for a single reward campaign over its epoch range.
    /// @param reward The reward campaign data.
    /// @param minEpoch The minimum epoch to consider (used as the offset for precomputed arrays).
    /// @param userShareRatios An array of the user's share ratios for each epoch.
    /// @param epochDurations An array of epoch durations for each epoch.
    /// @return rewardsOwed The total amount of tokens owed for this reward.
    function _calculateRewardsOwed(
        Reward memory reward,
        uint128 minEpoch,
        uint256[] memory userShareRatios,
        uint256[] memory epochDurations
    ) internal pure returns (uint256 rewardsOwed) {
        for (uint256 currEpoch = reward.startEpoch; currEpoch <= reward.endEpoch; ++currEpoch) {
            if (currEpoch < minEpoch) {
                // If user didn't have a deposit in this epoch, skip reward calculation
                continue;
            }
            uint256 currEpochIndex = currEpoch - minEpoch;
            uint256 userShareRatioForEpoch = userShareRatios[currEpochIndex];
            // Only process epochs where the user had a positive share ratio.
            if (userShareRatioForEpoch > 0) {
                uint256 epochReward = reward.rewardRate.mulWadDown(epochDurations[currEpochIndex]);
                rewardsOwed += epochReward.mulWadDown(userShareRatioForEpoch);
            }
        }
    }

    /// @notice Find the latest balance update index and balance for the specified epoch.
    /// @dev Assumes `balanceUpdates` is sorted in ascending order by `epoch`.
    /// @param epoch The epoch for which we want the user's balance.
    /// @param userBalanceUpdates The historical balance userBalanceUpdates for a user, sorted ascending by epoch.
    /// @return The latest balance update index and balance for the given epoch.
    function _findLatestBalanceUpdateForEpoch(uint128 epoch, BalanceUpdate[] storage userBalanceUpdates)
        internal
        view
        returns (uint256, uint128)
    {
        // If the requested epoch is beyond the last recorded epoch,
        // return the most recent known balance.
        uint256 lastIndex = userBalanceUpdates.length - 1;
        if (epoch >= userBalanceUpdates[lastIndex].epoch) {
            return (lastIndex, userBalanceUpdates[lastIndex].totalSharesBalance);
        }

        // Standard binary search:
        // We want the highest index where balanceUpdates[index].epoch <= epoch
        uint256 low = 0;
        uint256 high = lastIndex;

        // Perform the binary search in the range [low, high]
        while (low < high) {
            // Midpoint (biased towards the higher index when (low+high) is even)
            uint256 mid = (low + high + 1) >> 1; // same as (low + high + 1) / 2

            if (userBalanceUpdates[mid].epoch <= epoch) {
                // If mid's epoch is <= target, we move `low` up to mid
                low = mid;
            } else {
                // If mid's epoch is > target, we move `high` down to mid - 1
                high = mid - 1;
            }
        }

        // Now `low == high`, which should be the index where epoch <= balanceUpdates[low].epoch
        // and balanceUpdates[low].epoch is the largest epoch not exceeding `epoch`.
        return (low, userBalanceUpdates[low].totalSharesBalance);
    }
}

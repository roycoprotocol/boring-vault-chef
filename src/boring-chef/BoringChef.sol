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

    /// @dev Maps users to a boolean indicating if they have disabled reward accrual
    mapping(address user => bool isDisabled) public addressToIsDisabled; 

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

    /// @notice Disable reward accrual for a given address
    /// @dev Can only be called by an authorized address
    function disableRewardAccrual(address user) external requiresAuth {
        _decreaseCurrentEpochParticipation(user, uint128(balanceOf[user]));
        addressToIsDisabled[user] = true;
    }

    /// @notice Enable reward accrual for a given address
    /// @dev Can only be called by an authorized address
    function enableRewardAccrual(address user) external requiresAuth {
        addressToIsDisabled[user] = false;
        _increaseUpcomingEpochParticipation(user, uint128(balanceOf[user]));
    }

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
        // Cache length for gas op
        uint256 numRewards = tokens.length;
        // Ensure that all arrays are the same length.
        if (numRewards != amounts.length || numRewards != startEpochs.length || numRewards != endEpochs.length) {
            revert ArrayLengthMismatch();
        }

        // Loop over each set of parameters.
        for (uint256 i = 0; i < numRewards; ++i) {
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
            // Get total rewards owed to this reward campaign
            uint256 rewardsOwed = _calculateRewardsOwed(rewardsToClaim[i], minEpoch, userShareRatios, epochDurations);

            if (rewardsOwed > 0) {
                // Transfer rewards to the depositor
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

        // Account for transfer for sender and forfeit incentives for current epoch for msg.sender
        _decreaseCurrentEpochParticipation(msg.sender, uint128(amount));

        // Account for transfer for recipient and transfer incentives for next epoch onwards to "to"
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

        // Account for transfer for sender and forfeit incentives for current epoch for "from"
        _decreaseCurrentEpochParticipation(from, uint128(amount));

        // Account for transfer for recipient and transfer incentives for next epoch onwards to "to"
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

        // Mark this deposit eligible for incentives earned from the next epoch onwards
        _decreaseCurrentEpochParticipation(from, uint128(amount));
    }

    /// @dev Roll over to the next epoch.
    /// @dev Should be called on every boring vault rebalance.
    function _rollOverEpoch() internal {
        // Cache current epoch for gas savings
        uint128 ongoingEpoch = currentEpoch++;

        // Get the current and next epoch data.
        Epoch storage currentEpochData = epochs[ongoingEpoch];
        Epoch storage upcomingEpochData = epochs[++ongoingEpoch];

        // Update the current epoch's end timestamp and the next epoch's start timestamp.
        currentEpochData.endTimestamp = uint64(block.timestamp);
        upcomingEpochData.startTimestamp = uint64(block.timestamp);

        // Update the eligible shares for the next epoch by rolling them over.
        upcomingEpochData.eligibleShares += currentEpochData.eligibleShares;

        // Emit event for epoch start
        emit EpochStarted(ongoingEpoch, upcomingEpochData.eligibleShares, block.timestamp);
    }

    /// @notice Increase the user's share balance for the next epoch
    function _increaseUpcomingEpochParticipation(address user, uint128 amount) internal {

        // Skip participation accounting if the it has been disabled for this address
        if (addressToIsDisabled[user]) {
            return;
        }

        // Cache upcoming epoch for gas op
        uint128 targetEpoch = currentEpoch + 1;

        // Handle updating the balance accounting for this user
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];
        uint128 userBalance = uint128(balanceOf[user]);
        if (userBalanceUpdates.length == 0) {
            // If there are no balance updates, create a new one
            userBalanceUpdates.push(BalanceUpdate({epoch: targetEpoch, totalSharesBalance: userBalance}));
        } else {
            // Get the last balance update
            BalanceUpdate storage lastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 1];
            // Ensure no duplicate entries
            if (lastBalanceUpdate.epoch == targetEpoch) {
                // Handle case for multiple deposits into an epoch
                lastBalanceUpdate.totalSharesBalance = userBalance;
            } else {
                // Handle case for the first deposit for an epoch
                userBalanceUpdates.push(BalanceUpdate({epoch: targetEpoch, totalSharesBalance: userBalance}));
            }
        }

        // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
        Epoch storage epochData = epochs[targetEpoch];

        // Account for deposit for the specified epoch
        epochData.eligibleShares += amount;

        // Emit event for this deposit
        emit UserDepositedIntoEpoch(user, targetEpoch, amount);
    }

    /// @notice Decrease the user's share balance for the current epoch by withdrawing from
    ///         deposits from the latest eligible epoch down to the current epoch.
    function _decreaseCurrentEpochParticipation(address user, uint128 amount) internal {

        // Skip participation accounting if the it has been disabled for this address
        if (addressToIsDisabled[user]) {
            return;
        }

        // Cache the current epoch for gas efficiency.
        uint128 targetEpoch = currentEpoch;

        // Get the user's balance updates (assumed to be sorted in increasing order by epoch).
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];
        uint128 userBalance = uint128(balanceOf[user]);
        // If withdrawing, balance updates must have a non-zero length
        BalanceUpdate storage lastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 1];
        // Ensure no duplicate entries
        // Case: A new deposit has not been made for the upcoming epoch
        if (lastBalanceUpdate.epoch <= targetEpoch) {
            // Case: Last balance change was for the same epoch. Modify the last entry.
            if (lastBalanceUpdate.epoch == targetEpoch) {
                lastBalanceUpdate.totalSharesBalance = userBalance;
                // Case: Last balance change was for a past epoch. Make a new entry.
            } else {
                userBalanceUpdates.push(BalanceUpdate({epoch: targetEpoch, totalSharesBalance: userBalance}));
            }
            // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
            Epoch storage epochData = epochs[targetEpoch];
            // Account for withdrawal for the specified epoch
            epochData.eligibleShares -= amount;
        } else {
            // Case: A new deposit has been made for the upcoming epoch
            // Case: Last balance change was the only deposit and the deposit is guarranteed to be for the next epoch
            if (userBalanceUpdates.length == 1) {
                lastBalanceUpdate.totalSharesBalance = userBalance;
                // Account for withdrawal for the current epoch
                epochs[targetEpoch].eligibleShares -= amount;
                // Case: Last balance change for next epoch and second to last balance change can be for current epoch or previous ones
            } else {
                // Get second last balance update
                BalanceUpdate storage secondLastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 2];
                uint128 balanceDifference =
                    lastBalanceUpdate.totalSharesBalance - secondLastBalanceUpdate.totalSharesBalance;
                // If full amount to withdraw can't be withdrawn from the last update either modify or insert
                if (amount > balanceDifference) {
                    // If full amount to withdraw can't be withdrawn from the last update, and entry exists, then modify
                    if (secondLastBalanceUpdate.epoch == targetEpoch) {
                        // Withdraw whatever you can from the next epoch
                        lastBalanceUpdate.totalSharesBalance = userBalance;
                        // Withdraw whatever you can from the current epoch
                        secondLastBalanceUpdate.totalSharesBalance -= balanceDifference;
                        // Account for withdrawal for the next epoch
                        epochs[lastBalanceUpdate.epoch].eligibleShares -= amount;
                        // Account for withdrawal for the current epoch
                        epochs[targetEpoch].eligibleShares -= balanceDifference;
                        // If full amount to withdraw can't be withdrawn from the last update, and entry doesn't exist, then insert a new update
                    } else {
                        BalanceUpdate memory nextEpochUpdate = lastBalanceUpdate;
                        // Update the last entry to be for the current epoch (insertion)
                        lastBalanceUpdate.epoch = targetEpoch;
                        lastBalanceUpdate.totalSharesBalance = userBalance;
                        // Decrease shares of future epoch by amount withdrawn
                        nextEpochUpdate.totalSharesBalance -= amount;
                        // Append to user balance updates array to complete insertion
                        userBalanceUpdates.push(nextEpochUpdate);
                        // Withdraw whatever you can from the next epoch
                        epochs[targetEpoch + 1].eligibleShares -= amount;
                        // Account for withdrawal for the current epoch
                        epochs[targetEpoch].eligibleShares -= balanceDifference;
                    }
                    // If full amount to withdraw can be withdrawn from the next epoch, modify the entry
                } else {
                    // Withdraw full amount from next epoch
                    lastBalanceUpdate.totalSharesBalance -= amount;
                    // Account for withdrawal for the specified epoch
                    epochs[lastBalanceUpdate.epoch].eligibleShares -= amount;
                }
            }
        }
    }

    function _getEpochRangeForRewards(uint256[] calldata rewardIds)
        internal
        returns (uint128 minEpoch, uint128 maxEpoch, Reward[] memory rewardsToClaim)
    {
        // Cache array length and rewards for gas op
        uint256 rewardsLength = rewardIds.length;
        rewardsToClaim = new Reward[](rewardsLength);

        // Initialize epoch range
        minEpoch = type(uint128).max;
        maxEpoch = 0;

        // Variables to cache reward claim data as a gas optimization
        uint256 cachedRewardBucket;
        uint256 cachedClaimedRewards;

        // Variables used to preprocess rewardsIds to get a range of epochs for all rewards and mark them as claimed
        for (uint256 i = 0; i < rewardsLength; ++i) {
            // Cache management (reading and writing)
            {
                // Determine the reward bucket that this rewardId belongs in
                uint256 rewardBucket = rewardIds[i] / 256;

                if (i == 0) {
                    // Read the 256 bit bit-field to get this rewardId's claim status
                    cachedClaimedRewards = userToRewardBucketToClaimedRewards[msg.sender][rewardBucket];
                } else if (cachedRewardBucket != rewardBucket) {
                    // Write back the cached claim data to persistent storage
                    userToRewardBucketToClaimedRewards[msg.sender][cachedRewardBucket] = cachedClaimedRewards;
                    // Updated cache with the new reward bucket and rewards bit field
                    cachedRewardBucket = rewardBucket;
                    cachedClaimedRewards = userToRewardBucketToClaimedRewards[msg.sender][rewardBucket];
                }

                // The bit offset for rewardId within that bucket
                uint256 bitOffset = rewardIds[i] % 256;

                // Shift right so that the target bit is in the least significant position,
                // then check if it's 1 (indicating that it has been claimed)
                bool claimed = ((cachedClaimedRewards >> bitOffset) & 1) == 1;
                if (claimed) {
                    // If the user has already claimed this reward, revert.
                    revert RewardClaimedAlready(rewardIds[i]);
                } else {
                    // If user hasn't claimed this reward
                    // Set the bit corresponding to rewardId to true - indicating it has been claimed
                    cachedClaimedRewards |= (1 << bitOffset);
                }
            }

            // Retrieve the reward ID, start epoch, and end epoch.
            Reward storage reward = rewards[rewardIds[i]];
            uint128 startEpoch = reward.startEpoch;
            uint128 endEpoch = reward.endEpoch;
            if (startEpoch < minEpoch) {
                minEpoch = startEpoch;
            }
            if (endEpoch > maxEpoch) {
                maxEpoch = endEpoch;
            }
            // Move reward to memory for subsequent remittance logic
            rewardsToClaim[i] = Reward(reward.token, reward.rewardRate, startEpoch, endEpoch);
        }
        // Write back the final cache to persistent storage
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
            // Midpoint
            uint256 mid = (low + high + 1) >> 1;

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
        (uint256 balanceIndex, uint256 epochSharesBalance) =
            _findLatestBalanceUpdateForEpoch(minEpoch, userBalanceUpdates);
        // Cache the next balance update if it exists.
        BalanceUpdate memory nextUserBalanceUpdate;
        if (balanceIndex < userBalanceUpdatesLength - 1) {
            nextUserBalanceUpdate = userBalanceUpdates[balanceIndex + 1];
        }

        // Loop over each epoch from minEpoch to maxEpoch.
        for (uint256 epoch = minEpoch; epoch <= maxEpoch; ++epoch) {
            // Update the user's share balance if a new balance update occurs at the current epoch.
            if (balanceIndex < userBalanceUpdatesLength - 1 && epoch == nextUserBalanceUpdate.epoch) {
                epochSharesBalance = userBalanceUpdates[++balanceIndex].totalSharesBalance;
                if (balanceIndex < userBalanceUpdatesLength - 1) {
                    nextUserBalanceUpdate = userBalanceUpdates[balanceIndex + 1];
                }
            }

            // Retrieve the epoch data.
            Epoch storage epochData = epochs[epoch];
            uint256 epochIndex = epoch - minEpoch;
            // Calculate the user's fraction of shares for this epoch.
            userShareRatios[epochIndex] = epochSharesBalance.divWadDown(epochData.eligibleShares);
            // Calculate the epoch duration.
            epochDurations[epochIndex] = epochData.endTimestamp - epochData.startTimestamp;
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
        for (uint256 epoch = reward.startEpoch; epoch <= reward.endEpoch; ++epoch) {
            if (epoch < minEpoch) {
                // If user didn't have a deposit in this epoch, skip reward calculation
                continue;
            }
            uint256 epochIndex = epoch - minEpoch;
            uint256 userShareRatioForEpoch = userShareRatios[epochIndex];
            // Only process epochs where the user had a positive share ratio.
            if (userShareRatioForEpoch > 0) {
                uint256 epochReward = reward.rewardRate.mulWadDown(epochDurations[epochIndex]);
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

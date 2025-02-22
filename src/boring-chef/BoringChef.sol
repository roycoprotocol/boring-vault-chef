// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Auth, Authority} from "@solmate/auth/Auth.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {BoringSafe} from "./BoringSafe.sol";

/// @title BoringChef
/// @author Shivaansh Kapoor, Jet Jadeja, Jack Corddry
/// @notice A contract for reward accounting, retroactive distribution, and claims for share based vaults.
contract BoringChef is Auth, ERC20 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ArrayLengthMismatch();
    error NoFutureEpochRewards();
    error InvalidRewardCampaignDuration();
    error MustClaimAtLeastOneReward();
    error CannotClaimFutureReward();
    error RewardClaimedAlready(uint256 rewardId);
    error CannotDisableRewardAccrualMoreThanOnce();
    error CannotEnableRewardAccrualMoreThanOnce();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event EpochStarted(uint256 indexed epoch, uint256 eligibleShares, uint256 startTimestamp);
    event UserRewardsClaimed(address indexed user, address indexed token, uint256 rewardId, uint256 amount);
    event RewardsDistributed(
        address indexed token, uint256 indexed startEpoch, uint256 indexed endEpoch, uint256 amount, uint256 rewardId
    );
    event UserDepositedIntoEpoch(address indexed user, uint256 indexed epoch, uint256 shareAmount);
    event UserWithdrawnFromEpoch(address indexed user, uint256 indexed epoch, uint256 shareAmount);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @dev A record of a user's balance changing at a specific epoch
    struct BalanceUpdate {
        /// @dev The epoch in which the deposit was made
        uint48 epoch;
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
        /// @dev The epoch at which the reward starts
        uint48 startEpoch;
        /// @dev The epoch at which the reward ends
        uint48 endEpoch;
        /// @dev The token being rewarded
        address token;
        /// @dev The rate at which the reward token is distributed per second
        uint256 rewardRate;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev A contract to hold rewards to make sure the BoringVault doesn't spend them
    BoringSafe public immutable boringSafe;

    /// @dev The current epoch
    uint48 public currentEpoch;

    /// @dev A record of all epochs
    mapping(uint48 => Epoch) public epochs;

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
        // Deploy the BoringSafe that the BoringChef will use for escrowing distributed rewards.
        boringSafe = new BoringSafe();
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD DISTRIBUTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Disable reward accrual for a given address
    /// @dev Can only be called by an authorized address
    function disableRewardAccrual(address user) external requiresAuth {
        // Check that reward accrual hasn't been disabled already
        if (addressToIsDisabled[user] == true) {
            revert CannotDisableRewardAccrualMoreThanOnce();
        }
        // Decrease the user's participation by their entire balance
        // They won't be eligible for rewards from the current epoch onwards unless they are reenabled
        _decreaseCurrentAndNextEpochParticipation(user, uint128(balanceOf[user]));
        addressToIsDisabled[user] = true;
    }

    /// @notice Enable reward accrual for a given address
    /// @dev Can only be called by an authorized address
    function enableRewardAccrual(address user) external requiresAuth {
        // Check that reward accrual hasn't been enabled already
        if (addressToIsDisabled[user] == false) {
            revert CannotEnableRewardAccrualMoreThanOnce();
        }
        // Increase the user's participation by their entire balance
        // Their entire balance will be eligible for rewards from the next epoch onwards
        addressToIsDisabled[user] = false;
        _increaseNextEpochParticipation(user, uint128(balanceOf[user]));
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
        uint48[] calldata startEpochs,
        uint48[] calldata endEpochs
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
            rewards[maxRewardId] = Reward({
                startEpoch: startEpochs[i],
                endEpoch: endEpochs[i],
                token: tokens[i],
                // Calculate the reward rate over the epoch period.
                // Consider the case where endEpochData.endTimestamp == startEpochData.startTimestamp
                rewardRate: amounts[i].divWadDown(endEpochData.endTimestamp - startEpochData.startTimestamp)
            });

            // Transfer the reward tokens to the BoringSafe.
            ERC20(tokens[i]).safeTransferFrom(msg.sender, address(boringSafe), amounts[i]);

            // Emit an event for this reward distribution.
            emit RewardsDistributed(tokens[i], startEpochs[i], endEpochs[i], amounts[i], maxRewardId++);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claims rewards (specified as rewardIds) for the caller.
    /// @param rewardIds The rewardIds to claim rewards for.
    function claimRewards(uint256[] calldata rewardIds) external {
        // Get the epoch range for all rewards to claim and the corresponding Reward structs.
        (uint48 minEpoch, uint48 maxEpoch, Reward[] memory rewardsToClaim) = _getEpochRangeForRewards(rewardIds);

        // Fetch the caller's balance update history.
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[msg.sender];
        uint48 firstEpochDeposited = userBalanceUpdates[0].epoch;
        // Use the later of the minEpoch from rewards or the user's first deposit epoch.
        if (firstEpochDeposited > minEpoch) {
            minEpoch = firstEpochDeposited;
        }

        // Precompute the user's share ratios and epoch durations from minEpoch to maxEpoch.
        (uint256[] memory userShareRatios, uint256[] memory epochDurations) =
            _computeUserShareRatiosAndDurations(minEpoch, maxEpoch, userBalanceUpdates);

        // We'll accumulate rewards per token. Since we cannot create a mapping in memory,
        // we use two parallel arrays to record unique tokens and their total reward amounts.
        uint256 uniqueCount = 0;
        address[] memory uniqueTokens = new address[](rewardIds.length);
        uint256[] memory tokenAmounts = new uint256[](rewardIds.length);

        // For each reward campaign, calculate the rewards owed and add the amount into
        // the corresponding unique token's bucket.
        for (uint256 i = 0; i < rewardIds.length; ++i) {
            // Calculate the total rewards owed for this reward campaign.
            uint256 rewardsOwed = _calculateRewardsOwed(rewardsToClaim[i], minEpoch, userShareRatios, epochDurations);

            if (rewardsOwed > 0) {
                // Check if this reward token was already encountered.
                bool found = false;
                for (uint256 j = 0; j < uniqueCount; ++j) {
                    if (uniqueTokens[j] == rewardsToClaim[i].token) {
                        tokenAmounts[j] += rewardsOwed;
                        found = true;
                        break;
                    }
                }
                // If not found, add a new entry.
                if (!found) {
                    uniqueTokens[uniqueCount] = rewardsToClaim[i].token;
                    tokenAmounts[uniqueCount] = rewardsOwed;
                    uniqueCount++;
                }

                {
                    // Emit the reward-claim event per reward campaign.
                    uint256 rewardId = rewardIds[i];

                    emit UserRewardsClaimed(msg.sender, rewardsToClaim[i].token, rewardId, rewardsOwed);
                }
            }
        }

        // Finally, do one transfer per unique reward token.
        for (uint256 i = 0; i < uniqueCount; ++i) {
            boringSafe.transfer(uniqueTokens[i], msg.sender, tokenAmounts[i]);
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

        // Account for the transfer for the sender and forfeit incentives for current epoch for msg.sender
        _decreaseCurrentAndNextEpochParticipation(msg.sender, uint128(amount));

        // Account for the transfer for the recipient and transfer incentives for next epoch onwards to "to"
        _increaseNextEpochParticipation(to, uint128(amount));
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

        // Account for the transfer for the sender and forfeit incentives for current epoch for "from"
        _decreaseCurrentAndNextEpochParticipation(from, uint128(amount));

        // Account for the transfer for the recipient and transfer incentives for next epoch onwards to "to"
        _increaseNextEpochParticipation(to, uint128(amount));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all balance updates for a user.
    function getBalanceUpdates(address user) external view returns (BalanceUpdate[] memory) {
        return balanceUpdates[user];
    }

    /// @notice Get a user's reward balance for a given reward ID.
    /// @param user The user to get the reward balance for.
    /// @param rewardId The ID of the reward to get the balance for.
    function getUserRewardBalance(address user, uint256 rewardId) external view returns (uint256) {
        // Fetch all balance change updates for the caller.
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];

        // Retrieve the reward ID, start epoch, and end epoch.
        Reward storage reward = rewards[rewardId];

        // Initialize a local accumulator for the total reward owed.
        uint256 rewardsOwed = 0;

        // We want to iterate over the epoch range [startEpoch..endEpoch],
        // summing up the user's share of tokens from each epoch.
        for (uint48 epoch = reward.startEpoch; epoch <= reward.endEpoch; epoch++) {
            // Determine the user's share balance during this epoch.
            (, uint128 userBalanceAtEpoch) = _findLatestBalanceUpdateForEpoch(epoch, userBalanceUpdates);

            // If the user is owed rewards for this epoch, remit them
            if (userBalanceAtEpoch > 0) {
                Epoch storage epochData = epochs[epoch];
                // Compute user fraction = userBalance / totalShares.
                uint256 userFraction = uint256(userBalanceAtEpoch).divWadDown(epochData.eligibleShares);

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
    /// @dev Returns the user's eligible balance for the current epoch, not the next epoch
    function getUserEligibleBalance(address user) external view returns (uint128) {
        // Find the user's balance at the current epoch
        (, uint128 userBalance) = _findLatestBalanceUpdateForEpoch(currentEpoch, balanceUpdates[user]);
        return userBalance;
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
        _increaseNextEpochParticipation(to, uint128(amount));
    }

    /// @notice Burn shares
    /// @dev This function is overridden from the ERC20 implementation to account for incentives.
    function _burn(address from, uint256 amount) internal override(ERC20) {
        // Burn the shares from the depositor
        super._burn(from, amount);

        // Mark this deposit eligible for incentives earned from the next epoch onwards
        _decreaseCurrentAndNextEpochParticipation(from, uint128(amount));
    }

    /// @dev Roll over to the next epoch.
    /// @dev Should be called on every boring vault rebalance.
    function _rollOverEpoch() internal {
        // Cache current epoch for gas savings
        uint48 currEpoch = currentEpoch++;

        // Get the current and next epoch data.
        Epoch storage currentEpochData = epochs[currEpoch];
        Epoch storage nextEpochData = epochs[++currEpoch];

        // Update the current epoch's end timestamp and the next epoch's start timestamp.
        currentEpochData.endTimestamp = uint64(block.timestamp);
        nextEpochData.startTimestamp = uint64(block.timestamp);

        // Update the eligible shares for the next epoch by rolling them over.
        nextEpochData.eligibleShares += currentEpochData.eligibleShares;

        // Emit event for epoch start
        emit EpochStarted(currEpoch, nextEpochData.eligibleShares, block.timestamp);
    }

    /// @notice Increase the user's share balance for the next epoch
    function _increaseNextEpochParticipation(address user, uint128 amount) internal {
        // Skip participation accounting if it has been disabled for this address
        if (addressToIsDisabled[user]) return;

        // Cache next epoch for gas op
        uint48 nextEpoch = currentEpoch + 1;

        // Handle updating the balance accounting for this user
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];
        if (userBalanceUpdates.length == 0) {
            // If there are no balance updates, create a new one
            userBalanceUpdates.push(BalanceUpdate({epoch: nextEpoch, totalSharesBalance: amount}));
        } else {
            // Get the last balance update
            BalanceUpdate storage lastBalanceUpdate = userBalanceUpdates[userBalanceUpdates.length - 1];
            // Ensure no duplicate entries
            if (lastBalanceUpdate.epoch == nextEpoch) {
                // Handle case for multiple deposits into an epoch
                lastBalanceUpdate.totalSharesBalance += amount;
            } else {
                // Handle case for the first deposit for an epoch
                userBalanceUpdates.push(
                    BalanceUpdate({
                        epoch: nextEpoch,
                        // Add the specified amount to the last balance update's total shares
                        totalSharesBalance: (lastBalanceUpdate.totalSharesBalance + amount)
                    })
                );
            }
        }

        // Get the epoch data for the current epoch and next epoch (epoch to deposit for)
        Epoch storage epochData = epochs[nextEpoch];
        // Account for deposit for the specified epoch
        epochData.eligibleShares += amount;

        // Emit event for this deposit
        emit UserDepositedIntoEpoch(user, nextEpoch, amount);
    }

    /// @notice Decrease the user's share balance for the current epoch.
    /// @dev If the user has a deposit for the next epoch, it will withdraw as much as possible from the next epoch and the rest from the current.
    function _decreaseCurrentAndNextEpochParticipation(address user, uint128 amount) internal {
        // Skip participation accounting if it has been disabled for this address.
        if (addressToIsDisabled[user]) return;

        // Cache the current epoch, next epoch, and user's balance.
        uint48 currEpoch = currentEpoch;
        uint48 nextEpoch = currEpoch + 1;

        // Cache the user's balance updates and its length.
        BalanceUpdate[] storage userBalanceUpdates = balanceUpdates[user];
        uint256 balanceUpdatesLength = userBalanceUpdates.length;
        // It is assumed that len > 0 when withdrawing.
        BalanceUpdate storage lastBalanceUpdate = userBalanceUpdates[balanceUpdatesLength - 1];

        // CASE 1: No deposit for the next epoch.
        if (lastBalanceUpdate.epoch <= currEpoch) {
            // CASE 1.1: Last balance update is for the current epoch.
            if (lastBalanceUpdate.epoch == currEpoch) {
                // If already updated for the current epoch, just update the total shares to reflect the decrease.
                lastBalanceUpdate.totalSharesBalance -= amount;
                // CASE 1.2: Last balance update is a previous epoch. Create a new update to preserve order of updates.
            } else {
                // Append a new update for the current epoch.
                userBalanceUpdates.push(
                    BalanceUpdate({
                        epoch: currEpoch,
                        // Deduct the amount from the last balance update by the shares to decrease by
                        totalSharesBalance: (lastBalanceUpdate.totalSharesBalance - amount)
                    })
                );
            }
            // Account for withdrawal in the current epoch.
            epochs[currEpoch].eligibleShares -= amount;
            // Emit event for this withdrawal.
            emit UserWithdrawnFromEpoch(user, currEpoch, amount);
            return;
        }

        // CASE 2: Only deposit made is for the next epoch.
        if (balanceUpdatesLength == 1) {
            // If there is only one balance update, it has to be for the next epoch. Update it and adjust the epoch's eligible shares.
            lastBalanceUpdate.totalSharesBalance -= amount;
            epochs[nextEpoch].eligibleShares -= amount;
            // Emit event for this withdrawal
            emit UserWithdrawnFromEpoch(user, nextEpoch, amount);
            return;
        }

        // Get the second-to-last update.
        BalanceUpdate storage secondLastBalanceUpdate = userBalanceUpdates[balanceUpdatesLength - 2];
        // The amount deposited for the next epoch.
        uint128 amountDepositedIntoNextEpoch =
            lastBalanceUpdate.totalSharesBalance - secondLastBalanceUpdate.totalSharesBalance;

        // CASE 3: Deposit Made for the next epoch and the full withdrawal amount cannot be removed solely from the last update.
        if (amount > amountDepositedIntoNextEpoch) {
            // The amount deposited into the next epoch will be withdrawn completely in this case: amountDepositedIntoNextEpoch == amountToWithdrawFromNextEpoch.
            // The rest of the withdrawal amount will be deducted from the current epoch.
            uint128 amountToWithdrawFromCurrentEpoch = (amount - amountDepositedIntoNextEpoch);
            if (secondLastBalanceUpdate.epoch == currEpoch) {
                // Withdraw the amount left over from withdrawing from the next epoch from the current epoch.
                secondLastBalanceUpdate.totalSharesBalance -= amountToWithdrawFromCurrentEpoch;
                epochs[currEpoch].eligibleShares -= amountToWithdrawFromCurrentEpoch;
                // Withdraw the amount that was deposited into the next epoch completely
                epochs[nextEpoch].eligibleShares -= amountDepositedIntoNextEpoch;
                // Since the next epoch's deposit was completely cleared, we can pop the next epoch's (last) update off.
                userBalanceUpdates.pop();
            } else {
                // Update the last entry to be for the current epoch.
                lastBalanceUpdate.epoch = currEpoch;
                lastBalanceUpdate.totalSharesBalance -= amount;
                // Withdraw the amount to withdraw from the current epoch from total eligible shared.
                epochs[currEpoch].eligibleShares -= amountToWithdrawFromCurrentEpoch;
                // Withdraw the full amount deposited into the next epoch.
                epochs[nextEpoch].eligibleShares -= amountDepositedIntoNextEpoch;
            }
            // Emit event for the withdrawals.
            emit UserWithdrawnFromEpoch(user, nextEpoch, amountDepositedIntoNextEpoch);
            emit UserWithdrawnFromEpoch(user, currEpoch, amountToWithdrawFromCurrentEpoch);
            return;
            // CASE 4: The full amount can be withdrawn from the next epoch. Modify the next epoch (last) update.
        } else {
            lastBalanceUpdate.totalSharesBalance -= amount;
            epochs[nextEpoch].eligibleShares -= amount;
            // Emit event for this withdrawal.
            emit UserWithdrawnFromEpoch(user, nextEpoch, amount);
            return;
        }
    }

    function _getEpochRangeForRewards(uint256[] calldata rewardIds)
        internal
        returns (uint48 minEpoch, uint48 maxEpoch, Reward[] memory rewardsToClaim)
    {
        // Cache array length, rewards, and highest claimable rewardID for gas op.
        uint256 rewardsLength = rewardIds.length;
        // Check that the user is claiming at least 1 reward.
        if (rewardsLength == 0) {
            revert MustClaimAtLeastOneReward();
        }
        rewardsToClaim = new Reward[](rewardsLength);
        uint256 highestClaimaibleRewardId = maxRewardId - 1;

        // Initialize epoch range
        minEpoch = type(uint48).max;
        maxEpoch = 0;

        // Variables to cache reward claim data as a gas optimization.
        uint256 cachedRewardBucket;
        uint256 cachedClaimedRewards;

        // Variables used to preprocess rewardsIds to get a range of epochs for all rewards and mark them as claimed.
        for (uint256 i = 0; i < rewardsLength; ++i) {
            // Check if this rewardID exists
            if (rewardIds[i] > highestClaimaibleRewardId) {
                revert CannotClaimFutureReward();
            }

            // Cache management (reading and writing)
            {
                // Determine the reward bucket that this rewardId belongs in.
                uint256 rewardBucket = rewardIds[i] / 256;

                if (i == 0) {
                    // Initialize cache with the reward bucket and bit field
                    cachedRewardBucket = rewardBucket;
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

            // Retrieve and cache the reward ID, start epoch, and end epoch.
            rewardsToClaim[i] = rewards[rewardIds[i]];
            if (rewardsToClaim[i].startEpoch < minEpoch) {
                minEpoch = rewardsToClaim[i].startEpoch;
            }
            if (rewardsToClaim[i].endEpoch > maxEpoch) {
                maxEpoch = rewardsToClaim[i].endEpoch;
            }
        }
        // Write back the final cache to persistent storage
        userToRewardBucketToClaimedRewards[msg.sender][cachedRewardBucket] = cachedClaimedRewards;
    }

    /// @dev Computes the user's share ratios and epoch durations for every epoch between minEpoch and maxEpoch.
    /// @param minEpoch The starting epoch.
    /// @param maxEpoch The ending epoch.
    /// @param userBalanceUpdates The user's balance update history.
    /// @return userShareRatios An array of the user’s fraction of shares for each epoch.
    /// @return epochDurations An array of the epoch durations (endTimestamp - startTimestamp) for each epoch.
    function _computeUserShareRatiosAndDurations(
        uint48 minEpoch,
        uint48 maxEpoch,
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
        for (uint48 epoch = minEpoch; epoch <= maxEpoch; ++epoch) {
            // Update the user's share balance if a new balance update occurs at the current epoch.
            if (balanceIndex < userBalanceUpdatesLength - 1 && epoch == nextUserBalanceUpdate.epoch) {
                epochSharesBalance = nextUserBalanceUpdate.totalSharesBalance;
                balanceIndex++;
                if (balanceIndex < userBalanceUpdatesLength - 1) {
                    nextUserBalanceUpdate = userBalanceUpdates[balanceIndex + 1];
                }
            }

            // Retrieve the epoch data.
            Epoch storage epochData = epochs[epoch];
            uint128 eligibleShares = epochData.eligibleShares;
            // Only calculate ratio and duration if there are eligible shares. Else leave those set to 0.
            if (eligibleShares != 0) {
                uint256 epochIndex = epoch - minEpoch;
                // Calculate the user's fraction of shares for this epoch.
                userShareRatios[epochIndex] = epochSharesBalance.divWadDown(eligibleShares);
                // Calculate the epoch duration.
                epochDurations[epochIndex] = epochData.endTimestamp - epochData.startTimestamp;
            }
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
    /// @param userBalanceUpdates The historical balance updates for a user, sorted ascending by epoch.
    /// @return The latest balance update index and balance for the given epoch.
    function _findLatestBalanceUpdateForEpoch(uint48 epoch, BalanceUpdate[] storage userBalanceUpdates)
        internal
        view
        returns (uint256, uint128)
    {
        // No balance changes at all
        if (userBalanceUpdates.length == 0) {
            return (0, 0);
        }

        // If the requested epoch is before the first recorded epoch,
        // assume the user had 0 shares.
        if (epoch < userBalanceUpdates[0].epoch) {
            return (epoch, 0);
        }

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

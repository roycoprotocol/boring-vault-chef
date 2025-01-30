// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

/// @title BoringChef
contract BoringChef is ERC20, Auth {
    using SafeTransferLib for ERC20;

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
            rewardTokenDistributionRate: amount / (endEpochData.endTimestamp - startEpochData.startTimestamp),
            startEpoch: startEpoch,
            endEpoch: endEpoch
        });

        // Update the max reward ID
        maxRewardId = rewardId + 1;

        // Transfer the reward tokens to the contract.
        ERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // TODO: do we need to update the current epoch here?
        // epochs[currentEpoch].endTimestamp = block.timestamp;
        // epochs[currentEpoch++].startTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                       REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim rewards for a given array of tokens and epoch ranges.
    /// @dev We do this by calculating the rewards owed to the user for each token and epoch range.
    /// @param rewardIDs The IDs of the rewards to claim.
    /// @param rewardIDEpochRanges The epoch ranges for the rewards to claim.
    function claimRewards(
        uint256[] calldata rewardIDs,
        uint256[2][] calldata rewardIDEpochRanges
    ) external {
        // Store the user's balance changes.
        BalanceChangeUpdate[] memory balanceChangeUpdates = userToBalanceChanges[msg.sender]; 

        // Initialize the rewards owed and the current update index.
        uint256 rewardsOwed = 0;

        // Iterate over the supplied reward IDs.
        for (uint256 i = 0; i < rewardIDs.length; i++) {
            // Initialize the relevant balance changes array.
            uint256[] memory relevantBalanceChanges = new uint256[](balanceChangeUpdates.length);

            // Iterate over the balanceChangeUpdates array to find relevant epochs.
            uint256 relevantIndex = 0;
            for (uint256 k = 0; k < balanceChangeUpdates.length; k++) {
                uint256 epoch = balanceChangeUpdates[k].epoch;
                
                // Check if the epoch is directly before the epoch range or within the range.
                if (epoch >= rewardIDEpochRanges[i][0] && epoch <= rewardIDEpochRanges[i][1]) {
                    relevantBalanceChanges[relevantIndex] = k;
                    relevantIndex++;
                }
            }
            // Resize the relevantBalanceChanges array to the actual number of relevant epochs found.
            assembly { mstore(relevantBalanceChanges, relevantIndex) }

            for (uint256 j = 0; j < rewardIDEpochRanges[i].length; j++) {
                
            }
        }

        // initialize currentUpdateIndex
        // for(i in rewardIds) {
        //         // calculate the balance at this specific epoch using binary search
        //         // be careful about epoch updates during the epoch range specified
        //     for(y in rewardIDEpochs) {
        //         // calculate the amount of reward points owed to the user for this specific epoch 
        //         // we can do this by dividing (user shares * wad) by total shares 
        //         // multiply reward token amount per epoch by this fraction
        //         // memorize the values potentially ??? 
        //         // increase our current indexpointer -- this is a value reprensenting
        //         // our current epoch because we need to essentially check whether the balance changed 
        //         // from this
        //     }
        // }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL REWARD CLAIMING LOGIC
    //////////////////////////////////////////////////////////////*/

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


// /// @title BoringChef
// contract PussyDistrubitor {

//     /*//////////////////////////////////////////////////////////////
//                                 STORAGE
//     //////////////////////////////////////////////////////////////*/

//     struct Epoch {
//         uint256 eligibleShares;
//         uint256 startTimestamp;
//         uint256 endTimestamp;
//     }

//     mapping(uint256 epoch => Epoch) public epochs; //TODO: see if array is better
//     uint256 public currentEpoch;

//     struct BalanceChangeUpdate {
//         uint256 epoch;
//         uint256 totalDeposits;
//     }
//     mapping(address user => BalanceChangeUpdate[]) public userToDepositUpdates; // TODO: Consider outsourcing the binary search part of this to frontend. Could pass an array index in with the function params and ensure the previous entry is before and the next entry is after

//     struct Reward {
//         address token;
//         uint256 rewardRate;
//         uint256 startEpoch;
//         uint256 endEpoch;
//     }

//     //TODO call on deposit and anytime a user gains tokens
//     function _increaseUpcomingEpochParticipation(uint256 amount, address user) internal { //TODO: rename to amount of shares or sumn
//         Epoch storage currentEpoch = epochs[currentEpoch];
//         Epoch storage targetEpoch = epochs[currentEpoch + 1];

//         targetEpoch.eligibleShares = targetEpoch.eligibleShares ? targetEpoch.eligibleShares + amount : currentEpoch.eligibleShares + amount;

//         // the user's new balance (add amount to existing user shares)
//         uint newNumShares = 12345;
//         // TODO: make sure that balanceChangeUpdates are unique on epochID;
//         userToDepositUpdates[user].push(BalanceChangeUpdate(currentEpoch + 1), newNumShares);
//     }

//     //TODO call on withdraw and anytime a user loses tokens
//     function _decreaseCurrentEpochParticipation(uint256 amount, address user) internal {
//         Epoch storage currentEpoch = epochs[currentEpoch];

//         currentEpoch.eligibleShares -= amount;

//         uint newNumShares = 12345; // TODO: connect this to token logic
//         // TODO: make sure that balanceChangeUpdates are unique on epochID;
//         userToDepositUpdates[user].push(BalanceChangeUpdate(currentEpoch), newNumShares);
//     }

//     // TODO: either require call this on rebalance, or split into a rebalance call and a rewards call
//     function distributeRewards(uint256 amount, address token, uint256 startEpoch, uint256 endEpoch) public {
//         require (endEpoch <= currentEpoch, "No rewards on future epochs");

//         Epoch storage startEpoch = epochs[startEpoch];
//         Epoch storage endEpoch = epochs[endEpoch];

//         Reward.rewardRate = amount / (endEpoch.endTimestamp - startEpoch.startTimestamp); //TODO prevent 2x epochs in one block, zeroing this

//         epochs[currentEpoch].endTimestamp = block.timestamp;
//         epochs[currentEpoch++].startTimestamp = block.timestamp;

//         //TODO: ERC20(token).safeTransferFrom(msg.sender, address(this), amount);
//     }

//     function claim(uint256[] rewardIDs, uint256[2][] rewardIDEpochs) public { //TODO: batch claim
//         BalanceChangeUpdate[] storage balanceChangeUpdates = userToDepositUpdates[msg.sender];

//         uint256 memory rewardsOwed = 0;
//         uint256 memory currentUpdateIndex = 0;
//         uint256 memory epoch = rewardID.startEpoch;

//         BalanceChangeUpdate storage currentUpdate = balanceChangeUpdates[currentUpdateIndex];

//         // initialize currentUpdateIndex
//         // for(i in rewardIds) {
//         //         // calculate the balance at this specific epoch using binary search
//         //         // be careful about epoch updates during the epoch range specified
//         //     for(y in rewardIDEpochs) {
//         //         // calculate the amount of reward points owed to the user for this specific epoch
//         //         // we can do this by dividing (user shares * wad) by total shares
//         //         // multiply reward token amount per epoch by this fraction
//         //         // memorize the values potentially ???
//         //         // increase our current indexpointer -- this is a value reprensenting
//         //         // our current epoch because we need to essentially check whether the balance changed
//         //         // from this
//         //     }
//         // }
//     }

// }

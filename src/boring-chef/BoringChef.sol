// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {ERC20} from "@solmate/tokens/ERC20.sol";

/// @title BoringChef
contract BoringChef is ERC20 {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NoFutureEpochRewards();

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
        /// @dev The rate at which the reward is distributed per epoch
        /// This is the total amount of reward tokens distributed per epoch
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
    mapping(address user => BalanceChangeUpdate[]) public userToBalanceChanges;

    /// @dev Maps rewards to reward IDs
    mapping(uint256 rewardId => Reward) public rewards;
    uint256 public maxRewardId;

    /// @dev Maps users to an array of booleans representing whether they have claimed rewards for a given epoch
    /// TODO let's pack this into an array of uint256s or whatever is most efficient
    mapping(address user => mapping(uint256 rewardId => bool)) public userToClaimedEpochs;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol, _decimals) {}

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function distributeRewards(uint256 amount, address token, uint256 startEpoch, uint256 endEpoch) external {
        // This
        require(endEpoch <= currentEpoch, "No rewards on future epochs");
        // require (endEpoch <= currentEpoch, "No rewards on future epochs");

        // Epoch storage startEpoch = epochs[startEpoch];
        // Epoch storage endEpoch = epochs[endEpoch];

        // Reward.rewardRate = amount / (endEpoch.endTimestamp - startEpoch.startTimestamp); //TODO prevent 2x epochs in one block, zeroing this

        // epochs[currentEpoch].endTimestamp = block.timestamp;
        // epochs[currentEpoch++].startTimestamp = block.timestamp;

        // //TODO: ERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    // function claim(
    //     uint256[] calldata rewardIDs,
    //     uint256[2][] calldata rewardIDEpochs
    // ) external {
    //     BalanceChangeUpdate[] storage balanceChangeUpdates = userToDepositUpdates[msg.sender];

    //     uint256 memory rewardsOwed = 0;
    //     uint256 memory currentUpdateIndex = 0;
    //     uint256 memory epoch = rewardIDs.startEpoch;

    //     BalanceChangeUpdate storage currentUpdate = balanceChangeUpdates[currentUpdateIndex];

    //     // initialize currentUpdateIndex
    //     // for(i in rewardIds) {
    //     //         // calculate the balance at this specific epoch using binary search
    //     //         // be careful about epoch updates during the epoch range specified
    //     //     for(y in rewardIDEpochs) {
    //     //         // calculate the amount of reward points owed to the user for this specific epoch
    //     //         // we can do this by dividing (user shares * wad) by total shares
    //     //         // multiply reward token amount per epoch by this fraction
    //     //         // memorize the values potentially ???
    //     //         // increase our current indexpointer -- this is a value reprensenting
    //     //         // our current epoch because we need to essentially check whether the balance changed
    //     //         // from this
    //     //     }
    //     // }
    // }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _increaseUpcomingEpochParticipation(uint256 amount, address user) internal {
        Epoch storage currentEpochData = epochs[currentEpoch];
        Epoch storage targetEpoch = epochs[currentEpoch + 1];

        targetEpoch.eligibleShares = targetEpoch.eligibleShares > 0
            ? targetEpoch.eligibleShares + amount
            : currentEpochData.eligibleShares + amount;

        // the user's new balance (add amount to existing user shares)
        uint256 newNumShares = 12345;
        // TODO: make sure that balanceChanges are unique on epochID;
        userToBalanceChanges[user].push(
            BalanceChangeUpdate({epoch: currentEpoch + 1, totalSharesBalance: newNumShares})
        );
    }

    function _decreaseCurrentEpochParticipation(uint256 amount, address user) internal {
        Epoch storage currentEpochData = epochs[currentEpoch];

        currentEpochData.eligibleShares -= amount;

        uint256 newNumShares = 12345; // TODO: connect this to token logic
        // TODO: make sure that balanceChanges are unique on epochID;
        userToBalanceChanges[user].push(BalanceChangeUpdate({epoch: currentEpoch, totalSharesBalance: newNumShares}));
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

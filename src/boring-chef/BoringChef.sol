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
    mapping(address user => BalanceUpdate[]) public userToBalanceUpdates;

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
    //     BalanceUpdate[] storage BalanceUpdates = userToDepositUpdates[msg.sender];

    //     uint256 memory rewardsOwed = 0;
    //     uint256 memory currentUpdateIndex = 0;
    //     uint256 memory epoch = rewardIDs.startEpoch;

    //     BalanceUpdate storage currentUpdate = BalanceUpdates[currentUpdateIndex];

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

    function _mint(address to, uint256 amount) internal override {
        // Mint the shares to the depositor
        super._mint(to, amount);
        // Mark this deposit eligible for incentives earned from the next epoch onwards
        _increaseUpcomingEpochParticipation(to, amount);
    }

    function _burn(address from, uint256 amount) internal override {
        // Burn the shares from the depositor
        super._burn(from, amount);
    }

    function _increaseUpcomingEpochParticipation(address user, uint256 shareAmount) internal {
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
            ? upcomingEpochData.eligibleShares + shareAmount
            : currentEpochData.eligibleShares + shareAmount;

        // Get the post-entry share balance of the user
        uint256 resultingShareBalance = balanceOf[user];

        // Account for the entry for the user
        BalanceUpdate[] storage balanceUpdates = userToBalanceUpdates[user];
        BalanceUpdate storage lastBalanceUpdate = balanceUpdates[balanceUpdates.length - 1];
        if (lastBalanceUpdate.epoch == upcomingEpoch) {
            // If user already deposited into the next epoch, update the existing entry
            lastBalanceUpdate.totalSharesBalance = resultingShareBalance;
        } else {
            // If user hasn't deposited into the next epoch, make a new entry
            balanceUpdates.push(BalanceUpdate({epoch: upcomingEpoch, totalSharesBalance: resultingShareBalance}));
        }
    }

    // function _decreaseCurrentEpochParticipation(uint256 amount, address user) internal {
    //     Epoch storage currentEpoch = epochs[currentEpoch];

    //     currentEpoch.eligibleShares -= amount;

    //     uint256 newNumShares = 12345; // TODO: connect this to token logic
    //     // TODO: make sure that balanceChanges are unique on epochID;
    //     userToBalanceUpdates[user].push(BalanceUpdate({epoch: currentEpoch, totalSharesBalance: newNumShares}));
    // }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

import {Test, stdStorage, StdStorage, console} from "@forge-std/Test.sol";
import {BoringVault} from "src/base/BoringVault.sol";
import {BoringChef} from "src/boring-chef/BoringChef.sol";
import {TellerWithMultiAssetSupport} from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import {AccountantWithRateProviders} from "src/base/Roles/AccountantWithRateProviders.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FixedPointMathLib} from "lib/solmate/src/utils/FixedPointMathLib.sol";

contract BoringVaultTest is Test {
    using stdStorage for StdStorage;
    using FixedPointMathLib for uint256;

    BoringVault public boringVault;
    BoringChef public boringChef;
    TellerWithMultiAssetSupport public teller;
    RolesAuthority public rolesAuthority;
    AccountantWithRateProviders public accountant;
    MockERC20 public token;

    // Roles
    uint8 public constant ADMIN_ROLE = 1;
    uint8 public constant MINTER_ROLE = 7;
    uint8 public constant BURNER_ROLE = 8;
    uint8 public constant DEPOSITOR_ROLE = 9;
    // (other roles if needed…)

    // Test addresses
    address public owner;
    address public testUser;
    address public anotherUser;

    function setUp() external {
        // Set up test addresses.
        owner = address(this); // the test contract is the owner
        testUser = vm.addr(1);
        anotherUser = vm.addr(2);

        // Deploy a mock ERC20 token to serve as the deposit (share) token.
        token = new MockERC20("Test Token", "TEST", 18);

        // Mint an initial balance to the owner and test users.
        token.mint(owner, 1_000e18);
        token.mint(testUser, 1_000e18);
        token.mint(anotherUser, 1_000e18);

        // (Optional) Deploy a standalone BoringChef instance.
        boringChef = new BoringChef(owner, "BoringChef", "BCHEF", 18);

        // Deploy the BoringVault.
        // BoringVault's constructor takes (address _shareToken, string memory _name, string memory _symbol, uint8 _decimals)
        boringVault = new BoringVault(address(this), "TestBoringVault", "TBV", 18);

        // Deploy a dummy accountant.
        // If you have a proper mock, deploy it here; for now we use address(0) as a placeholder.
        // In a real test you should replace address(0) with a deployed mock that implements AccountantWithRateProviders.
        accountant = new AccountantWithRateProviders(address(this), address(boringVault), address(0), 1e18, address(token), 1000, 1000, 1, 0, 0);

        // Deploy the TellerWithMultiAssetSupport.
        // Its constructor requires (_owner, _vault, _accountant, _weth). For testing, you can pass token as a placeholder for the native wrapper.
        teller = new TellerWithMultiAssetSupport(owner, address(boringVault), address(accountant), address(token));

        // Deploy a RolesAuthority contract. Here we use the test contract as the authority owner.
        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));

        // Set up role capabilities for the vault.
        rolesAuthority.setRoleCapability(MINTER_ROLE, address(boringVault), BoringVault.enter.selector, true);
        rolesAuthority.setRoleCapability(BURNER_ROLE, address(boringVault), BoringVault.exit.selector, true);

        // Grant owner ADMIN_ROLE.
        rolesAuthority.setUserRole(owner, ADMIN_ROLE, true);

        // Give the teller MINTER and BURNER roles.
        rolesAuthority.setUserRole(address(teller), MINTER_ROLE, true);
        rolesAuthority.setUserRole(address(teller), BURNER_ROLE, true);

        // Set the authority for the vault and the teller.
        boringVault.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);

        // (Optional) Update asset data on the teller so that the deposit token is allowed for deposits and withdrawals.
        teller.updateAssetData(ERC20(address(token)), true, true, 0);

        // Log setup details.
        // console.log("Owner:", owner);
        // console.log("TestUser:", testUser);
        // console.log("AnotherUser:", anotherUser);
        // console.log("Token address:", address(token));
        // console.log("BoringVault address:", address(boringVault));
        // console.log("BoringChef address:", address(boringChef));
        // console.log("Teller address:", address(teller));
        // console.log("RolesAuthority address:", address(rolesAuthority));
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that a single deposit works.
    function testSingleDeposit() external {
        // Assume deposit amount of 100 tokens.
        uint256 depositAmount = 100e18;

        // Have address(this) approve the vault to spend the deposit tokens.
        // (Assuming that address(this) already has an initial balance; see setUp in your test contract.)
        token.approve(address(boringVault), depositAmount);

        // Call the deposit function on the teller.
        // The third parameter (minimumMint) is set to 0 for simplicity.
        uint256 sharesMinted = teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Check that the vault's share balance for address(this) increased correctly.
        // The balanceOf function inherited from ERC20 should now return sharesMinted for address(this).
        assertEq(boringVault.balanceOf(address(this)), sharesMinted, "User share balance in vault is incorrect.");

        // Assuming the rate is 1:1, then the shares minted should equal the deposit amount.
        assertEq(sharesMinted, depositAmount, "Shares minted should equal the deposit amount under a 1:1 rate.");

        // Check that the user's token balance has decreased by the deposit amount.
        // (Assuming address(this) started with 1,000e18 tokens, the new balance should be 900e18.)
        assertEq(token.balanceOf(address(this)), 900e18, "User token balance did not decrease correctly.");

        // Check that the user's balance update record has been added for the upcoming epoch.
        // For this test we expect that there is at least one update. If this is the first deposit,
        // it should be stored at index 0.
        (uint256 recordedEpoch, uint256 recordedBalance) = boringVault.balanceUpdates(address(this), 0);
        // The update should be for epoch = currentEpoch + 1.
        uint256 expectedEpoch = boringVault.currentEpoch() + 1;
        assertEq(recordedEpoch, expectedEpoch, "The balance update epoch is not correct.");
        // The recorded balance should match the user's current share balance.
        assertEq(recordedBalance, boringVault.balanceOf(address(this)), "The recorded user balance does not match the vault balance.");

        // Check that the upcoming epoch's eligibleShares equals the deposit amount.
        // Since this is the first deposit and assuming no other deposits have occurred, 
        // the upcoming epoch (currentEpoch + 1) should have eligibleShares equal to depositAmount.
        (uint256 epochEligibleShares, ,) = boringVault.epochs(expectedEpoch);
        assertEq(epochEligibleShares, depositAmount, "Upcoming epoch's eligible shares not updated correctly.");
    }
    
    function testMultipleDeposits() external {
        // Define deposit amounts.
        uint256 depositAmount1 = 100e18; // address(this)'s first deposit
        uint256 depositAmount2 = 50e18;  // address(this)'s second deposit

        // Approve teller to spend the total deposit amount.
        token.approve(address(boringVault), depositAmount1 + depositAmount2);
        // First deposit.
        teller.deposit(ERC20(address(token)), depositAmount1, 0);

        // Second deposit.
        teller.deposit(ERC20(address(token)), depositAmount2, 0);

        // --- Check vault share balances ---
        uint256 totalShares = boringVault.balanceOf(address(this));
        // Under a 1:1 rate, each user's shares should equal their deposit amounts.
        assertEq(totalShares, depositAmount1 + depositAmount2, "TestUser total shares incorrect.");

        // --- Check token balances ---
        // Assuming each started with 1,000e18 tokens:
        assertEq(token.balanceOf(address(this)), 1_000e18 - (depositAmount1 + depositAmount2), "TestUser token balance incorrect.");

        // --- Check upcoming epoch's eligibleShares ---
        uint256 expectedEpoch = boringVault.currentEpoch() + 1;
        (uint256 eligibleShares, , ) = boringVault.epochs(expectedEpoch);
        // The upcoming epoch's eligibleShares should be the sum of all deposits.
        assertEq(eligibleShares, depositAmount1 + depositAmount2, "Upcoming epoch eligibleShares not updated correctly.");

        // --- Check user balance update records ---
        // For address(this): since both deposits occurred in the same upcoming epoch, there should be one record.
        (uint256 recordedEpochTest, uint256 recordedBalanceTest) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recordedEpochTest, expectedEpoch, "TestUser balance update epoch is not correct.");
        assertEq(recordedBalanceTest, totalShares, "TestUser recorded balance does not match vault balance.");
    }

    function testWithdrawPartial() external {
        // Define deposit and withdrawal amounts.
        uint256 depositAmount = 100e18;
        uint256 withdrawShares = 40e18;

        // -------------------------------
        // 1. Deposit 100 Tokens
        // -------------------------------
        // Approve the BoringVault for the deposit amount.
        token.approve(address(boringVault), depositAmount);
        
        // Call the deposit function on the teller.
        // (minimumMint is set to 0 for simplicity)
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Verify that testUser's vault share balance equals the deposit amount (assuming 1:1 rate).
        uint256 initialVaultBalance = boringVault.balanceOf(address(this));
        assertEq(initialVaultBalance, depositAmount, "Initial vault share balance should equal deposit amount");

        // -----------------------------------
        // 2. Withdraw 40 Shares Partially
        // -----------------------------------

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();

        // Record the initial eligible shares.
        (uint256 eligibleBefore, ,) = boringVault.epochs(boringVault.currentEpoch());

        // Call bulkWithdraw on the teller.
        // Parameters: withdraw asset, number of shares to withdraw, minimumAssets (set to 0), and recipient.
        uint256 assetsReceived = teller.bulkWithdraw(ERC20(address(token)), withdrawShares, 0, address(this));

        // Under a 1:1 rate, assetsReceived should equal withdrawShares.
        assertEq(assetsReceived, withdrawShares, "Assets received should equal withdrawn shares");

        // -----------------------------------
        // 3. Verify Final Vault and Token Balances
        // -----------------------------------
        // The vault share balance for address(this) should now be (100e18 - 40e18) = 60e18.
        uint256 finalVaultBalance = boringVault.balanceOf(address(this));
        assertEq(finalVaultBalance, depositAmount - withdrawShares, "Final vault share balance is incorrect");

        // Assuming address(this) started with 1,000e18 tokens:
        // After depositing 100e18 tokens, address(this)'s token balance becomes 900e18.
        // After withdrawing 40e18 tokens (in asset value), their balance should be 900e18 + 40e18 = 940e18.
        uint256 finalTokenBalance = token.balanceOf(address(this));
        assertEq(finalTokenBalance, 940e18, "User token balance after partial withdrawal is incorrect");

        // (b) Verify that the eligibleShares in the current epoch have decreased appropriately.
        (uint256 eligibleAfter, ,) = boringVault.epochs(boringVault.currentEpoch());

        // Expected eligible shares should be the initial eligible shares minus withdrawShares.
        assertEq(eligibleAfter, eligibleBefore - withdrawShares, "Eligible shares in current epoch not updated correctly after withdrawal.");
    }

    function testWithdrawAll() external {
        // Define deposit and withdrawal amounts.
        uint256 depositAmount = 100e18;
        uint256 withdrawShares = 100e18;

        // -------------------------------
        // 1. Deposit 100 Tokens
        // -------------------------------
        // Approve the BoringVault for the deposit amount.
        token.approve(address(boringVault), depositAmount);
        
        // Call the deposit function on the teller.
        // (minimumMint is set to 0 for simplicity)
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Verify that testUser's vault share balance equals the deposit amount (assuming 1:1 rate).
        uint256 initialVaultBalance = boringVault.balanceOf(address(this));
        assertEq(initialVaultBalance, depositAmount, "Initial vault share balance should equal deposit amount");

        // -----------------------------------
        // 2. Withdraw 100 Shares
        // -----------------------------------

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();

        // Record the initial eligible shares.
        (uint256 eligibleBefore, ,) = boringVault.epochs(boringVault.currentEpoch());
        
        // Call bulkWithdraw on the teller.
        // Parameters: withdraw asset, number of shares to withdraw, minimumAssets (set to 0), and recipient.
        uint256 assetsReceived = teller.bulkWithdraw(ERC20(address(token)), withdrawShares, 0, address(this));

        // Under a 1:1 rate, assetsReceived should equal withdrawShares.
        assertEq(assetsReceived, withdrawShares, "Assets received should equal withdrawn shares");

        // -----------------------------------
        // 3. Verify Final Vault and Token Balances
        // -----------------------------------
        // The vault share balance for address(this) should now be 0e18.
        uint256 finalVaultBalance = boringVault.balanceOf(address(this));
        assertEq(finalVaultBalance, depositAmount - withdrawShares, "Final vault share balance is incorrect");

        // Assuming address(this) started with 1,000e18 tokens:
        // After depositing 100e18 tokens, address(this)'s token balance becomes 900e18.
        // After withdrawing 100e18 tokens (in asset value), their balance should be 900e18 + 100e18 = 1000e18.
        uint256 finalTokenBalance = token.balanceOf(address(this));
        assertEq(finalTokenBalance, 1000e18, "User token balance after partial withdrawal is incorrect");

        // (b) Verify that the eligibleShares in the current epoch have decreased appropriately.
        (uint256 eligibleAfter, ,) = boringVault.epochs(boringVault.currentEpoch());
        
        // Expected eligible shares should be the initial eligible shares minus withdrawShares.
        assertEq(eligibleAfter, eligibleBefore - withdrawShares, "Eligible shares in current epoch not updated correctly after withdrawal.");
    }

    function testFailWithdrawExceedingBalance() external {
        // Define deposit and withdrawal amounts.
        uint256 depositAmount = 100e18;
        uint256 withdrawShares = 100e18;

        // Approve the BoringVault for the deposit amount.
        token.approve(address(boringVault), depositAmount);
        
        // Call the deposit function on the teller.
        // (minimumMint is set to 0 for simplicity)
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();
        
        // Call bulkWithdraw on the teller.
        // Parameters: withdraw asset, number of shares to withdraw, minimumAssets (set to 0), and recipient.
        teller.bulkWithdraw(ERC20(address(token)), withdrawShares + 1, 0, address(this));
    }

    // /*//////////////////////////////////////////////////////////////
    //                         TRANSFERS
    // //////////////////////////////////////////////////////////////*/
    function testBasicTransfer() external {
        // Define amounts.
        uint256 depositAmount = 100e18;

        // Approve BoringVault for depositAmount tokens.
        token.approve(address(boringVault), depositAmount);

        // Deposit into the vault via the teller.
        // We set minimumMint to 0 for simplicity.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Check the vault share balance for address(this).
        uint256 initialVaultBalance = boringVault.balanceOf(address(this));
        assertEq(
            initialVaultBalance,
            depositAmount,
            "Initial vault share balance should match depositAmount (assuming 1:1 rate)."
        );

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();

        // Transfer 40 shares from address(this) to anotherUser.
        uint256 transferShares = 40e18;
        bool success = boringVault.transfer(anotherUser, transferShares);
        assertTrue(success, "Transfer should succeed.");

        // a) Check share balances:
        uint256 finalVaultBalanceThis = boringVault.balanceOf(address(this));
        uint256 finalVaultBalanceAnother = boringVault.balanceOf(anotherUser);

        // address(this) should have depositAmount - transferShares left.
        assertEq(
            finalVaultBalanceThis,
            depositAmount - transferShares,
            "address(this) final vault shares are incorrect."
        );

        // anotherUser should have exactly 40 shares.
        assertEq(
            finalVaultBalanceAnother,
            transferShares,
            "anotherUser final vault shares are incorrect."
        );

        // b) Token balances do NOT change when transferring shares (only share ownership changes).
        // So address(this) still has 900e18 tokens if they started with 1,000e18 and deposited 100e18.
        // Another user also hasn't changed their underlying token balance.
        assertEq(
            token.balanceOf(address(this)),
            900e18,
            "Token balance of address(this) should be unchanged after share transfer."
        );
        assertEq(
            token.balanceOf(anotherUser),
            1_000e18,
            "Token balance of anotherUser should be unchanged after share transfer."
        );

        // c) BoringChef logic: transferring shares triggers _decreaseCurrentEpochParticipation(from) 
        //    and _increaseUpcomingEpochParticipation(to).
        // So the from-user's current epoch eligible shares decrease, 
        // while the to-user's share goes to the next epoch's eligibleShares.
        // We'll check these epoch states.

        // The 'from' user is in the current epoch (currentEpoch).
        uint256 currentEpochIndex = boringVault.currentEpoch();

        // The 'to' user is placed in the upcoming epoch (currentEpoch + 1).
        uint256 nextEpochIndex = currentEpochIndex + 1;

        // If no other actions occurred in the current epoch besides our deposit, 
        // fromEpochEligibleShares should now be (100 - 40) = 60.
        // toEpochEligibleShares should be 40 if this is the user's first time receiving shares
        // in the upcoming epoch.
        // However, note that if your deposit occurred just moments ago, 
        // you may or may not have "rolled over" the epoch. 
        // Usually, deposit sets your shares into (currentEpoch + 1) anyway. 
        // If you want to confirm the effect, you can check those fields.

        // d) Check user balance update records:
        // Because the vault calls _decreaseCurrentEpochParticipation(from) for the current epoch 
        // and _increaseUpcomingEpochParticipation(to) for the next epoch, you should see a new 
        // BalanceUpdate entry for each user's array. 
        // For address(this), a new entry in the currentEpoch with updated balance. 
        // For anotherUser, a new entry in nextEpoch with 40 shares.

        // Check the last record in from-user's balanceUpdates:
        uint256 fromUpdatesLen = boringVault.getTotalBalanceUpdates(address(this));
        (
            uint256 lastEpochFrom,
            uint256 lastBalanceFrom
        ) = boringVault.balanceUpdates(address(this), fromUpdatesLen - 1);

        assertEq(
            lastEpochFrom, 
            currentEpochIndex, 
            "From-user last balance update should track the current epoch."
        );
        assertEq(
            lastBalanceFrom, 
            depositAmount - transferShares, 
            "From-user last recorded share balance mismatch."
        );

        // Check the last record in to-user's balanceUpdates:
        uint256 toUpdatesLen = boringVault.getTotalBalanceUpdates(address(this));
        (
            uint256 lastEpochTo,
            uint256 lastBalanceTo
        ) = boringVault.balanceUpdates(anotherUser, toUpdatesLen - 1);

        assertEq(
            lastEpochTo, 
            nextEpochIndex, 
            "To-user last balance update should track the next epoch."
        );
        assertEq(
            lastBalanceTo, 
            transferShares, 
            "To-user last recorded share balance mismatch."
        );
    }

    function testFailTransferExceedingBalance() external {
        // Define amounts.
        uint256 depositAmount = 100e18;
        uint256 transferShares = 101e18;

        // Approve BoringVault for depositAmount tokens.
        token.approve(address(boringVault), depositAmount);

        // Deposit into the vault via the teller.
        // We set minimumMint to 0 for simplicity.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Check the vault share balance for address(this).
        uint256 initialVaultBalance = boringVault.balanceOf(address(this));
        assertEq(
            initialVaultBalance,
            depositAmount,
            "Initial vault share balance should match depositAmount (assuming 1:1 rate)."
        );

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();

        // Transfer 40 shares from address(this) to anotherUser.
        boringVault.transfer(anotherUser, transferShares);
    }

    function testFailTransferBeforeRollover() external {
        // Define amounts.
        uint256 depositAmount = 100e18;
        uint256 transferShares = 40e18;

        // Approve BoringVault for depositAmount tokens.
        token.approve(address(boringVault), depositAmount);

        // Deposit into the vault via the teller.
        // We set minimumMint to 0 for simplicity.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Check the vault share balance for address(this).
        uint256 initialVaultBalance = boringVault.balanceOf(address(this));
        assertEq(
            initialVaultBalance,
            depositAmount,
            "Initial vault share balance should match depositAmount (assuming 1:1 rate)."
        );

        // Transfer 40 shares from address(this) to anotherUser.
        boringVault.transfer(anotherUser, transferShares);
    }


    // /*//////////////////////////////////////////////////////////////
    //                         EPOCH ROLLING
    // //////////////////////////////////////////////////////////////*/
    function testManualEpochRollover() external {
        // ----- SETUP: Deposit some tokens first -----
        uint256 depositAmount = 100e18;
        // Have the test contract (owner) deposit 100 tokens via the teller.
        token.approve(address(boringVault), depositAmount);
        // Minimum mint is 0 for simplicity.
        teller.deposit(ERC20(address(token)), depositAmount, 0);
        
        // Capture the initial epoch. (Assume currentEpoch is already set; if not, it should be 0.)
        uint256 initialEpoch = boringVault.currentEpoch();
        
        // Read the current epoch data.
        (, , uint256 endTimestampBefore) = boringVault.epochs(initialEpoch);
        // Before a rollover, the current epoch's endTimestamp should be 0 (still open).
        assertEq(endTimestampBefore, 0, "Current epoch endTimestamp should be 0 before rollover");
        
        // --- (Optional) Check the user's balance update record for upcoming epoch.
        // Expect that the deposit has been recorded for epoch = initialEpoch + 1.
        (uint256 recordedEpoch, uint256 recordedBalance) = boringVault.balanceUpdates(address(this), 0);
        uint256 expectedUpcomingEpoch = initialEpoch + 1;
        assertEq(recordedEpoch, expectedUpcomingEpoch, "Balance update epoch should be currentEpoch + 1");
        assertEq(recordedBalance, boringVault.balanceOf(address(this)), "Recorded balance does not match vault balance");
        
        // --- Simulate a small time lapse.
        skip(10); // skip 10 seconds
        
        // ----- ROLLOVER: Manually roll over to the next epoch -----
        // Call the rollOverEpoch function. (The caller must be authorized; here, address(this) is the owner.)
        boringVault.rollOverEpoch();
        
        // The currentEpoch should now have incremented.
        uint256 newEpoch = boringVault.currentEpoch();
        assertEq(newEpoch, initialEpoch + 1, "Epoch did not increment correctly after rollover");
        
        // ----- Check previous epoch data -----
        // The previous epoch (initialEpoch) should now have an endTimestamp set.
        (, , uint256 previousEpochEnd) = boringVault.epochs(initialEpoch);
        assertGt(previousEpochEnd, 0, "Previous epoch endTimestamp should be > 0 after rollover");
        // Use an approximate equality check (tolerance of 2 seconds) for block.timestamp.
        assertApproxEqAbs(previousEpochEnd, block.timestamp, 2, "Previous epoch endTimestamp not close to current time");
        
        // ----- Check new epoch data -----
        ( , uint256 newEpochStart, ) = boringVault.epochs(newEpoch);
        // The new epoch's startTimestamp should be near the current block.timestamp.
        assertApproxEqAbs(newEpochStart, block.timestamp, 2, "New epoch startTimestamp not set correctly");
        
        // The new epoch's eligibleShares should be rolled over from the previous epoch.
        // According to _rollOverEpoch(), if the upcoming epoch's eligibleShares is 0,
        // it gets set to current epoch's eligibleShares.
        (uint256 eligibleNew, , ) = boringVault.epochs(newEpoch);
        assertEq(eligibleNew, depositAmount, "New epoch eligibleShares should equal the previous epoch's eligible shares");
        
        // ----- Check user balance update records -----
        // (Assuming you have a helper function getTotalBalanceUpdates(address) that returns the length of balanceUpdates for a user.)
        uint256 updatesLength = boringVault.getTotalBalanceUpdates(address(this));
        // The latest balance update record should correspond to the new epoch.
        (uint256 lastUpdateEpoch, uint256 lastRecordedBalance) = boringVault.balanceUpdates(address(this), updatesLength - 1);
        assertEq(lastUpdateEpoch, newEpoch, "Latest balance update epoch should be the new epoch");
        assertEq(lastRecordedBalance, boringVault.balanceOf(address(this)), "Latest recorded balance does not match current vault balance");
    }

    function testMultipleEpochRollovers() external {
        // Deposit an initial amount of tokens.
        uint256 depositAmount = 100e18;
        token.approve(address(boringVault), depositAmount);
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Capture the initial epoch. Deposits are recorded for upcoming epoch (currentEpoch + 1)
        uint256 initialEpoch = boringVault.currentEpoch();

        // Verify the balance update record for the upcoming epoch.
        (uint256 recordedEpoch, uint256 recordedBalance) = boringVault.balanceUpdates(address(this), 0);
        uint256 expectedUpcomingEpoch = initialEpoch + 1;
        assertEq(recordedEpoch, expectedUpcomingEpoch, "Balance update epoch should be currentEpoch + 1");
        assertEq(recordedBalance, boringVault.balanceOf(address(this)), "Recorded balance does not match vault balance");

        // Number of rollovers to simulate.
        uint256 numRollovers = 5;

        for (uint256 i = 0; i < numRollovers; i++) {
            // Simulate time passing so that the epoch can end.
            skip(10); // Skip 10 seconds

            // Call the rollOverEpoch function.
            boringVault.rollOverEpoch();

            // The currentEpoch should now have incremented by 1 each time.
            uint256 currentEpoch = boringVault.currentEpoch();
            assertEq(currentEpoch, initialEpoch + i + 1, "Epoch did not increment correctly after rollover");

            // Check the previous epoch's endTimestamp is set.
            (, , uint256 prevEpochEnd) = boringVault.epochs(currentEpoch - 1);
            assertGt(prevEpochEnd, 0, "Previous epoch endTimestamp should be > 0 after rollover");
            assertApproxEqAbs(prevEpochEnd, block.timestamp, 2, "Previous epoch endTimestamp not close to current time");

            // Check the new epoch's startTimestamp.
            ( , uint256 currentEpochStart, ) = boringVault.epochs(currentEpoch);
            assertApproxEqAbs(currentEpochStart, block.timestamp, 2, "New epoch startTimestamp not set correctly");

            // Check that the new epoch's eligibleShares has been rolled over correctly.
            // Since no additional deposits occurred, it should equal the depositAmount.
            (uint256 eligibleShares, , ) = boringVault.epochs(currentEpoch);
            assertEq(eligibleShares, depositAmount, "New epoch eligibleShares should equal the initial deposit amount");
        }

        // After all rollovers, verify the user's final balance update.
        uint256 lastRecordedBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(lastRecordedBalance, boringVault.balanceOf(address(this)), "Latest recorded balance does not match vault balance");
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/
    function testDistributeRewardsValidRange() external {
        // Set our testUser and anotherUser to have roles so that they can deposit/withdraw.
        // (These role settings are only necessary if the Teller contract enforces role restrictions on deposits.)
        rolesAuthority.setUserRole(testUser, DEPOSITOR_ROLE, true);
        rolesAuthority.setUserRole(anotherUser, DEPOSITOR_ROLE, true);
        rolesAuthority.setRoleCapability(DEPOSITOR_ROLE, address(teller), teller.deposit.selector, true);
        rolesAuthority.setRoleCapability(DEPOSITOR_ROLE, address(teller), teller.bulkWithdraw.selector, true);

        // Deploy the reward tokens and mint them.
        MockERC20 rewardToken1 = new MockERC20("Reward Token 1", "RT1", 18);
        MockERC20 rewardToken2 = new MockERC20("Reward Token 2", "RT2", 18);
        rewardToken1.mint(address(this), 100e18);
        rewardToken2.mint(address(this), 100e18);

        // Deposit 100 tokens from each address.
        address[3] memory users = [address(this), testUser, anotherUser];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(boringVault), 100e18);
            teller.deposit(ERC20(address(token)), 100e18, 0);
            vm.stopPrank();
        }

        // For clarity, let the owner call further functions.
        vm.startPrank(owner);

        // Simulate time passing so that the current epoch(s) can be ended.
        skip(10); // skip 10 seconds

        // Roll over the epoch several times.
        // (Here we roll over 5 times, skipping some extra seconds between rollovers.)
        uint8[5] memory extraTime = [15, 30, 45, 60, 75];
        for (uint256 i = 0; i < extraTime.length; i++) {
            boringVault.rollOverEpoch();
            skip(extraTime[i]); // skip additional seconds after each rollover
        }
        
        // At this point, the currentEpoch has advanced enough that we can distribute rewards retroactively.
        // Set up the reward distribution arrays.
        // Reward 0: For deposit token reward across epochs 0 to 1.
        // Reward 1: For rewardToken1 distributed from epoch 1 to 2.
        // Reward 2: For rewardToken2 distributed from epoch 1 to 3.
        address[] memory tokenArray = new address[](3);
        tokenArray[0] = address(token);
        tokenArray[1] = address(rewardToken1);
        tokenArray[2] = address(rewardToken2);

        uint256[] memory amountArray = new uint256[](3);
        amountArray[0] = 60e18;
        amountArray[1] = 12e18;
        amountArray[2] = 10e18;

        uint256[] memory startEpochArray = new uint256[](3);
        startEpochArray[0] = 0;
        startEpochArray[1] = 1;
        startEpochArray[2] = 1;

        uint256[] memory endEpochArray = new uint256[](3);
        endEpochArray[0] = 1;
        endEpochArray[1] = 2;
        endEpochArray[2] = 3;

        // Approve the reward tokens for the vault (boringSafe) to pull the tokens.
        token.approve(address(boringVault), 60e18);
        rewardToken1.approve(address(boringVault), 12e18);
        rewardToken2.approve(address(boringVault), 10e18);

        // Distribute the rewards.
        boringVault.distributeRewards(
            tokenArray,
            amountArray,
            startEpochArray,
            endEpochArray
        );

        // --- Check that the rewards have been transferred to the safe ---
        assertEq(token.balanceOf(address(boringVault.boringSafe())), 60e18, "Deposit token not correctly transferred to safe");
        assertEq(rewardToken1.balanceOf(address(boringVault.boringSafe())), 12e18, "Reward token 1 not correctly transferred to safe");
        assertEq(rewardToken2.balanceOf(address(boringVault.boringSafe())), 10e18, "Reward token 2 not correctly transferred to safe");

        // --- Additional internal consistency checks on the rewards stored in the vault ---
        // Ensure that maxRewardId is now 3.
        assertEq(boringVault.maxRewardId(), 3, "maxRewardId should be 3 after reward distribution");

        // For each reward, verify the stored parameters and that the computed total distribution matches the input amount.
        // Reward 0: Distribution for token deposit from epoch 0 to 1.
        {
            (address rToken0, uint256 rRate0, uint256 rStart0, uint256 rEnd0) = boringVault.rewards(0);
            assertEq(rToken0, address(token), "Reward 0 token mismatch");
            assertEq(rStart0, 0, "Reward 0 startEpoch mismatch");
            assertEq(rEnd0, 1, "Reward 0 endEpoch mismatch");
            // Retrieve epoch data for epochs 0 and 1.
            ( , uint256 epoch0Start, uint256 epoch0End) = boringVault.epochs(0);
            ( , uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);
            // Total duration for reward 0 is from epoch0.startTimestamp to epoch0.endTimestamp plus epoch1 duration.
            uint256 duration0 = (epoch0End - epoch0Start) + (epoch1End - epoch1Start);
            uint256 totalReward0 = rRate0.mulWadDown(duration0);
            assertApproxEqAbs(totalReward0, 60e18, 1e6, "Total distributed reward for reward 0 mismatch");

            // Since our user's had no eligible shares at epoch 0, we need to calculate exactly how many rewards they are owed.
            // Since we have 3 users, we divide the total reward by 3.
            duration0 = (epoch1End - epoch1Start);
            uint256 userReward0 = (rRate0.mulWadDown(duration0)).divWadDown(3e18);

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(boringVault.getUserRewardBalance(address(this), 0), userReward0, 1e12, "User should have 20 reward 0");
            assertApproxEqAbs(boringVault.getUserRewardBalance(testUser, 0), userReward0, 1e12, "TestUser should have 20 reward 0");
            assertApproxEqAbs(boringVault.getUserRewardBalance(anotherUser, 0), userReward0, 1e12, "AnotherUser should have 20 reward 0");
        }

        // Reward 1: Distribution for rewardToken1 from epoch 1 to 2.
        {
            (address rToken1, uint256 rRate1, uint256 rStart1, uint256 rEnd1) = boringVault.rewards(1);
            assertEq(rToken1, address(rewardToken1), "Reward 1 token mismatch");
            assertEq(rStart1, 1, "Reward 1 startEpoch mismatch");
            assertEq(rEnd1, 2, "Reward 1 endEpoch mismatch");
            // Retrieve epoch data for epochs 1 and 2.
            ( , uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);
            ( , uint256 epoch2Start, uint256 epoch2End) = boringVault.epochs(2);
            // Total duration for reward 1 is from epoch1.startTimestamp to epoch1.endTimestamp plus epoch2 duration.
            uint256 duration1 = (epoch1End - epoch1Start) + (epoch2End - epoch2Start);
            uint256 totalReward1 = rRate1.mulWadDown(duration1);
            assertApproxEqAbs(totalReward1, 12e18, 1e6, "Total distributed reward for reward 1 mismatch");

            // Calculate the reward for each user.
            uint256 userReward1 = totalReward1.divWadDown(3e18);

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(boringVault.getUserRewardBalance(address(this), 1), userReward1, 1e12, "User should have 4 reward 1");
            assertApproxEqAbs(boringVault.getUserRewardBalance(testUser, 1), userReward1, 1e12, "TestUser should have 4 reward 1");
            assertApproxEqAbs(boringVault.getUserRewardBalance(anotherUser, 1), userReward1, 1e12, "AnotherUser should have 4 reward 1");
        }

        // Reward 2: Distribution for rewardToken2 from epoch 1 to 3.
        {
            (address rToken2, uint256 rRate2, uint256 rStart2, uint256 rEnd2) = boringVault.rewards(2);
            assertEq(rToken2, address(rewardToken2), "Reward 2 token mismatch");
            assertEq(rStart2, 1, "Reward 2 startEpoch mismatch");
            assertEq(rEnd2, 3, "Reward 2 endEpoch mismatch");
            // Retrieve epoch data for epochs 1 and 2.
            ( , uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);
            ( , uint256 epoch2Start, uint256 epoch2End) = boringVault.epochs(2);
            ( , uint256 epoch3Start, uint256 epoch3End) = boringVault.epochs(3);
            // Total duration for reward 2 is from epoch1.startTimestamp to epoch1.endTimestamp plus epoch2 duration plus epoch3 duration.
            uint256 duration2 = (epoch1End - epoch1Start) + (epoch2End - epoch2Start) + (epoch3End - epoch3Start);
            uint256 totalReward2 = rRate2.mulWadDown(duration2);
            assertApproxEqAbs(totalReward2, 10e18, 1e6, "Total distributed reward for reward 2 mismatch");

            // Calculate the reward for each user.
            uint256 userReward2 = totalReward2.divWadDown(3e18);

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(boringVault.getUserRewardBalance(address(this), 2), userReward2, 1e12, "User should have 4 reward 2");
            assertApproxEqAbs(boringVault.getUserRewardBalance(testUser, 2), userReward2, 1e12, "TestUser should have 4 reward 2");
            assertApproxEqAbs(boringVault.getUserRewardBalance(anotherUser, 2), userReward2, 1e12, "AnotherUser should have 4 reward 2");   
        }
    }

    function testFailRewardsStartEpochGreaterThanEndEpoch() external {
        boringVault.rollOverEpoch();
        boringVault.rollOverEpoch();
        boringVault.rollOverEpoch();

        address[] memory tokenArray = new address[](1);
        tokenArray[0] = address(token);

        uint256[] memory amountArray = new uint256[](1);
        amountArray[0] = 100e18;

        uint256[] memory startEpochArray = new uint256[](1);
        startEpochArray[0] = 2;

        uint256[] memory endEpochArray = new uint256[](1);
        endEpochArray[0] = 0;

        boringVault.distributeRewards(
            tokenArray,
            amountArray,
            startEpochArray,
            endEpochArray
        );
    }

    function testFailDistributeRewardsEndEpochInFuture() external {
        boringVault.rollOverEpoch();

        address[] memory tokenArray = new address[](1);
        tokenArray[0] = address(token);

        uint256[] memory amountArray = new uint256[](1);
        amountArray[0] = 100e18;

        uint256[] memory startEpochArray = new uint256[](1);
        startEpochArray[0] = 0;

        uint256[] memory endEpochArray = new uint256[](1);
        endEpochArray[0] = 2;

        boringVault.distributeRewards(
            tokenArray,
            amountArray,
            startEpochArray,
            endEpochArray
        );
    }

    function testSingleEpochRewardDistribution() external {
        // Deploy the reward token and mint it.
        MockERC20 rewardToken1 = new MockERC20("Reward Token 1", "RT1", 18);
        rewardToken1.mint(address(this), 100e18);

        // Deposit 100 tokens.
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // Roll over the epoch.
        boringVault.rollOverEpoch();

        // Simulate time passing so that the current epoch(s) can be ended.
        skip(10); // skip 10 seconds

        // Roll over the epoch again.
        boringVault.rollOverEpoch();
        
        // At this point, the currentEpoch has advanced enough that we can distribute rewards retroactively.
        // Set up the reward distribution arrays.
        // Reward 0: For deposit token reward across epochs 0 to 1.
        // Reward 1: For rewardToken1 distributed from epoch 1 to 2.
        // Reward 2: For rewardToken2 distributed from epoch 1 to 3.
        address[] memory tokenArray = new address[](1);
        tokenArray[0] = address(rewardToken1);

        uint256[] memory amountArray = new uint256[](1);
        amountArray[0] = 100e18;

        uint256[] memory startEpochArray = new uint256[](1);
        startEpochArray[0] = 1;

        uint256[] memory endEpochArray = new uint256[](1);
        endEpochArray[0] = 1;

        // Approve the reward tokens for the vault (boringSafe) to pull the tokens.
        rewardToken1.approve(address(boringVault), 100e18);

        // Distribute the rewards.
        boringVault.distributeRewards(
            tokenArray,
            amountArray,
            startEpochArray,
            endEpochArray
        );

        // --- Check that the rewards have been transferred to the safe ---
        assertEq(rewardToken1.balanceOf(address(boringVault.boringSafe())), 100e18, "Reward token 1 not correctly transferred to safe");

        // --- Additional internal consistency checks on the rewards stored in the vault ---
        // Ensure that maxRewardId is now 3.
        assertEq(boringVault.maxRewardId(), 1, "maxRewardId should be 1 after reward distribution");

        // For each reward, verify the stored parameters and that the computed total distribution matches the input amount.
        // Reward 0: Distribution for token deposit from epoch 1.
        {
            (address rToken0, uint256 rRate0, uint256 rStart0, uint256 rEnd0) = boringVault.rewards(0);
            assertEq(rToken0, address(rewardToken1), "Reward 0 token mismatch");
            assertEq(rStart0, 1, "Reward 0 startEpoch mismatch");
            assertEq(rEnd0, 1, "Reward 0 endEpoch mismatch");
            // Retrieve epoch data for epochs 1.
            ( , uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);

            // Total duration for reward 0 is from epoch0.startTimestamp to epoch0.endTimestamp plus epoch1 duration.
            uint256 duration0 = (epoch1End - epoch1Start);
            uint256 totalReward0 = rRate0.mulWadDown(duration0);
            assertApproxEqAbs(totalReward0, 100e18, 1e6, "Total distributed reward for reward 0 mismatch");

            // Since our user's had no eligible shares at epoch 0, we need to calculate exactly how many rewards they are owed.
            uint256 userReward0 = (rRate0.mulWadDown(duration0));

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(boringVault.getUserRewardBalance(address(this), 0), userReward0, 1e12, "User should have 100 reward 0");
        }
    }

    function testComplexRewardDistribution() external {}

    // /*//////////////////////////////////////////////////////////////
    //                         CLAIMS
    // //////////////////////////////////////////////////////////////*/
    // function testClaimFullRange() external {}
    // function testClaimPartialEpochParticipation() external {}
    // function testClaimZeroTotalShares() external {}
    // function testClaimAlreadyClaimed() external {}
    // function testClaimMultipleRewards() external {}

    // /*//////////////////////////////////////////////////////////////
    //                         USER SHARE ACCOUNTING
    // //////////////////////////////////////////////////////////////*/
    function testFindUserBalanceAtEpochNoDeposits() external {
        // Create a new epoch
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        uint256 eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have no eligible balance");
    }

    function testFindUserBalanceAtEpochAllUpdatesAfter() external {
        // Create a new epoch
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        uint256 eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have no eligible balance");

        // Deposit 100 tokens
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have no eligible balance");

        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 100e18, "User should have 100 eligible balance");
        
    }

    function testFindUserBalanceAtEpochExactMatch() external {
        // Create a new epoch
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        uint256 eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have no eligible balance");

        // Deposit 100 tokens
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have 0 eligible balance");

        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 100e18, "User should have 100 eligible balance");
        
        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 100e18, "User should have 100 eligible balance");
    }
    function testFindUserBalanceAtEpochMultipleUpdates() external {
        // Create a new epoch
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        uint256 eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have no eligible balance");

        // Deposit 100 tokens
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 0, "User should have 0 eligible balance");

        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 100e18, "User should have 100 eligible balance");
        
        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Deposit 100 tokens
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 100e18, "User should still have 100 eligible balance");

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 200e18, "User should have 200 eligible balance");

        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Withdraw 50 tokens
        teller.bulkWithdraw(ERC20(address(token)), 50e18, 0, address(this));

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 150e18, "User should have 150 eligible balance");
        
        // Simulate time passing so that the epoch can end.
        skip(10); // Skip 10 seconds

        // Call the rollOverEpoch function.
        boringVault.rollOverEpoch();

        // Get the user's eligible balance
        eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, 150e18, "User should still have 150 eligible balance");
    }

    // /*//////////////////////////////////////////////////////////////
    //                         INTEGRATION & EDGE CASES
    // //////////////////////////////////////////////////////////////*/
    // function testLargeRewards() external {}
    // function testStressManyEpochs() external {}
}
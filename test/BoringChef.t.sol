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

contract BoringVaultTest is Test {
    using stdStorage for StdStorage;

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
        // BoringVault’s constructor takes (address _shareToken, string memory _name, string memory _symbol, uint8 _decimals)
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

        // Set the authority for the vault and the teller.
        boringVault.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);
        rolesAuthority.setUserRole(address(teller), BURNER_ROLE, true);

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
        // After depositing 100e18 tokens, address(this)’s token balance becomes 900e18.
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
        // After depositing 100e18 tokens, address(this)’s token balance becomes 900e18.
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
        (uint256 fromEpochEligibleShares, , ) = boringVault.epochs(currentEpochIndex);

        // The 'to' user is placed in the upcoming epoch (currentEpoch + 1).
        uint256 nextEpochIndex = currentEpochIndex + 1;
        (uint256 toEpochEligibleShares, , ) = boringVault.epochs(nextEpochIndex);

        // If no other actions occurred in the current epoch besides our deposit, 
        // fromEpochEligibleShares should now be (100 - 40) = 60.
        // toEpochEligibleShares should be 40 if this is the user’s first time receiving shares
        // in the upcoming epoch.
        // However, note that if your deposit occurred just moments ago, 
        // you may or may not have “rolled over” the epoch. 
        // Usually, deposit sets your shares into (currentEpoch + 1) anyway. 
        // If you want to confirm the effect, you can check those fields.

        // For demonstration, let's just read them for insight:
        console.log("Eligible shares in current epoch:", fromEpochEligibleShares);
        console.log("Eligible shares in next epoch:", toEpochEligibleShares);

        // d) Check user balance update records:
        // Because the vault calls _decreaseCurrentEpochParticipation(from) for the current epoch 
        // and _increaseUpcomingEpochParticipation(to) for the next epoch, you should see a new 
        // BalanceUpdate entry for each user’s array. 
        // For address(this), a new entry in the currentEpoch with updated balance. 
        // For anotherUser, a new entry in nextEpoch with 40 shares.

        // Check the last record in from-user’s balanceUpdates:
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

        // Check the last record in to-user’s balanceUpdates:
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
        // Before a rollover, the current epoch’s endTimestamp should be 0 (still open).
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
        // According to _rollOverEpoch(), if the upcoming epoch’s eligibleShares is 0,
        // it gets set to current epoch’s eligibleShares.
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

    // /*//////////////////////////////////////////////////////////////
    //                         REWARDS
    // //////////////////////////////////////////////////////////////*/
    // function testDistributeRewardsValidRange() external {}
    // function testFailDistributeRewardsStartEpochGreaterThanEndEpoch() external {
    //     boringChef = BoringChef(address(0));

    //     revert("test");
    // }
    // function testFailDistributeRewardsEndEpochInFuture() external {
    //     boringChef = BoringChef(address(0));

    //     revert("test");
    // }
    // function testFailDistributeRewardsInsufficientTokenBalance() external {
    //     boringChef = BoringChef(address(0));

    //     revert("test");
    // }
    // function testSingleEpochRewardDistribution() external {}

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
    function testFindUserBalanceAtEpochNoDeposits() external {}
    function testFindUserBalanceAtEpochAllUpdatesAfter() external {}
    function testFindUserBalanceAtEpochExactMatch() external {}
    function testFindUserBalanceAtEpochMultipleUpdates() external {}

    // /*//////////////////////////////////////////////////////////////
    //                         INTEGRATION & EDGE CASES
    // //////////////////////////////////////////////////////////////*/
    // function testLargeRewards() external {}
    // function testStressManyEpochs() external {}
}
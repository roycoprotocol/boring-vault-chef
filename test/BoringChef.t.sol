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

contract BoringChefTest is Test {
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
        accountant = new AccountantWithRateProviders(
            address(this), address(boringVault), address(0), 1e18, address(token), 1000, 1000, 1, 0, 0
        );

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
    function test_SingleDeposit() external {
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
        assertEq(
            recordedBalance,
            boringVault.balanceOf(address(this)),
            "The recorded user balance does not match the vault balance."
        );

        // Check that the upcoming epoch's eligibleShares equals the deposit amount.
        // Since this is the first deposit and assuming no other deposits have occurred,
        // the upcoming epoch (currentEpoch + 1) should have eligibleShares equal to depositAmount.
        (uint256 epochEligibleShares,,) = boringVault.epochs(expectedEpoch);
        assertEq(epochEligibleShares, depositAmount, "Upcoming epoch's eligible shares not updated correctly.");
    }

    function test_MultipleDeposits() external {
        // Define deposit amounts.
        uint256 depositAmount1 = 100e18; // address(this)'s first deposit
        uint256 depositAmount2 = 50e18; // address(this)'s second deposit

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
        assertEq(
            token.balanceOf(address(this)),
            1_000e18 - (depositAmount1 + depositAmount2),
            "TestUser token balance incorrect."
        );

        // --- Check upcoming epoch's eligibleShares ---
        uint256 expectedEpoch = boringVault.currentEpoch() + 1;
        (uint256 eligibleShares,,) = boringVault.epochs(expectedEpoch);
        // The upcoming epoch's eligibleShares should be the sum of all deposits.
        assertEq(
            eligibleShares, depositAmount1 + depositAmount2, "Upcoming epoch eligibleShares not updated correctly."
        );

        // --- Check user balance update records ---
        // For address(this): since both deposits occurred in the same upcoming epoch, there should be one record.
        (uint256 recordedEpochTest, uint256 recordedBalanceTest) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recordedEpochTest, expectedEpoch, "TestUser balance update epoch is not correct.");
        assertEq(recordedBalanceTest, totalShares, "TestUser recorded balance does not match vault balance.");
    }

    function testFuzz_MultipleDeposits(uint256 depositAmount1, uint256 depositAmount2) public {
        vm.assume(1e30 > depositAmount1 && depositAmount1 > 1e18);
        vm.assume(1e30 > depositAmount2 && depositAmount2 > 1e18);

        // Mint the total deposit amount to the user.
        token.mint(address(this), depositAmount1 + depositAmount2);

        // Approve teller to spend the total deposit amount.
        token.approve(address(boringVault), depositAmount1 + depositAmount2);
        
        // =========================================
        // ================ First deposit. ================
        // =========================================
        teller.deposit(ERC20(address(token)), depositAmount1, 0);

        // Check the user's balance update record.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 1, "TestUser balance update record is not correct.");
        (uint256 recordedEpochTest, uint256 recordedBalanceTest) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recordedEpochTest, boringVault.currentEpoch() + 1, "TestUser balance update epoch is not correct.");
        assertEq(recordedBalanceTest, depositAmount1, "TestUser recorded balance does not match vault balance.");

        // Vault Eligible Shares
        (uint256 vaultEligibleShares, , ) = boringVault.epochs(boringVault.currentEpoch() + 1);

        // Check the user's and vault's eligible balance.
        assertEq(boringVault.getUserEligibleBalance(address(this)), 0, "TestUser eligible balance should be 0.");
        assertEq(vaultEligibleShares, depositAmount1, "Vault eligible balance is not correct.");

        // =========================================
        // ================ Second deposit. ================
        // =========================================
        teller.deposit(ERC20(address(token)), depositAmount2, 0);

        // Check the user's balance update record.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 1, "TestUser balance update record is not correct.");
        (uint256 recordedEpochTest2, uint256 recordedBalanceTest2) = boringVault.balanceUpdates(address(this), 0);

        // Check the user's balance update record.
        // The second deposit should have occurred in the same epoch as the first deposit.
        assertEq(recordedEpochTest2, boringVault.currentEpoch() + 1, "TestUser balance update epoch is not correct.");
        assertEq(recordedBalanceTest2, depositAmount1 + depositAmount2, "TestUser recorded balance does not match vault balance.");

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();

        // Vault Eligible Shares
        (uint256 vaultEligibleShares2, , ) = boringVault.epochs(boringVault.currentEpoch());

        // Check the user's and vault's eligible balance.
        assertEq(boringVault.getUserEligibleBalance(address(this)), depositAmount1 + depositAmount2, "TestUser eligible balance is not correct.");
        assertEq(vaultEligibleShares2, depositAmount1 + depositAmount2, "Vault eligible balance is not correct.");

        // --- Check vault share balances ---
        uint256 totalShares = boringVault.balanceOf(address(this));
        // Under a 1:1 rate, each user's shares should equal their deposit amounts.
        assertEq(totalShares, depositAmount1 + depositAmount2, "TestUser total shares incorrect.");
    }

    // Test that multiple deposits in different epochs work correctly.
    function testFuzz_MultipleDeposits_DifferentEpochs(uint256 depositAmount1, uint256 depositAmount2) external {
        // Assume reasonable deposit amounts.
        vm.assume(depositAmount1 > 1e18 && depositAmount1 < 1e30);
        vm.assume(depositAmount2 > 1e18 && depositAmount2 < 1e30);

        // Mint the tokens to this contract.
        token.mint(address(this), depositAmount1 + depositAmount2);
        token.approve(address(boringVault), depositAmount1 + depositAmount2);

        // -------- First Deposit (will be recorded for upcoming epoch) --------
        // At this point, suppose currentEpoch == X.
        // This deposit will be recorded for epoch X+1.
        teller.deposit(ERC20(address(token)), depositAmount1, 0);

        // Check that there is one balance update record.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 1, "Should have 1 balance update after first deposit");
        (uint256 firstRecordEpoch, uint256 firstRecordBalance) = boringVault.balanceUpdates(address(this), 0);
        // Expect that the record is for currentEpoch + 1 and equals depositAmount1.
        assertEq(firstRecordEpoch, boringVault.currentEpoch() + 1, "First record epoch should be currentEpoch+1");
        assertEq(firstRecordBalance, depositAmount1, "First record balance should equal depositAmount1");

        // Check that, before rollover, eligible balance is still 0.
        assertEq(boringVault.getUserEligibleBalance(address(this)), 0, "Eligible balance should be 0 before epoch rollover");

        // Also, the upcoming epoch’s eligible shares (currentEpoch+1) should equal depositAmount1.
        (uint256 upcomingEligible1, , ) = boringVault.epochs(boringVault.currentEpoch() + 1);
        assertEq(upcomingEligible1, depositAmount1, "Upcoming epoch eligible shares mismatch after first deposit");

        // -------- Rollover Epoch after first deposit --------
        boringVault.rollOverEpoch(); 
        // Now currentEpoch increments (if it was X, now currentEpoch == X+1).

        // -------- Second Deposit (in a new epoch) --------
        // Now, when we deposit again, it will be recorded for the upcoming epoch (currentEpoch+1).
        teller.deposit(ERC20(address(token)), depositAmount2, 0);
        // Since the second deposit is in a new epoch, we now expect two balance update records.
        uint256 totalUpdates = boringVault.getTotalBalanceUpdates(address(this));
        assertEq(totalUpdates, 2, "Should have 2 balance update records after second deposit");

        // Retrieve both update records.
        (uint256 recordEpoch1, uint256 recordBalance1) = boringVault.balanceUpdates(address(this), 0);
        (uint256 recordEpoch2, uint256 recordBalance2) = boringVault.balanceUpdates(address(this), 1);
        // The first record (from the first deposit) should remain unchanged.
        assertEq(recordEpoch1, boringVault.currentEpoch(), "First record epoch should equal previous upcoming epoch");
        assertEq(recordBalance1, depositAmount1, "First record balance should equal depositAmount1");
        // The second record should now be for the new upcoming epoch (currentEpoch+1) and reflect the cumulative deposit.
        assertEq(recordEpoch2, boringVault.currentEpoch() + 1, "Second record epoch should be currentEpoch+1");
        assertEq(recordBalance2, depositAmount1 + depositAmount2, "Second record balance should be the sum of both deposits");

        // -------- Rollover Again to Activate the Deposits --------
        boringVault.rollOverEpoch(); 
        // Now the deposits become eligible. Current epoch has increased by one.

        // Check that the user's eligible balance equals the total deposited.
        uint256 userEligible = boringVault.getUserEligibleBalance(address(this));
        assertEq(userEligible, depositAmount1 + depositAmount2, "Eligible balance should equal total deposits after rollover");

        // Finally, check the vault share balance (should equal the total deposited, given 1:1 rate).
        uint256 totalShares = boringVault.balanceOf(address(this));
        assertEq(totalShares, depositAmount1 + depositAmount2, "Total vault shares should equal the sum of deposits");
    }


    function test_WithdrawPartial() external {
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
        (uint256 eligibleBefore,,) = boringVault.epochs(boringVault.currentEpoch());

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
        (uint256 eligibleAfter,,) = boringVault.epochs(boringVault.currentEpoch());

        // Expected eligible shares should be the initial eligible shares minus withdrawShares.
        assertEq(
            eligibleAfter,
            eligibleBefore - withdrawShares,
            "Eligible shares in current epoch not updated correctly after withdrawal."
        );
    }

    function test_WithdrawAll() external {
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
        (uint256 eligibleBefore,,) = boringVault.epochs(boringVault.currentEpoch());

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
        (uint256 eligibleAfter,,) = boringVault.epochs(boringVault.currentEpoch());

        // Expected eligible shares should be the initial eligible shares minus withdrawShares.
        assertEq(
            eligibleAfter,
            eligibleBefore - withdrawShares,
            "Eligible shares in current epoch not updated correctly after withdrawal."
        );
    }

    function testFuzz_Withdraw(uint256 withdrawAmount) external {
        // Assume reasonable deposit amounts.
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), withdrawAmount);
        token.approve(address(boringVault), withdrawAmount);

        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), withdrawAmount, 0);

        // Roll over to the next epoch.
        boringVault.rollOverEpoch();

        // Validate the eligible shares.
        uint256 eligibleShares = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleShares, withdrawAmount, "Eligible shares are incorrect.");

        // Validate the user's eligible balance. 
        (uint256 eligibleBefore, ,) = boringVault.epochs(boringVault.currentEpoch());
        assertEq(eligibleBefore, withdrawAmount, "Eligible shares are incorrect.");

        // Call bulkWithdraw on the teller.
        // Parameters: withdraw asset, number of shares to withdraw, minimumAssets (set to 0), and recipient.
        uint256 assetsReceived = teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));

        // Under a 1:1 rate, assetsReceived should equal withdrawAmount.
        assertEq(assetsReceived, withdrawAmount, "Assets received should equal withdrawn shares");

        // Validate the user's eligible balance. 
        (uint256 eligibleAfter, ,) = boringVault.epochs(boringVault.currentEpoch());
        assertEq(eligibleAfter, 0, "Eligible shares are incorrect.");

        // Validate the user's vault share balance.
        uint256 finalVaultBalance = boringVault.balanceOf(address(this));
        assertEq(finalVaultBalance, 0, "Vault share balance is incorrect.");

        // Validate the user's eligible balance.
        uint256 eligibleAfter2 = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleAfter2, 0, "Eligible shares are incorrect.");
    }

    function testFuzz_Withdraw_MultipleEpochsAndDeposits(uint256 withdrawAmount) external {
        // Assume withdrawAmount is between 1e18 and 1e30.
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);

        // ─────────────────────────────────────────────────────────────
        // PHASE 1: Deposit in Epoch 0
        // ─────────────────────────────────────────────────────────────
        // Mint withdrawAmount tokens and deposit them.
        token.mint(address(this), withdrawAmount);
        token.approve(address(boringVault), withdrawAmount);
        // This deposit is recorded for the upcoming epoch (currentEpoch + 1).
        teller.deposit(ERC20(address(token)), withdrawAmount, 0);

        // Roll over the epoch so that the deposit becomes eligible.
        boringVault.rollOverEpoch();

        // Validate the user's eligible balance.
        uint256 eligibleBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance, withdrawAmount, "First eligible balance is incorrect.");

        // Validate the user's balance update record.
        (uint256 recEpoch1, uint256 recBalance1) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recEpoch1, boringVault.currentEpoch(), "First update epoch should be currentEpoch");
        assertEq(recBalance1, withdrawAmount, "First update balance mismatch");
        

        // ─────────────────────────────────────────────────────────────
        // PHASE 2: Deposit in a later epoch
        // ─────────────────────────────────────────────────────────────
        // Now mint and deposit 2×withdrawAmount tokens.
        token.mint(address(this), 2 * withdrawAmount);
        token.approve(address(boringVault), 2 * withdrawAmount);
        // This deposit is recorded for the upcoming epoch.
        teller.deposit(ERC20(address(token)), 2 * withdrawAmount, 0);

        // Roll over the epoch so that the second deposit becomes eligible.
        boringVault.rollOverEpoch();

        // Validate the user's eligible balance.
        uint256 eligibleBalance2 = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance2, withdrawAmount * 3, "Second eligible balance is incorrect.");

        // Validate the user's balance update record.
        (uint256 recEpoch2, uint256 recBalance2) = boringVault.balanceUpdates(address(this), 1);
        assertEq(recEpoch2, boringVault.currentEpoch(), "Second update epoch should be currentEpoch");
        assertEq(recBalance2, withdrawAmount * 3, "Second update balance mismatch");

        // ─────────────────────────────────────────────────────────────
        // PHASE 3: Deposit multiple times in a later epoch
        // ─────────────────────────────────────────────────────────────
        // Now mint and deposit 2×withdrawAmount tokens.
        token.mint(address(this), 2 * withdrawAmount);
        token.approve(address(boringVault), 2 * withdrawAmount);
        // This deposit is recorded for the upcoming epoch.
        teller.deposit(ERC20(address(token)), withdrawAmount, 0);
        teller.deposit(ERC20(address(token)), withdrawAmount, 0);

        // Roll over the epoch so that the second deposit becomes eligible.
        boringVault.rollOverEpoch();

        // Validate the user's eligible balance.
        uint256 eligibleBalance3 = boringVault.getUserEligibleBalance(address(this));
        assertEq(eligibleBalance3, 5 * withdrawAmount, "Eligible balance is incorrect.");

        // Validate the user's balance update record.
        (uint256 recEpoch3, uint256 recBalance3) = boringVault.balanceUpdates(address(this), 2);
        assertEq(recEpoch3, boringVault.currentEpoch(), "Third update epoch should be currentEpoch");
        assertEq(recBalance3, 5 * withdrawAmount, "Third update balance mismatch");
        // ─────────────────────────────────────────────────────────────
        // PHASE 4: First Partial Withdrawal
        // ─────────────────────────────────────────────────────────────
        // Withdraw withdrawAmount tokens.
        uint256 assetsReceived1 = teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));

        // Under a 1:1 rate, assetsReceived should equal withdrawAmount.
        assertEq(assetsReceived1, withdrawAmount, "First withdrawal assets received mismatch");

        // Validate the user's balance updates record.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 3, "Balance updates record is incorrect.");

        // ─────────────────────────────────────────────────────────────
        // PHASE 5: Second (Final) Withdrawals
        // ─────────────────────────────────────────────────────────────
        // Withdraw the remaining shares.
        uint256 assetsReceived2 = teller.bulkWithdraw(ERC20(address(token)), 2 * withdrawAmount, 0, address(this));
        assertEq(assetsReceived2, 2 * withdrawAmount, "Second withdrawal assets received mismatch");

        // Withdraw a second time.
        teller.bulkWithdraw(ERC20(address(token)), 2 * withdrawAmount, 0, address(this));

        // Validate the user's balance updates record.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 3, "Balance updates record is incorrect.");

        // After the final withdrawal, the vault share balance and eligible balance should both be zero.
        uint256 finalShares = boringVault.balanceOf(address(this));
        assertEq(finalShares, 0, "Final vault share balance should be zero");
        uint256 finalEligible = boringVault.getUserEligibleBalance(address(this));
        assertEq(finalEligible, 0, "Final eligible balance should be zero");
    }


    function testFail_WithdrawExceedingBalance() external {
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

    // No current update, no upcoming update.
    function testFuzz_Deposit_RollOverMultipleEpochs_Withdraw(uint256 depositAmount, uint256 withdrawAmount, uint256 numEpochs) external {
        // Assume deposit and withdraw amounts are between 1e18 and 1e30.
        vm.assume(depositAmount > 1e18 && depositAmount < 1e30);
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);
        vm.assume(depositAmount > withdrawAmount);
        
        // Set our number of epochs to roll over (between 2 and 4).
        uint256 epochs = numEpochs % 3 + 2;

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), depositAmount);
        token.approve(address(boringVault), depositAmount);
        
        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Roll over the epochs.
        for (uint256 i = 0; i < epochs; i++) {
            boringVault.rollOverEpoch();
        }

        // Withdraw the tokens from the vault.
        teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));

        // Check the balanceUpdates record.
        // We should have two balance updates, one for the deposit and one for the withdrawal.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 2, "Balance updates record is incorrect.");

        (uint256 recEpoch, uint256 recBalance) = boringVault.balanceUpdates(address(this), 1);
        assertEq(recEpoch, boringVault.currentEpoch(), "Balance update epoch should be currentEpoch");
        assertEq(recBalance, depositAmount - withdrawAmount, "Balance update balance should be depositAmount - withdrawAmount");
    }

    // Current update, no upcoming update.
    function testFuzz_Deposit_RollOver_Withdraw(uint256 depositAmount, uint256 withdrawAmount) external {
        // Assume deposit and withdraw amounts are between 1e18 and 1e30.
        vm.assume(depositAmount > 1e18 && depositAmount < 1e30);
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);
        vm.assume(depositAmount > withdrawAmount);

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), depositAmount);
        token.approve(address(boringVault), depositAmount);
        
        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Roll over the epoch.
        boringVault.rollOverEpoch();

        // Withdraw the tokens from the vault.
        teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));

        // Check the balanceUpdates record.
        // We should have two balance updates, one for the deposit and one for the withdrawal.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 1, "Balance updates record is incorrect.");

        (uint256 recEpoch, uint256 recBalance) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recEpoch, boringVault.currentEpoch(), "Balance update epoch should be currentEpoch");
        assertEq(recBalance, depositAmount - withdrawAmount, "Balance update balance should be depositAmount - withdrawAmount");
    }
    
    // No current update, upcoming update.
    function testFuzz_DepositWithdraw_SameEpoch(uint256 amount) external {
        // Assume deposit and withdraw amounts are between 1e18 and 1e30.
        vm.assume(amount > 1e18 && amount < 1e30);

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), amount);
        token.approve(address(boringVault), amount);

        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), amount, 0);

        // Check the balanceUpdates record.
        // We should be updating the next epoch's eligibleBalance.
        // We should have only a single balance update record, since this was our first action. 
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 1, "Balance updates record is incorrect.");
        
        (uint256 recEpoch, uint256 recBalance) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recEpoch, boringVault.currentEpoch() + 1, "Balance update epoch should be currentEpoch + 1");
        assertEq(recBalance, amount, "Balance update balance should match deposit amount");

        // Withdraw the tokens from the vault. 
        // NOTE: we haven't rolled over the epoch yet, so the balanceUpdates record length should not change.
        teller.bulkWithdraw(ERC20(address(token)), amount / 2, 0, address(this));

        // Check the balanceUpdates record.
        // We should have only a single balance update record, since we only had one before. 
        // However, since our eligibleBalance was all in the next epoch, we need to update the next epoch and nothing else.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 1, "Balance updates record is incorrect.");

        (uint256 recEpoch2, uint256 recBalance2) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recEpoch2, recEpoch, "Balance update epoch should not change");
        assertEq(recBalance2, recBalance - amount / 2, "Balance update balance should decrease by half");
    }

    // No current update, upcoming update.
    function testFuzz_DepositWithdraw_SameEpoch_ExistingBalance(uint256 depositAmount, uint256 withdrawAmount) external {
        // Assume deposit and withdraw amounts are between 1e18 and 1e30.
        vm.assume(depositAmount > 1e18 && depositAmount < 1e30);
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);
        vm.assume(depositAmount*2 > withdrawAmount);

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), depositAmount*2);
        token.approve(address(boringVault), depositAmount*2);

        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Roll over a few epochs.
        for (uint256 i = 0; i < 10; i++) {
            boringVault.rollOverEpoch();
        }

        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Check the balanceUpdates record.
        // We should be updating the next epoch's eligibleBalance.
        // We should have only a single balance update record, since this was our first action. 
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 2, "Balance updates record is incorrect.");
        
        (uint256 recEpoch, uint256 recBalance) = boringVault.balanceUpdates(address(this), 1);
        assertEq(recEpoch, boringVault.currentEpoch() + 1, "Balance update epoch should be currentEpoch + 1");
        assertEq(recBalance, depositAmount*2, "Balance update balance should match deposit amounts");

        // Withdraw the tokens from the vault. 
        // NOTE: we haven't rolled over the epoch yet.
        teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));

        // Check the balanceUpdates record.
        // We should now have 3 balance updates, since we have 2 deposits and 1 withdrawal.
        // The first should be the initial deposit and it should remain the same as before.
        // The second should be this withdrawal and it should be in the current epoch.
        // The eligibleBalance should be deposit1 - withdraw1.
        // The third one should be the second deposit and it should be in the next epoch. 
        // The eligibleBalance should be (deposit1+deposit2) - withdraw1.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 3, "Balance updates record is incorrect.");

        (uint256 recEpoch2, uint256 recBalance2) = boringVault.balanceUpdates(address(this), 1);
        assertEq(recEpoch2, boringVault.currentEpoch(), "Balance update epoch should be currentEpoch");
        if(withdrawAmount > depositAmount) {
            assertEq(recBalance2, 0, "Balance update balance should be 0");
        } else {
            assertEq(recBalance2, depositAmount - withdrawAmount, "Balance update balance should be depositAmount - withdrawAmount");
        }

        (uint256 recEpoch3, uint256 recBalance3) = boringVault.balanceUpdates(address(this), 2);
        assertEq(recEpoch3, boringVault.currentEpoch() + 1, "Balance update epoch should be currentEpoch + 1");
        assertEq(recBalance3, depositAmount*2 - withdrawAmount, "Balance update balance should be depositAmount*2 - withdrawAmount");
    }

    // Current update, upcoming update.
    function testFuzz_Deposit_RollOver_Deposit_Withdraw(uint256 depositAmount, uint256 withdrawAmount) external {
        // Assume deposit and withdraw amounts are between 1e18 and 1e30.
        vm.assume(depositAmount > 1e18 && depositAmount < 1e30);
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);
        vm.assume(depositAmount*2 > withdrawAmount && depositAmount < withdrawAmount);

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), depositAmount*2);
        token.approve(address(boringVault), depositAmount*2);

        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Roll over the epoch.
        boringVault.rollOverEpoch();

        // Deposit the tokens into the vault.
        teller.deposit(ERC20(address(token)), depositAmount, 0);

        // We should have 2 balance updates, one for the initial deposit and one for the second deposit.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 2, "Balance updates record is incorrect.");

        // Withdraw the tokens from the vault.
        teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));
        
        // We should have 2 balance updates, one for the initial deposit and one for the second deposit.
        // The withdrawal should have subtracted from the eligibleBalance in the next epoch and the previous epoch 
        // if necessary.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 2, "Balance updates record is incorrect.");

        // Next epoch's eligibleBalance should be depositAmount - withdrawAmount.
        (uint256 recEpoch, uint256 recBalance) = boringVault.balanceUpdates(address(this), 0);
        assertEq(recEpoch, boringVault.currentEpoch(), "Balance update epoch should be currentEpoch");
        assertEq(recBalance, 0, "Balance update balance should be depositAmount - withdrawAmount");

        (uint256 recEpoch2, uint256 recBalance2) = boringVault.balanceUpdates(address(this), 1);
        assertEq(recEpoch2, boringVault.currentEpoch() + 1, "Balance update epoch should be currentEpoch + 1");
        assertEq(recBalance2, depositAmount*2 - withdrawAmount, "Balance update balance should be depositAmount*2 - withdrawAmount");
    }

    // Fuzz test that randomly deposits, withdraws, and rolls over epochs.
    function testFuzz_DepositWithdraw_Random(uint256 depositAmount, uint256 withdrawAmount, uint256 seed) external {
        // Assume deposit and withdraw amounts are between 1e18 and 1e30.
        vm.assume(depositAmount > 1e18 && depositAmount < 1e30);
        vm.assume(withdrawAmount > 1e18 && withdrawAmount < 1e30);
        vm.assume(depositAmount > withdrawAmount || (depositAmount*2 > withdrawAmount && depositAmount < withdrawAmount));

        // Set iteration count.
        uint256 iterations = seed % 64 + 1;
        uint256 lastDecision;

        // Mint the tokens to this contract. Aprove it for the withdraw amount.
        token.mint(address(this), depositAmount*64);
        
        // Deposit the tokens into the vault.
        // We do this to ensure that the vault has a balance before we start withdrawing.
        token.approve(address(boringVault), depositAmount*2);
        teller.deposit(ERC20(address(token)), depositAmount*2, 0);

        // Roll over the epochs.
        for (uint256 i = 0; i < iterations; i++) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint256 decision = seed % 3;
            if(decision == 0) {
                // Deposit.
                teller.deposit(ERC20(address(token)), depositAmount, 0);
            } else if(decision == 1) {
                boringVault.rollOverEpoch();

                // Withdraw if we have enough balance.
                if(boringVault.balanceOf(address(this)) > withdrawAmount) {
                    teller.bulkWithdraw(ERC20(address(token)), withdrawAmount, 0, address(this));
                }
            } else {
                // Roll over.
                boringVault.rollOverEpoch();
            }

            // Need to store last decision for checks in the next iteration.
            lastDecision = decision;
        }
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
            finalVaultBalanceThis, depositAmount - transferShares, "address(this) final vault shares are incorrect."
        );

        // anotherUser should have exactly 40 shares.
        assertEq(finalVaultBalanceAnother, transferShares, "anotherUser final vault shares are incorrect.");

        // We should have 2 balance updates, one for the initial deposit and one for the transfer.
        assertEq(boringVault.getTotalBalanceUpdates(address(this)), 2, "Balance updates record is incorrect.");

        // Check the balanceUpdates record for address(this).
        (uint256 recEpoch, uint256 recBalance) = boringVault.balanceUpdates(address(this), 1);
        assertEq(recEpoch, boringVault.currentEpoch(), "Balance update epoch should be currentEpoch");
        assertEq(recBalance, depositAmount - transferShares, "Balance update balance should be depositAmount - transferShares");

        // Check the balanceUpdates record for anotherUser.
        // They should have 1 balance update, for the transfer.
        assertEq(boringVault.getTotalBalanceUpdates(anotherUser), 1, "Balance updates record is incorrect.");

        (uint256 recEpoch2, uint256 recBalance2) = boringVault.balanceUpdates(anotherUser, 0);
        assertEq(recEpoch2, boringVault.currentEpoch() + 1, "Balance update epoch should be currentEpoch");
        assertEq(recBalance2, transferShares, "Balance update balance should be transferShares");
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
        (,, uint256 endTimestampBefore) = boringVault.epochs(initialEpoch);
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
        (,, uint256 previousEpochEnd) = boringVault.epochs(initialEpoch);
        assertGt(previousEpochEnd, 0, "Previous epoch endTimestamp should be > 0 after rollover");
        // Use an approximate equality check (tolerance of 2 seconds) for block.timestamp.
        assertApproxEqAbs(previousEpochEnd, block.timestamp, 2, "Previous epoch endTimestamp not close to current time");

        // ----- Check new epoch data -----
        (, uint256 newEpochStart,) = boringVault.epochs(newEpoch);
        // The new epoch's startTimestamp should be near the current block.timestamp.
        assertApproxEqAbs(newEpochStart, block.timestamp, 2, "New epoch startTimestamp not set correctly");

        // The new epoch's eligibleShares should be rolled over from the previous epoch.
        // According to _rollOverEpoch(), if the upcoming epoch's eligibleShares is 0,
        // it gets set to current epoch's eligibleShares.
        (uint256 eligibleNew,,) = boringVault.epochs(newEpoch);
        assertEq(
            eligibleNew, depositAmount, "New epoch eligibleShares should equal the previous epoch's eligible shares"
        );

        // ----- Check user balance update records -----
        // (Assuming you have a helper function getTotalBalanceUpdates(address) that returns the length of balanceUpdates for a user.)
        uint256 updatesLength = boringVault.getTotalBalanceUpdates(address(this));
        // The latest balance update record should correspond to the new epoch.
        (uint256 lastUpdateEpoch, uint256 lastRecordedBalance) =
            boringVault.balanceUpdates(address(this), updatesLength - 1);
        assertEq(lastUpdateEpoch, newEpoch, "Latest balance update epoch should be the new epoch");
        assertEq(
            lastRecordedBalance,
            boringVault.balanceOf(address(this)),
            "Latest recorded balance does not match current vault balance"
        );
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
            (,, uint256 prevEpochEnd) = boringVault.epochs(currentEpoch - 1);
            assertGt(prevEpochEnd, 0, "Previous epoch endTimestamp should be > 0 after rollover");
            assertApproxEqAbs(prevEpochEnd, block.timestamp, 2, "Previous epoch endTimestamp not close to current time");

            // Check the new epoch's startTimestamp.
            (, uint256 currentEpochStart,) = boringVault.epochs(currentEpoch);
            assertApproxEqAbs(currentEpochStart, block.timestamp, 2, "New epoch startTimestamp not set correctly");

            // Check that the new epoch's eligibleShares has been rolled over correctly.
            // Since no additional deposits occurred, it should equal the depositAmount.
            (uint256 eligibleShares,,) = boringVault.epochs(currentEpoch);
            assertEq(eligibleShares, depositAmount, "New epoch eligibleShares should equal the initial deposit amount");
        }

        // After all rollovers, verify the user's final balance update.
        uint256 lastRecordedBalance = boringVault.getUserEligibleBalance(address(this));
        assertEq(
            lastRecordedBalance,
            boringVault.balanceOf(address(this)),
            "Latest recorded balance does not match vault balance"
        );
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

        uint128[] memory startEpochArray = new uint128[](3);
        startEpochArray[0] = 0;
        startEpochArray[1] = 1;
        startEpochArray[2] = 1;

        uint128[] memory endEpochArray = new uint128[](3);
        endEpochArray[0] = 1;
        endEpochArray[1] = 2;
        endEpochArray[2] = 3;

        // Approve the reward tokens for the vault (boringSafe) to pull the tokens.
        token.approve(address(boringVault), 60e18);
        rewardToken1.approve(address(boringVault), 12e18);
        rewardToken2.approve(address(boringVault), 10e18);

        // Distribute the rewards.
        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);

        // --- Check that the rewards have been transferred to the safe ---
        assertEq(
            token.balanceOf(address(boringVault.boringSafe())), 60e18, "Deposit token not correctly transferred to safe"
        );
        assertEq(
            rewardToken1.balanceOf(address(boringVault.boringSafe())),
            12e18,
            "Reward token 1 not correctly transferred to safe"
        );
        assertEq(
            rewardToken2.balanceOf(address(boringVault.boringSafe())),
            10e18,
            "Reward token 2 not correctly transferred to safe"
        );

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
            (, uint256 epoch0Start, uint256 epoch0End) = boringVault.epochs(0);
            (, uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);
            // Total duration for reward 0 is from epoch0.startTimestamp to epoch0.endTimestamp plus epoch1 duration.
            uint256 duration0 = (epoch0End - epoch0Start) + (epoch1End - epoch1Start);
            uint256 totalReward0 = rRate0.mulWadDown(duration0);
            assertApproxEqAbs(totalReward0, 60e18, 1e6, "Total distributed reward for reward 0 mismatch");

            // Since our user's had no eligible shares at epoch 0, we need to calculate exactly how many rewards they are owed.
            // Since we have 3 users, we divide the total reward by 3.
            duration0 = (epoch1End - epoch1Start);
            uint256 userReward0 = (rRate0.mulWadDown(duration0)).divWadDown(3e18);

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 0), userReward0, 1e12, "User should have 20 reward 0"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 0), userReward0, 1e12, "TestUser should have 20 reward 0"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 0),
                userReward0,
                1e12,
                "AnotherUser should have 20 reward 0"
            );
        }

        // Reward 1: Distribution for rewardToken1 from epoch 1 to 2.
        {
            (address rToken1, uint256 rRate1, uint256 rStart1, uint256 rEnd1) = boringVault.rewards(1);
            assertEq(rToken1, address(rewardToken1), "Reward 1 token mismatch");
            assertEq(rStart1, 1, "Reward 1 startEpoch mismatch");
            assertEq(rEnd1, 2, "Reward 1 endEpoch mismatch");
            // Retrieve epoch data for epochs 1 and 2.
            (, uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);
            (, uint256 epoch2Start, uint256 epoch2End) = boringVault.epochs(2);
            // Total duration for reward 1 is from epoch1.startTimestamp to epoch1.endTimestamp plus epoch2 duration.
            uint256 duration1 = (epoch1End - epoch1Start) + (epoch2End - epoch2Start);
            uint256 totalReward1 = rRate1.mulWadDown(duration1);
            assertApproxEqAbs(totalReward1, 12e18, 1e6, "Total distributed reward for reward 1 mismatch");

            // Calculate the reward for each user.
            uint256 userReward1 = totalReward1.divWadDown(3e18);

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 1), userReward1, 1e12, "User should have 4 reward 1"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 1), userReward1, 1e12, "TestUser should have 4 reward 1"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 1),
                userReward1,
                1e12,
                "AnotherUser should have 4 reward 1"
            );
        }

        // Reward 2: Distribution for rewardToken2 from epoch 1 to 3.
        {
            (address rToken2, uint256 rRate2, uint256 rStart2, uint256 rEnd2) = boringVault.rewards(2);
            assertEq(rToken2, address(rewardToken2), "Reward 2 token mismatch");
            assertEq(rStart2, 1, "Reward 2 startEpoch mismatch");
            assertEq(rEnd2, 3, "Reward 2 endEpoch mismatch");
            // Retrieve epoch data for epochs 1 and 2.
            (, uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);
            (, uint256 epoch2Start, uint256 epoch2End) = boringVault.epochs(2);
            (, uint256 epoch3Start, uint256 epoch3End) = boringVault.epochs(3);
            // Total duration for reward 2 is from epoch1.startTimestamp to epoch1.endTimestamp plus epoch2 duration plus epoch3 duration.
            uint256 duration2 = (epoch1End - epoch1Start) + (epoch2End - epoch2Start) + (epoch3End - epoch3Start);
            uint256 totalReward2 = rRate2.mulWadDown(duration2);
            assertApproxEqAbs(totalReward2, 10e18, 1e6, "Total distributed reward for reward 2 mismatch");

            // Calculate the reward for each user.
            uint256 userReward2 = totalReward2.divWadDown(3e18);

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 2), userReward2, 1e12, "User should have 4 reward 2"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 2), userReward2, 1e12, "TestUser should have 4 reward 2"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 2),
                userReward2,
                1e12,
                "AnotherUser should have 4 reward 2"
            );
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

        uint128[] memory startEpochArray = new uint128[](1);
        startEpochArray[0] = 2;

        uint128[] memory endEpochArray = new uint128[](1);
        endEpochArray[0] = 0;

        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);
    }

    function testFailDistributeRewardsEndEpochInFuture() external {
        boringVault.rollOverEpoch();

        address[] memory tokenArray = new address[](1);
        tokenArray[0] = address(token);

        uint256[] memory amountArray = new uint256[](1);
        amountArray[0] = 100e18;

        uint128[] memory startEpochArray = new uint128[](1);
        startEpochArray[0] = 0;

        uint128[] memory endEpochArray = new uint128[](1);
        endEpochArray[0] = 2;

        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);
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

        uint128[] memory startEpochArray = new uint128[](1);
        startEpochArray[0] = 1;

        uint128[] memory endEpochArray = new uint128[](1);
        endEpochArray[0] = 1;

        // Approve the reward tokens for the vault (boringSafe) to pull the tokens.
        rewardToken1.approve(address(boringVault), 100e18);

        // Distribute the rewards.
        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);

        // --- Check that the rewards have been transferred to the safe ---
        assertEq(
            rewardToken1.balanceOf(address(boringVault.boringSafe())),
            100e18,
            "Reward token 1 not correctly transferred to safe"
        );

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
            (, uint256 epoch1Start, uint256 epoch1End) = boringVault.epochs(1);

            // Total duration for reward 0 is from epoch0.startTimestamp to epoch0.endTimestamp plus epoch1 duration.
            uint256 duration0 = (epoch1End - epoch1Start);
            uint256 totalReward0 = rRate0.mulWadDown(duration0);
            assertApproxEqAbs(totalReward0, 100e18, 1e6, "Total distributed reward for reward 0 mismatch");

            // Since our user's had no eligible shares at epoch 0, we need to calculate exactly how many rewards they are owed.
            uint256 userReward0 = (rRate0.mulWadDown(duration0));

            // Check that the reward has been distributed to the correct users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 0), userReward0, 1e12, "User should have 100 reward 0"
            );
        }
    }

    function testComplexRewardDistribution() external {
        // ─────────────────────────────────────────────────────────────
        // SETUP: Roles and deploy additional reward tokens.
        // ─────────────────────────────────────────────────────────────
        rolesAuthority.setUserRole(testUser, DEPOSITOR_ROLE, true);
        rolesAuthority.setUserRole(anotherUser, DEPOSITOR_ROLE, true);
        rolesAuthority.setRoleCapability(DEPOSITOR_ROLE, address(teller), teller.deposit.selector, true);
        rolesAuthority.setRoleCapability(DEPOSITOR_ROLE, address(teller), teller.bulkWithdraw.selector, true);

        // Deploy three reward tokens.
        MockERC20 rewardToken1 = new MockERC20("Reward Token 1", "RT1", 18);
        MockERC20 rewardToken2 = new MockERC20("Reward Token 2", "RT2", 18);
        MockERC20 rewardToken3 = new MockERC20("Reward Token 3", "RT3", 18);

        // Mint reward tokens.
        rewardToken1.mint(address(this), 200e18);
        rewardToken2.mint(address(this), 200e18);
        rewardToken3.mint(address(this), 200e18);

        // ─────────────────────────────────────────────────────────────
        // DEPOSITS AT DIFFERENT TIMES (Different epochs and amounts)
        // Note: Deposits are recorded for the upcoming epoch (currentEpoch + 1).
        // Since they aren't registered until the next epoch, they are not eligible for rewards.
        // Epoch 1: 100 tokens -- Address(this) deposits 100 tokens.
        // Epoch 2: 250 tokens -- testUser deposits 150 tokens.
        // Epoch 3: 500 tokens -- anotherUser deposits 200 tokens and Address(this) deposits an additional 50 tokens.
        // Epoch 4: 500 tokens -- rolled over from epoch3.
        // ─────────────────────────────────────────────────────────────

        // (1) Address(this) deposits 100 tokens.
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0); // recorded for epoch1
        skip(50); // simulate 50 seconds
        boringVault.rollOverEpoch(); // currentEpoch becomes 1

        // (2) testUser deposits 150 tokens.
        vm.startPrank(testUser);
        token.approve(address(boringVault), 150e18);
        teller.deposit(ERC20(address(token)), 150e18, 0); // recorded for epoch2
        vm.stopPrank();
        skip(100);
        boringVault.rollOverEpoch(); // currentEpoch becomes 2

        // (3) anotherUser deposits 200 tokens and Address(this) deposits an additional 50 tokens.
        vm.startPrank(anotherUser);
        token.approve(address(boringVault), 200e18);
        teller.deposit(ERC20(address(token)), 200e18, 0); // recorded for epoch3
        vm.stopPrank();
        token.approve(address(boringVault), 50e18);
        teller.deposit(ERC20(address(token)), 50e18, 0); // recorded for epoch3
        skip(200);
        boringVault.rollOverEpoch(); // currentEpoch becomes initialEpoch+3
        skip(300);
        boringVault.rollOverEpoch(); // currentEpoch becomes initialEpoch+4
        skip(100);
        boringVault.rollOverEpoch(); // currentEpoch becomes initialEpoch+5

        // ─────────────────────────────────────────────────────────────
        // REWARD DISTRIBUTIONS:
        // Reward 0: token from epoch1 to epoch3, total = 60e18.
        // Reward 1: rewardToken1 from epoch2 to epoch4, total = 20e18.
        // Reward 2: rewardToken2 from epoch1 to epoch4, total = 30e18.
        // Reward 3: rewardToken3 from epoch3 to epoch3, total = 10e18.
        // ─────────────────────────────────────────────────────────────
        address[] memory tokenArray = new address[](4);
        tokenArray[0] = address(token);
        tokenArray[1] = address(rewardToken1);
        tokenArray[2] = address(rewardToken2);
        tokenArray[3] = address(rewardToken3);

        uint256[] memory amountArray = new uint256[](4);
        amountArray[0] = 60e18;
        amountArray[1] = 20e18;
        amountArray[2] = 30e18;
        amountArray[3] = 10e18;

        uint128[] memory startEpochArray = new uint128[](4);
        startEpochArray[0] = 1;
        startEpochArray[1] = 2;
        startEpochArray[2] = 1;
        startEpochArray[3] = 3;

        uint128[] memory endEpochArray = new uint128[](4);
        endEpochArray[0] = 3;
        endEpochArray[1] = 4;
        endEpochArray[2] = 4;
        endEpochArray[3] = 3;

        // Approve reward tokens for safe.
        token.approve(address(boringVault), 60e18);
        rewardToken1.approve(address(boringVault), 20e18);
        rewardToken2.approve(address(boringVault), 30e18);
        rewardToken3.approve(address(boringVault), 10e18);

        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);

        // Check rewards in the safe.
        assertEq(token.balanceOf(address(boringVault.boringSafe())), 60e18, "Deposit token not in safe");
        assertEq(rewardToken1.balanceOf(address(boringVault.boringSafe())), 20e18, "Reward token 1 not in safe");
        assertEq(rewardToken2.balanceOf(address(boringVault.boringSafe())), 30e18, "Reward token 2 not in safe");
        assertEq(rewardToken3.balanceOf(address(boringVault.boringSafe())), 10e18, "Reward token 3 not in safe");
        assertEq(boringVault.maxRewardId(), 4, "maxRewardId should be 4");

        // ─────────────────────────────────────────────────────────────
        // Retrieve epoch data for epochs 1 to 4 using a memory array to reduce locals.
        // Each element: [eligibleShares, startTimestamp, endTimestamp]
        uint256[3][] memory epData = new uint256[3][](4);
        for (uint256 i = 0; i < 4; i++) {
            (epData[i][0], epData[i][1], epData[i][2]) = boringVault.epochs(i + 1);
        }
        uint256 d1 = epData[0][2] - epData[0][1];
        uint256 d2 = epData[1][2] - epData[1][1];
        uint256 d3 = epData[2][2] - epData[2][1];
        uint256 d4 = epData[3][2] - epData[3][1];

        // Expected eligible shares:
        // Epoch1: only address(this) with 100e18.
        // Epoch2: only testUser with 150e18.
        // Epoch3: address(this) has 150e18 + anotherUser has 200e18 = 350e18.
        // Epoch4: rolled over from epoch3 = 350e18.
        {
            assertEq(epData[0][0], 100e18, "Epoch1 eligible mismatch");
            assertEq(epData[1][0], 250e18, "Epoch2 eligible mismatch");
            assertEq(epData[2][0], 500e18, "Epoch3 eligible mismatch");
            assertEq(epData[3][0], 500e18, "Epoch4 eligible mismatch");
        }

        // Expected per-user balances:
        // Address(this): 100 in epoch1; then 150 in epochs>=3.
        // testUser: 0 for epochs <2; 150 for epochs>=2.
        // anotherUser: 0 for epochs <3; 200 for epochs>=3.

        // ─────────────────────────────────────────────────────────────
        // REWARD 0: token reward from epoch1 to epoch3, total = 60e18.
        {
            // Calculate the reward amounts for each epoch.
            uint256 totalDur0 = d1 + d2 + d3;
            uint256 rRate0 = amountArray[0].divWadDown(totalDur0);
            uint256 r0_e1 = rRate0.mulWadDown(d1);
            uint256 r0_e2 = rRate0.mulWadDown(d2);
            uint256 r0_e3 = rRate0.mulWadDown(d3);

            // Calculate the reward amounts for each user.
            // Owner has 100e18 in epoch1 and 150e18 in epochs>=3.
            uint256 r0_e1_owner = r0_e1;
            uint256 r0_e2_owner = r0_e2.mulWadDown(100e18).divWadDown(250e18);
            uint256 r0_e3_owner = r0_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected0_owner = r0_e1_owner + r0_e2_owner + r0_e3_owner;

            // testUser has 0 in epochs<2 and 150e18 in epochs>=2.
            uint256 r0_e2_test = r0_e2.mulWadDown(150e18).divWadDown(250e18);
            uint256 r0_e3_test = r0_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected0_test = r0_e2_test + r0_e3_test;

            // anotherUser has 0 in epochs<3 and 200e18 in epochs>=3.
            uint256 r0_e3_another = r0_e3.mulWadDown(200e18).divWadDown(500e18);
            uint256 expected0_another = r0_e3_another;

            // Test that total reward is correct.
            uint256 totalReward0 = rRate0.mulWadDown(totalDur0);
            assertApproxEqAbs(totalReward0, 60e18, 1e6, "Total distributed reward for reward 0 mismatch");

            // Check that the rewards have been distributed correctly to users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 0), expected0_owner, 1e12, "Reward0: owner mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 0), expected0_test, 1e12, "Reward0: testUser mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 0),
                expected0_another,
                1e12,
                "Reward0: anotherUser mismatch"
            );
        }

        // ─────────────────────────────────────────────────────────────
        // REWARD 1: rewardToken1 from epoch2 to epoch4, total = 20e18.
        {
            // Calculate the reward amounts for each epoch.
            uint256 totalDur1 = d2 + d3 + d4;
            uint256 rRate1 = amountArray[1].divWadDown(totalDur1);
            uint256 r1_e2 = rRate1.mulWadDown(d2);
            uint256 r1_e3 = rRate1.mulWadDown(d3);
            uint256 r1_e4 = rRate1.mulWadDown(d4);

            // Calculate the reward amounts for each user.
            // Owner has 100e18 in epoch1 and 150e18 in epochs>=3.
            uint256 r1_e2_owner = r1_e2.mulWadDown(100e18).divWadDown(250e18);
            uint256 r1_e3_owner = r1_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 r1_e4_owner = r1_e4.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected1_owner = r1_e2_owner + r1_e3_owner + r1_e4_owner;

            // testUser has 0 in epochs<2 and 150e18 in epochs>=2.
            uint256 r1_e2_test = r1_e2.mulWadDown(150e18).divWadDown(250e18);
            uint256 r1_e3_test = r1_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 r1_e4_test = r1_e4.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected1_test = r1_e2_test + r1_e3_test + r1_e4_test;

            // anotherUser has 0 in epochs<3 and 200e18 in epochs>=3.
            uint256 r1_e3_another = r1_e3.mulWadDown(200e18).divWadDown(500e18);
            uint256 r1_e4_another = r1_e4.mulWadDown(200e18).divWadDown(500e18);
            uint256 expected1_another = r1_e3_another + r1_e4_another;

            // Test that total reward is correct.
            uint256 totalReward1 = rRate1.mulWadDown(totalDur1);
            assertApproxEqAbs(totalReward1, 20e18, 1e6, "Total distributed reward for reward 1 mismatch");

            // Check that the rewards have been distributed correctly to users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 1), expected1_owner, 1e12, "Reward1: owner mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 1), expected1_test, 1e12, "Reward1: testUser mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 1),
                expected1_another,
                1e12,
                "Reward1: anotherUser mismatch"
            );
        }

        // ─────────────────────────────────────────────────────────────
        // REWARD 2: rewardToken2 from epoch1 to epoch4, total = 30e18.
        {
            // Calculate the reward amounts for each epoch.
            uint256 totalDur2 = d1 + d2 + d3 + d4;
            uint256 rRate2 = amountArray[2].divWadDown(totalDur2);
            uint256 r2_e1 = rRate2.mulWadDown(d1);
            uint256 r2_e2 = rRate2.mulWadDown(d2);
            uint256 r2_e3 = rRate2.mulWadDown(d3);
            uint256 r2_e4 = rRate2.mulWadDown(d4);

            // Calculate the reward amounts for each user.
            // Owner has 100e18 in epoch1 and 150e18 in epochs>=3.
            uint256 r2_e1_owner = r2_e1;
            uint256 r2_e2_owner = r2_e2.mulWadDown(100e18).divWadDown(250e18);
            uint256 r2_e3_owner = r2_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 r2_e4_owner = r2_e4.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected2_owner = r2_e1_owner + r2_e2_owner + r2_e3_owner + r2_e4_owner;

            // testUser has 0 in epochs<2 and 150e18 in epochs>=2.
            uint256 r2_e2_test = r2_e2.mulWadDown(150e18).divWadDown(250e18);
            uint256 r2_e3_test = r2_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 r2_e4_test = r2_e4.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected2_test = r2_e2_test + r2_e3_test + r2_e4_test;

            // anotherUser has 0 in epochs<3 and 200e18 in epochs>=3.
            uint256 r2_e3_another = r2_e3.mulWadDown(200e18).divWadDown(500e18);
            uint256 r2_e4_another = r2_e4.mulWadDown(200e18).divWadDown(500e18);
            uint256 expected2_another = r2_e3_another + r2_e4_another;

            // Test that total reward is correct.
            uint256 totalReward2 = rRate2.mulWadDown(totalDur2);
            assertApproxEqAbs(totalReward2, 30e18, 1e6, "Total distributed reward for reward 2 mismatch");

            // Check that the rewards have been distributed correctly to users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 2), expected2_owner, 1e12, "Reward2: owner mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 2), expected2_test, 1e12, "Reward2: testUser mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 2),
                expected2_another,
                1e12,
                "Reward2: anotherUser mismatch"
            );
        }

        // ─────────────────────────────────────────────────────────────
        // REWARD 3: rewardToken3 from epoch3 to epoch3, total = 10e18.
        {
            // Calculate the reward amounts for each epoch.
            uint256 totalDur3 = d3;
            uint256 rRate3 = amountArray[3].divWadDown(totalDur3);
            uint256 r3_e3 = rRate3.mulWadDown(d3);

            // Calculate the reward amounts for each user.
            // Owner has 100e18 in epoch1 and 150e18 in epochs>=3.
            uint256 r3_e3_owner = r3_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected3_owner = r3_e3_owner;

            // testUser has 0 in epochs<2 and 150e18 in epochs>=2.
            uint256 r3_e3_test = r3_e3.mulWadDown(150e18).divWadDown(500e18);
            uint256 expected3_test = r3_e3_test;

            // anotherUser has 0 in epochs<3 and 200e18 in epochs>=3.
            uint256 r3_e3_another = r3_e3.mulWadDown(200e18).divWadDown(500e18);
            uint256 expected3_another = r3_e3_another;

            // Test that total reward is correct.
            uint256 totalReward3 = rRate3.mulWadDown(totalDur3);
            assertApproxEqAbs(totalReward3, 10e18, 1e6, "Total distributed reward for reward 3 mismatch");

            // Check that the rewards have been distributed correctly to users.
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(address(this), 3), expected3_owner, 1e12, "Reward3: owner mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(testUser, 3), expected3_test, 1e12, "Reward3: testUser mismatch"
            );
            assertApproxEqAbs(
                boringVault.getUserRewardBalance(anotherUser, 3),
                expected3_another,
                1e12,
                "Reward3: anotherUser mismatch"
            );
        }
    }

    // /*//////////////////////////////////////////////////////////////
    //                         CLAIMS
    // //////////////////////////////////////////////////////////////*/

    function testRewardClaiming() external {
        // ─────────────────────────────────────────────────────────────
        // SETUP: Roles and deploy additional reward tokens.
        // ─────────────────────────────────────────────────────────────
        rolesAuthority.setUserRole(testUser, DEPOSITOR_ROLE, true);
        rolesAuthority.setUserRole(anotherUser, DEPOSITOR_ROLE, true);
        rolesAuthority.setRoleCapability(DEPOSITOR_ROLE, address(teller), teller.deposit.selector, true);
        rolesAuthority.setRoleCapability(DEPOSITOR_ROLE, address(teller), teller.bulkWithdraw.selector, true);

        // Deploy three reward tokens.
        MockERC20 rewardToken1 = new MockERC20("Reward Token 1", "RT1", 18);
        MockERC20 rewardToken2 = new MockERC20("Reward Token 2", "RT2", 18);
        MockERC20 rewardToken3 = new MockERC20("Reward Token 3", "RT3", 18);

        // Mint reward tokens.
        rewardToken1.mint(address(this), 20e18);
        rewardToken2.mint(address(this), 30e18);
        rewardToken3.mint(address(this), 10e18);

        // ─────────────────────────────────────────────────────────────
        // DEPOSITS AT DIFFERENT TIMES (Different epochs and amounts)
        // Note: Deposits are recorded for the upcoming epoch (currentEpoch + 1).
        // Epoch 1: 100 tokens -- Address(this) deposits 100 tokens.
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0); // recorded for epoch 1
        skip(50); // simulate 50 seconds
        boringVault.rollOverEpoch(); // currentEpoch becomes 1

        // Epoch 2: 150 tokens -- testUser deposits 150 tokens.
        vm.startPrank(testUser);
        token.approve(address(boringVault), 150e18);
        teller.deposit(ERC20(address(token)), 150e18, 0); // recorded for epoch 2
        vm.stopPrank();
        skip(100);
        boringVault.rollOverEpoch(); // currentEpoch becomes 2

        // Epoch 3: 200 + 50 tokens -- anotherUser deposits 200 tokens and Address(this) deposits an additional 50 tokens.
        vm.startPrank(anotherUser);
        token.approve(address(boringVault), 200e18);
        teller.deposit(ERC20(address(token)), 200e18, 0); // recorded for epoch 3
        vm.stopPrank();
        token.approve(address(boringVault), 50e18);
        teller.deposit(ERC20(address(token)), 50e18, 0); // recorded for epoch 3

        skip(200);
        boringVault.rollOverEpoch(); // currentEpoch becomes 3
        skip(300);
        boringVault.rollOverEpoch(); // currentEpoch becomes 4
        skip(100);
        boringVault.rollOverEpoch(); // currentEpoch becomes 5

        // ─────────────────────────────────────────────────────────────
        // REWARD DISTRIBUTIONS:
        // Reward 0: token from epoch 1 to epoch 3, total = 60e18.
        // Reward 1: rewardToken1 from epoch 2 to epoch 4, total = 20e18.
        // Reward 2: rewardToken2 from epoch 1 to epoch 4, total = 30e18.
        // Reward 3: rewardToken3 from epoch 3 to epoch 3, total = 10e18.
        // ─────────────────────────────────────────────────────────────
        address[] memory tokenArray = new address[](4);
        tokenArray[0] = address(token);
        tokenArray[1] = address(rewardToken1);
        tokenArray[2] = address(rewardToken2);
        tokenArray[3] = address(rewardToken3);

        uint256[] memory amountArray = new uint256[](4);
        amountArray[0] = 60e18;
        amountArray[1] = 20e18;
        amountArray[2] = 30e18;
        amountArray[3] = 10e18;

        // Using uint128 for start/end epoch arrays to ease stack pressure.
        uint128[] memory startEpochArray = new uint128[](4);
        startEpochArray[0] = 1;
        startEpochArray[1] = 2;
        startEpochArray[2] = 1;
        startEpochArray[3] = 3;

        uint128[] memory endEpochArray = new uint128[](4);
        endEpochArray[0] = 3;
        endEpochArray[1] = 4;
        endEpochArray[2] = 4;
        endEpochArray[3] = 3;

        token.approve(address(boringVault), 60e18);
        rewardToken1.approve(address(boringVault), 20e18);
        rewardToken2.approve(address(boringVault), 30e18);
        rewardToken3.approve(address(boringVault), 10e18);

        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);

        // ─────────────────────────────────────────────────────────────
        // CLAIM REWARDS
        // ─────────────────────────────────────────────────────────────
        // Set up reward IDs.
        uint256[] memory rewardIds = new uint256[](4);
        rewardIds[0] = 0;
        rewardIds[1] = 1;
        rewardIds[2] = 2;
        rewardIds[3] = 3;

        // Claim rewards for owner.
        boringVault.claimRewards(rewardIds);

        // Claim rewards for testUser.
        vm.startPrank(testUser);
        boringVault.claimRewards(rewardIds);
        vm.stopPrank();

        // Claim rewards for anotherUser.
        vm.startPrank(anotherUser);
        boringVault.claimRewards(rewardIds);
        vm.stopPrank();

        // Ensure balances are correct for owner.
        assertEq(
            rewardToken1.balanceOf(address(this)),
            boringVault.getUserRewardBalance(address(this), 1),
            "Reward token 1 balance mismatch"
        );
        assertEq(
            rewardToken2.balanceOf(address(this)),
            boringVault.getUserRewardBalance(address(this), 2),
            "Reward token 2 balance mismatch"
        );
        assertEq(
            rewardToken3.balanceOf(address(this)),
            boringVault.getUserRewardBalance(address(this), 3),
            "Reward token 3 balance mismatch"
        );

        // Ensure balances are correct for testUser.
        assertEq(
            rewardToken1.balanceOf(testUser),
            boringVault.getUserRewardBalance(testUser, 1),
            "Reward token 1 balance mismatch"
        );
        assertEq(
            rewardToken2.balanceOf(testUser),
            boringVault.getUserRewardBalance(testUser, 2),
            "Reward token 2 balance mismatch"
        );
        assertEq(
            rewardToken3.balanceOf(testUser),
            boringVault.getUserRewardBalance(testUser, 3),
            "Reward token 3 balance mismatch"
        );

        // Ensure balances are correct for anotherUser.
        assertEq(
            rewardToken1.balanceOf(anotherUser),
            boringVault.getUserRewardBalance(anotherUser, 1),
            "Reward token 1 balance mismatch"
        );
        assertEq(
            rewardToken2.balanceOf(anotherUser),
            boringVault.getUserRewardBalance(anotherUser, 2),
            "Reward token 2 balance mismatch"
        );
        assertEq(
            rewardToken3.balanceOf(anotherUser),
            boringVault.getUserRewardBalance(anotherUser, 3),
            "Reward token 3 balance mismatch"
        );
    }

    function testComplexRewardClaiming() external {
        // ─────────────────────────────────────────────────────────────
        // DEPLOY REWARD TOKENS: Deploy 20 reward tokens.
        // ─────────────────────────────────────────────────────────────
        uint256 numRewardTokens = 20;
        MockERC20[] memory rewardTokens = new MockERC20[](numRewardTokens);
        for (uint256 i = 0; i < numRewardTokens; i++) {
            rewardTokens[i] = new MockERC20(
                string(abi.encodePacked("Reward Token ", uint2str(i))), string(abi.encodePacked("RT", uint2str(i))), 18
            );

            // Mint the reward tokens to the test contract.
            rewardTokens[i].mint(address(this), 100e18);
        }

        // ─────────────────────────────────────────────────────────────
        // SIMULATE MULTIPLE EPOCHS OF DEPOSITS:
        // We'll simulate 10 epochs.
        // For each epoch, each user deposits 10e18.
        // Each deposit is for 1e18 tokens.
        uint256 totalEpochs = 100;
        uint256 depositAmount = 1e18;

        // Iterate over each epoch.
        for (uint256 epoch = 0; epoch < totalEpochs; epoch++) {
            // Skip time.
            skip(100);

            if (epoch % 3 == 0) {
                // Mint the deposit amount to the user.
                token.mint(address(this), depositAmount);

                // Approve the deposit.
                token.approve(address(boringVault), depositAmount);

                // Deposit.
                teller.deposit(ERC20(address(token)), depositAmount, 0);
            }

            // // Mint the deposit amount to the user.
            // token.mint(address(this), depositAmount);

            // // Approve the deposit.
            // token.approve(address(boringVault), depositAmount);

            // // Deposit.
            // teller.deposit(ERC20(address(token)), depositAmount, 0);

            // Roll over the epoch.
            boringVault.rollOverEpoch();
        }

        // ─────────────────────────────────────────────────────────────
        // PREPARE REWARD CAMPAIGNS:
        // For each reward token, choose a campaign duration between 3 and 10 epochs.
        uint256 currentEpoch = boringVault.currentEpoch(); // should be ~10 after rollovers.
        uint128[] memory startEpochArray = new uint128[](numRewardTokens);
        uint128[] memory endEpochArray = new uint128[](numRewardTokens);
        uint256[] memory amountArray = new uint256[](numRewardTokens);

        for (uint256 i = 0; i < numRewardTokens; i++) {
            // 100 epochs in length.
            uint256 startEpoch = 0;
            uint256 duration = 100;

            uint256 endEpoch = startEpoch + duration;
            if (endEpoch >= currentEpoch) {
                endEpoch = currentEpoch - 1;
            }
            startEpochArray[i] = uint128(i);
            endEpochArray[i] = uint128(numRewardTokens + i);
            // Set reward amount: start at 1e18 and add i * 0.1e18.
            amountArray[i] = 1e18 + (i * 1e17);
        }

        // Build tokenArray from rewardTokens.
        address[] memory tokenArray = new address[](numRewardTokens);
        for (uint256 i = 0; i < numRewardTokens; i++) {
            tokenArray[i] = address(rewardTokens[i]);
        }

        // Ensure we are the owner.
        vm.startPrank(owner);

        // Approve reward tokens for distribution.
        for (uint256 i = 0; i < numRewardTokens; i++) {
            rewardTokens[i].approve(address(boringVault), amountArray[i]);
        }

        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);

        // ─────────────────────────────────────────────────────────────
        // CLAIM REWARDS:
        // All users claim rewards for all campaigns.
        uint256[] memory rewardIds = new uint256[](numRewardTokens);
        for (uint256 i = 0; i < numRewardTokens; i++) {
            rewardIds[i] = i;
        }

        // Claim rewards for the test contract.
        boringVault.claimRewards(rewardIds);
    }

    function testFailClaimRewardsAlreadyClaimed() external {
        // Just deposit some tokens.
        testFuzz_MultipleDeposits(100e18, 100e18);

        // Mint and prepare to distribute rewards.
        token.mint(address(this), 100e18);
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // It's currently epoch 1, let's roll it over.
        skip(100);
        boringVault.rollOverEpoch();

        // Distribute rewards.
        address[] memory tokenArray = new address[](1);
        tokenArray[0] = address(token);

        uint256[] memory amountArray = new uint256[](1);
        amountArray[0] = 100e18;

        uint128[] memory startEpochArray = new uint128[](1);
        startEpochArray[0] = 1;

        uint128[] memory endEpochArray = new uint128[](1);
        endEpochArray[0] = 1;

        // Distribute rewards.
        token.approve(address(boringVault), 100e18);
        boringVault.distributeRewards(tokenArray, amountArray, startEpochArray, endEpochArray);

        // Claim rewards.
        uint256[] memory rewardIds = new uint256[](1);
        rewardIds[0] = 0;
        boringVault.claimRewards(rewardIds);

        // // Try to claim rewards again.
        boringVault.claimRewards(rewardIds);
    }

    // Helper: convert uint256 to string.
    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

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
}

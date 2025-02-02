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

        // We want testUser to perform the deposit.
        // Use vm.prank to simulate a call from testUser.
        vm.startPrank(testUser);

        // Have testUser approve the vault to spend the deposit tokens.
        // (Assuming that testUser already has an initial balance; see setUp in your test contract.)
        token.approve(address(boringVault), depositAmount);

        // Call the deposit function on the teller.
        // The third parameter (minimumMint) is set to 0 for simplicity.
        uint256 sharesMinted = teller.deposit(ERC20(address(token)), depositAmount, 0);

        // Check that the vault's share balance for testUser increased correctly.
        // The balanceOf function inherited from ERC20 should now return sharesMinted for testUser.
        assertEq(boringVault.balanceOf(testUser), sharesMinted, "User share balance in vault is incorrect.");

        // Assuming the rate is 1:1, then the shares minted should equal the deposit amount.
        assertEq(sharesMinted, depositAmount, "Shares minted should equal the deposit amount under a 1:1 rate.");

        // Check that the user's token balance has decreased by the deposit amount.
        // (Assuming testUser started with 1,000e18 tokens, the new balance should be 900e18.)
        assertEq(token.balanceOf(testUser), 900e18, "User token balance did not decrease correctly.");

        // Check that the user's balance update record has been added for the upcoming epoch.
        // For this test we expect that there is at least one update. If this is the first deposit,
        // it should be stored at index 0.
        (uint256 recordedEpoch, uint256 recordedBalance) = boringVault.balanceUpdates(testUser, 0);
        // The update should be for epoch = currentEpoch + 1.
        uint256 expectedEpoch = boringVault.currentEpoch() + 1;
        assertEq(recordedEpoch, expectedEpoch, "The balance update epoch is not correct.");
        // The recorded balance should match the user's current share balance.
        assertEq(recordedBalance, boringVault.balanceOf(testUser), "The recorded user balance does not match the vault balance.");

        // Check that the upcoming epoch's eligibleShares equals the deposit amount.
        // Since this is the first deposit and assuming no other deposits have occurred, 
        // the upcoming epoch (currentEpoch + 1) should have eligibleShares equal to depositAmount.
        (uint256 epochEligibleShares, ,) = boringVault.epochs(expectedEpoch);
        assertEq(epochEligibleShares, depositAmount, "Upcoming epoch's eligible shares not updated correctly.");

        // End the prank.
        vm.stopPrank();
    }
    
    function testMultipleDeposits() external {}
    function testWithdrawPartial() external {}
    function testWithdrawAll() external {}
    function testFailWithdrawExceedingBalance() external {}
    function testDepositZero() external {}
    function testWithdrawZero() external {}

    /*//////////////////////////////////////////////////////////////
                            TRANSFERS
    //////////////////////////////////////////////////////////////*/
    function testBasicTransfer() external {}
    function testZeroTransfer() external {}
    function testTransferSelf() external {}
    function testFailTransferFromInsufficientAllowance() external {}
    function testTransferFromWithSufficientAllowance() external {}

    /*//////////////////////////////////////////////////////////////
                            EPOCH ROLLING
    //////////////////////////////////////////////////////////////*/
    function testManualEpochRollover() external {}
    function testMultipleEpochRollovers() external {}
    function testRolloverNoUsers() external {}

    /*//////////////////////////////////////////////////////////////
                            REWARDS
    //////////////////////////////////////////////////////////////*/
    function testDistributeRewardsValidRange() external {}
    function testFailDistributeRewardsStartEpochGreaterThanEndEpoch() external {}
    function testFailDistributeRewardsEndEpochInFuture() external {}
    function testFailDistributeRewardsInsufficientTokenBalance() external {}
    function testSingleEpochRewardDistribution() external {}

    /*//////////////////////////////////////////////////////////////
                            CLAIMS
    //////////////////////////////////////////////////////////////*/
    function testClaimFullRange() external {}
    function testClaimPartialEpochParticipation() external {}
    function testClaimZeroTotalShares() external {}
    function testClaimAlreadyClaimed() external {}
    function testClaimMultipleRewards() external {}

    /*//////////////////////////////////////////////////////////////
                            USER SHARE ACCOUNTING
    //////////////////////////////////////////////////////////////*/
    function testFindUserBalanceAtEpochNoDeposits() external {}
    function testFindUserBalanceAtEpochAllUpdatesAfter() external {}
    function testFindUserBalanceAtEpochExactMatch() external {}
    function testFindUserBalanceAtEpochMultipleUpdates() external {}

    /*//////////////////////////////////////////////////////////////
                            USER SHARE ACCOUNTING
    //////////////////////////////////////////////////////////////*/
    function testUpdateUserShareAccountingSameEpochMultipleTimes() external {}
    function testUpdateUserShareAccountingBrandNewEpoch() external {}
    function testUpdateUserShareAccountingEmpty() external {}

    /*//////////////////////////////////////////////////////////////
                            ROLE-BASED SECURITY
    //////////////////////////////////////////////////////////////*/
    function testFailDistributeRewardsUnauthorized() external {}
    function testDistributeRewardsByOwner() external {}

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION & EDGE CASES
    //////////////////////////////////////////////////////////////*/
    function testMultipleUsersIntegration() external {}
    function testZeroDurationEpoch() external {}
    function testLargeRewards() external {}
    function testFractionalDivisionsRounding() external {}
    function testStressManyEpochs() external {}
}
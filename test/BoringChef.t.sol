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
        // Deposit 100 tokens into the vault.
        token.approve(address(boringVault), 100e18);
        teller.deposit(ERC20(address(token)), 100e18, 0);

        // // Check that the user's balance is 100e18.
        // assertEq(boringVault.balanceOf(testUser), 100e18);
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


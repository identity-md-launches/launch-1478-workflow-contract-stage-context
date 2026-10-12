// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev The only holders are the four actors. No balances are changed with cheatcodes.
contract LaunchTokenTransferHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedTransfers;

    constructor(LaunchToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = 1e27;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amount) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        transfers++;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        amount = bound(amount, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        delegatedTransfers++;
    }

    function rejectOverspend(uint8 fromSeed, uint8 toSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 balance = expectedBalance[from];
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        token.transfer(to, balance + 1);
        rejectedTransfers++;
    }

    function revokeThenReject(uint8 ownerSeed, uint8 spenderSeed) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        vm.prank(owner);
        token.approve(spender, 0);
        expectedAllowance[owner][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(owner, spender, 1);
        rejectedTransfers++;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenPropertiesTest is Test {
    LaunchToken private token;
    LaunchTokenTransferHandler private handler;
    address[4] private actors;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        token = new LaunchToken();
        actors =
            [makeAddr("token-holder"), makeAddr("token-buyer"), makeAddr("token-spender"), makeAddr("token-recipient")];
        token.transfer(actors[0], 1e27);
        handler = new LaunchTokenTransferHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.revokeThenReject.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @dev Checks every holder and approval against inputs, not only a global supply getter.
    function invariant_supplyBalancesAndSpendingAuthorityAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]), "holder balance");
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]), "approval"
                );
            }
        }
        assertEq(sum, 1e27, "closed set of holders conserves supply");
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function test_handlerReachesNonzeroDelegatedAndRejectedTransfers() public {
        handler.transfer(0, 1, 200);
        handler.approve(1, 2, 150);
        handler.transferFrom(1, 2, 3, 100);
        handler.transferFrom(1, 2, 1, 50); // Self-transfer still spends a finite allowance.
        handler.rejectOverspend(1, 0);
        handler.revokeThenReject(0, 2);
        invariant_supplyBalancesAndSpendingAuthorityAreConserved();
        assertEq(token.balanceOf(actors[3]), 100);
        assertEq(handler.delegatedTransfers(), 2);
        assertEq(handler.rejectedTransfers(), 2);
    }

    function test_zeroOneAndEntireSupplyTransfersEmitExactAmounts() public {
        vm.startPrank(actors[0]);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(actors[0], actors[1], 0);
        token.transfer(actors[1], 0);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(actors[0], actors[1], 1);
        token.transfer(actors[1], 1);
        token.transfer(actors[1], 1e27 - 1);
        vm.stopPrank();
        assertEq(token.balanceOf(actors[0]), 0);
        assertEq(token.balanceOf(actors[1]), 1e27);
        vm.prank(actors[1]);
        token.transfer(actors[0], 1e27);
        assertEq(token.balanceOf(actors[0]), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_failedDelegatedTransferRestoresConsumedAllowance() public {
        vm.prank(actors[1]);
        token.approve(actors[2], type(uint256).max - 1);
        vm.prank(actors[2]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actors[1], 0, 1));
        token.transferFrom(actors[1], actors[3], 1);
        assertEq(token.allowance(actors[1], actors[2]), type(uint256).max - 1);
        assertEq(token.balanceOf(actors[3]), 0);
    }

    function test_maximumApprovalSurvivesFullSupplyAndSelfTransfers() public {
        vm.prank(actors[0]);
        token.approve(actors[2], type(uint256).max);
        vm.startPrank(actors[2]);
        token.transferFrom(actors[0], actors[0], 1e27);
        token.transferFrom(actors[0], actors[1], 1e27);
        vm.stopPrank();
        assertEq(token.allowance(actors[0], actors[2]), type(uint256).max);
        assertEq(token.balanceOf(actors[0]), 0);
        assertEq(token.balanceOf(actors[1]), 1e27);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_invalidRecipientCannotConsumeBalanceOrApproval(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        vm.prank(actors[0]);
        token.approve(actors[2], amount);
        vm.prank(actors[2]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(actors[0], address(0), amount);
        assertEq(token.allowance(actors[0], actors[2]), amount);
        assertEq(token.balanceOf(actors[0]), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}

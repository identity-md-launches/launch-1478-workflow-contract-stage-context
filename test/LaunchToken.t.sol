// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_policySupplyAndMetadata() public view {
        assertEq(token.name(), "RH PEPEFRONT");
        assertEq(token.symbol(), "PEPEFRONT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_exactTransfer(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndTransferFailures() public {
        token.transfer(alice, 100);
        vm.startPrank(alice);
        token.approve(bob, 40);
        vm.stopPrank();
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40));
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 40);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 61);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    function test_noMintOwnerPauseOrUpgradeSelectors() public {
        string[8] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "setMinter(address)",
            "transferOwnership(address)",
            "pause()",
            "initialize(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], alice, 1e30));
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(alice), 0);
        }
    }
}

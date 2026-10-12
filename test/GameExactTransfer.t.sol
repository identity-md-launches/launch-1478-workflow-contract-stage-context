// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GameFixture} from "./helpers/GameFixture.sol";
import {Game} from "src/Game.sol";

/// @dev Offline behavior probe, not a claim about the deployed IMD implementation.
contract TransferBehaviorProbe is ERC20 {
    enum Mode {
        Standard,
        NoMovement,
        SenderSurcharge
    }
    Mode public mode;

    constructor() ERC20("Transfer behavior probe", "PROBE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function configureMode(Mode mode_) external {
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            if (mode == Mode.NoMovement) return;
            if (mode == Mode.SenderSurcharge) super._update(from, address(0), 1);
        }
        super._update(from, to, amount);
    }
}

contract GameExactTransferTest is GameFixture {
    TransferBehaviorProbe private probe;

    function setUp() public override {
        super.setUp();
        TransferBehaviorProbe implementation = new TransferBehaviorProbe();
        vm.etch(address(imd), address(implementation).code);
        probe = TransferBehaviorProbe(address(imd));
    }

    function test_successReturnWithoutMovementCannotCreateUnbackedFunding() public {
        probe.configureMode(TransferBehaviorProbe.Mode.NoMovement);
        uint256 tokensBefore = token.balanceOf(sponsor);
        uint256 tokenApprovalBefore = token.allowance(sponsor, address(game));
        uint256 prizeApprovalBefore = probe.allowance(sponsor, address(game));
        vm.prank(sponsor);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.fund(FIRST_DAY, 100, 200);
        assertEq(token.balanceOf(sponsor), tokensBefore);
        assertEq(token.allowance(sponsor, address(game)), tokenApprovalBefore);
        assertEq(probe.allowance(sponsor, address(game)), prizeApprovalBefore);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(probe.balanceOf(address(game)), 0);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
        (uint256 tokens, uint256 prizes) = game.contributions(FIRST_DAY, sponsor);
        assertEq(tokens + prizes, 0);
        assertEq(_epoch(FIRST_DAY).tokenBudget + _epoch(FIRST_DAY).prizeBudget, 0);
    }

    function test_successReturnWithoutPaymentPreservesClaimUntilAssetRecovers() public {
        _fundAndOpen(0, 100);
        _win(alice, 0, 3);
        _close(FIRST_DAY);
        bytes memory playerBefore = game.state(alice);
        probe.configureMode(TransferBehaviorProbe.Mode.NoMovement);
        vm.prank(alice);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.act(_action(9, 0, 0, 0));
        assertEq(game.state(alice), playerBefore);
        assertEq(_epoch(FIRST_DAY).creditedPower, 0);
        assertEq(probe.balanceOf(alice), 0);
        assertEq(game.totalPrizeLiability(), 100);
        probe.configureMode(TransferBehaviorProbe.Mode.Standard);
        vm.prank(alice);
        game.claimPrize();
        assertEq(probe.balanceOf(alice), 100);
        assertEq(game.totalPrizeLiability(), 0);
    }

    function test_senderSurchargeCannotConsumeAnotherPlayersReserves() public {
        _fundAndOpen(0, 100);
        _win(alice, 0, 3);
        _win(bob, 0, 3);
        _close(FIRST_DAY);
        probe.configureMode(TransferBehaviorProbe.Mode.SenderSurcharge);
        bytes memory beforeState = game.state(alice);
        vm.prank(alice);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.claimPrize(); // Recipient would receive exactly 50; vault would incorrectly lose 51.
        assertEq(game.state(alice), beforeState);
        assertEq(game.prizeClaimable(bob), 50);
        assertEq(probe.balanceOf(alice), 0);
        assertEq(probe.balanceOf(address(game)), 100);
        assertEq(_epoch(FIRST_DAY).prizeAllocated, 0);
        probe.configureMode(TransferBehaviorProbe.Mode.Standard);
        vm.prank(alice);
        game.claimPrize();
        vm.prank(bob);
        game.claimPrize();
        assertEq(probe.balanceOf(alice), 50);
        assertEq(probe.balanceOf(bob), 50);
    }

    function test_senderSurchargeRefundRollsBackBothAssetsAndBothSponsors() public {
        _fund(FIRST_DAY, 100, 200);
        probe.mint(bob, 1);
        vm.startPrank(bob);
        probe.approve(address(game), 1);
        game.fund(FIRST_DAY, 0, 1);
        vm.stopPrank();
        _close(FIRST_DAY);
        uint256 tokenBefore = token.balanceOf(sponsor);
        uint256 prizeBefore = probe.balanceOf(sponsor);
        probe.configureMode(TransferBehaviorProbe.Mode.SenderSurcharge);
        vm.prank(sponsor);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.refund(FIRST_DAY);
        assertEq(token.balanceOf(sponsor), tokenBefore);
        assertEq(probe.balanceOf(sponsor), prizeBefore);
        assertEq(probe.balanceOf(address(game)), 201);
        (uint256 tokens, uint256 prizes) = game.contributions(FIRST_DAY, sponsor);
        assertEq(tokens, 100);
        assertEq(prizes, 200);
        (, uint256 bobContribution) = game.contributions(FIRST_DAY, bob);
        assertEq(bobContribution, 1);
        probe.configureMode(TransferBehaviorProbe.Mode.Standard);
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        vm.prank(bob);
        game.refundPrize(FIRST_DAY);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
        assertEq(probe.balanceOf(bob), 1);
    }

    function test_prizeSettlementUsesRawUnitsWithoutAssumingEighteenDecimals() public {
        assertEq(probe.decimals(), 6);
        _fundAndOpen(0, 1_000_001);
        _win(alice, 0, 3);
        _win(bob, 0, 3);
        _close(FIRST_DAY);
        vm.prank(alice);
        game.claimPrize();
        vm.prank(bob);
        game.claimPrize();
        assertEq(probe.balanceOf(alice), 500_000);
        assertEq(probe.balanceOf(bob), 500_000);
        assertEq(probe.balanceOf(address(game)), 1);
        game.recycle(FIRST_DAY);
        assertEq(_epoch(FIRST_DAY + 2).prizeBudget, 1);
        assertEq(game.totalPrizeLiability(), 1);
    }
}

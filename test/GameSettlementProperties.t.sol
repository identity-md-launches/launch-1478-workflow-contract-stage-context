// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture} from "./helpers/GameFixture.sol";
import {Game} from "src/Game.sol";

contract GameSettlementPropertiesTest is GameFixture {
    event RewardsAccrued(address indexed player, uint64 indexed epoch, uint256 power, uint256 tokens, uint256 prizes);

    /// @dev Equal economic outcomes under different sponsor/refund/recycling orderings.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitRefundsCommuteWithRecycling(uint128 aTokens, uint128 bTokens, uint128 prizes) public {
        aTokens = uint128(bound(aTokens, 1, 1_000 ether));
        bTokens = uint128(bound(bTokens, 1, 1_000 ether));
        prizes = uint128(bound(prizes, 1, 1_000 ether));
        uint256 sponsorTokens = token.balanceOf(sponsor);
        uint256 sponsorPrizes = imd.balanceOf(sponsor);
        uint256 bobTokens = token.balanceOf(bob);
        _fund(FIRST_DAY, aTokens, prizes);
        vm.startPrank(bob);
        token.approve(address(game), bTokens);
        game.fund(FIRST_DAY, bTokens, 0);
        vm.stopPrank();
        vm.startPrank(alice);
        token.approve(address(game), 100 ether);
        game.act(_action(8, 0, 0, 0));
        vm.stopPrank();
        _close(FIRST_DAY);
        uint256 checkpoint = vm.snapshotState();

        vm.prank(sponsor);
        game.refundToken(FIRST_DAY);
        game.recycle(FIRST_DAY);
        vm.prank(bob);
        game.refund(FIRST_DAY);
        vm.prank(sponsor);
        game.refundPrize(FIRST_DAY);
        bytes32 splitResult = _settlementDigest();
        assertEq(token.balanceOf(sponsor), sponsorTokens);
        assertEq(imd.balanceOf(sponsor), sponsorPrizes);
        assertEq(token.balanceOf(bob), bobTokens);
        assertEq(_epoch(FIRST_DAY).tokenBudget, 0);
        assertEq(_epoch(FIRST_DAY + 2).tokenBudget, 25 ether);
        assertEq(token.balanceOf(address(game)), 100 ether);
        assertEq(game.totalTokenLiability(), 25 ether);

        assertTrue(vm.revertToState(checkpoint));
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        vm.prank(bob);
        game.refundToken(FIRST_DAY);
        game.recycle(FIRST_DAY);
        assertEq(_settlementDigest(), splitResult, "settlement must not depend on call order");
        vm.prank(sponsor);
        vm.expectRevert(Game.NoRefund.selector);
        game.refund(FIRST_DAY);
        vm.prank(alice);
        vm.expectRevert(Game.NoRefund.selector);
        game.refund(FIRST_DAY); // Cosmetic spending never becomes a refundable sponsorship.
        _assertSolvent();
    }

    function _settlementDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _epoch(FIRST_DAY),
                _epoch(FIRST_DAY + 2),
                token.balanceOf(sponsor),
                imd.balanceOf(sponsor),
                token.balanceOf(bob),
                token.balanceOf(address(game)),
                imd.balanceOf(address(game)),
                game.totalTokenLiability(),
                game.totalPrizeLiability(),
                game.retiredTokens()
            )
        );
    }

    /// @dev The three legal strategies earn 13, 23 and 33 power. Budgets include zero/dust.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_threePlayerSettlementOrderAndRounding(
        uint128 tokens,
        uint128 prizes,
        uint8 ordering,
        bool implicitAccrual
    ) public {
        tokens = uint128(bound(tokens, 0, 10_000 ether));
        prizes = uint128(bound(prizes, 0, 10_000 ether));
        if (tokens == 0 && prizes == 0) tokens = 1;
        _fundAndOpen(tokens, prizes);
        _win(alice, 0, 3);
        _win(bob, 2, 3);
        _win(outsider, 4, 3);
        assertEq(_epoch(FIRST_DAY).totalPower, 69);
        _close(FIRST_DAY);
        address[3] memory players = [alice, bob, outsider];
        uint256[3] memory powers = [uint256(13), uint256(23), uint256(33)];
        uint256 paidTokens;
        uint256 paidPrizes;
        for (uint256 i; i < 3; ++i) {
            uint256 index = ordering % 2 == 0 ? (uint256(ordering) / 2 + i) % 3 : (uint256(ordering) / 2 + 3 - i) % 3;
            address player = players[index];
            uint256 expectedTokens = uint256(tokens) * powers[index] / 69;
            uint256 expectedPrizes = uint256(prizes) * powers[index] / 69;
            assertEq(game.claimable(player), expectedTokens);
            assertEq(game.prizeClaimable(player), expectedPrizes);
            if (!implicitAccrual) game.accrue(player);
            uint256 beforeTokens = token.balanceOf(player);
            uint256 beforePrizes = imd.balanceOf(player);
            vm.startPrank(player);
            if (expectedTokens == 0) vm.expectRevert(Game.NothingToClaim.selector);
            game.claim();
            if (expectedPrizes == 0) vm.expectRevert(Game.NothingToClaim.selector);
            game.claimPrize();
            vm.stopPrank();
            // Zero-value claims revert their implicit accrual; the permissionless path must still work.
            game.accrue(player);
            assertEq(token.balanceOf(player) - beforeTokens, expectedTokens);
            assertEq(imd.balanceOf(player) - beforePrizes, expectedPrizes);
            assertEq(game.claimable(player), 0);
            assertEq(game.prizeClaimable(player), 0);
            paidTokens += expectedTokens;
            paidPrizes += expectedPrizes;
        }
        uint256 tokenDust = uint256(tokens) - paidTokens;
        uint256 prizeDust = uint256(prizes) - paidPrizes;
        assertLt(tokenDust, 3);
        assertLt(prizeDust, 3);
        if (tokenDust + prizeDust == 0) vm.expectRevert(Game.InvalidAmount.selector);
        game.recycle(FIRST_DAY);
        assertEq(_epoch(FIRST_DAY + 2).tokenBudget, tokenDust);
        assertEq(_epoch(FIRST_DAY + 2).prizeBudget, prizeDust);
        assertEq(token.balanceOf(address(game)), tokenDust);
        assertEq(imd.balanceOf(address(game)), prizeDust);
        _assertSolvent();
    }

    function test_oneWeiBudgetsRemainLiveWhenEveryRewardRoundsToZero() public {
        _fundAndOpen(1, 1);
        _win(alice, 0, 3);
        _win(bob, 0, 3);
        _close(FIRST_DAY);
        vm.prank(alice);
        vm.expectRevert(Game.NothingToClaim.selector);
        game.claim();
        assertEq(game.rewardsOf(alice).power, 13);
        vm.expectRevert(Game.EpochNotClosed.selector);
        game.recycle(FIRST_DAY);
        vm.expectEmit(true, true, false, true, address(game));
        emit RewardsAccrued(alice, FIRST_DAY, 13, 0, 0);
        game.accrue(alice);
        game.accrue(bob);
        game.recycle(FIRST_DAY);
        assertEq(_epoch(FIRST_DAY + 2).tokenBudget, 1);
        assertEq(_epoch(FIRST_DAY + 2).prizeBudget, 1);

        vm.warp(uint256(FIRST_DAY + 2) * 1 days);
        _win(alice, 0, 3);
        _close(FIRST_DAY + 2);
        vm.startPrank(alice);
        game.claim();
        game.claimPrize();
        vm.stopPrank();
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
        assertEq(imd.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(game)), 0);
    }

    function test_crossEpochAutoAccrualPreservesAllOlderCredits() public {
        _fund(FIRST_DAY, 101, 201);
        _fund(FIRST_DAY + 1, 102, 202);
        _fund(FIRST_DAY + 2, 103, 203);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        _win(alice, 0, 3);
        for (uint64 i = 1; i < 3; ++i) {
            vm.warp(uint256(game.commandOf(alice).lastRewardAt) + 1 days);
            _win(alice, 0, 3);
            assertEq(game.rewardsOf(alice).epoch, FIRST_DAY + i);
            assertEq(game.rewardsOf(alice).power, 13);
        }
        assertEq(game.rewardsOf(alice).tokens, 203);
        assertEq(game.rewardsOf(alice).prizes, 403);
        _close(FIRST_DAY + 2);
        assertEq(game.claimable(alice), 306);
        assertEq(game.prizeClaimable(alice), 606);
        game.accrue(alice);
        bytes memory afterAccrual = game.state(alice);
        game.accrue(alice);
        assertEq(game.state(alice), afterAccrual, "accrual is idempotent");
        vm.prank(creator);
        game.renounceOwnership();
        vm.startPrank(alice);
        game.claim();
        game.act(_action(9, 0, 0, 0));
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 606);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
    }

    function test_claimOldCreditPreservesOpenEpochPowerAndNeverPaysItEarly() public {
        _fund(FIRST_DAY, 11, 22);
        _fund(FIRST_DAY + 1, 33, 44);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        _win(alice, 0, 3);
        vm.warp(uint256(game.commandOf(alice).lastRewardAt) + 1 days);
        _win(alice, 0, 3);
        vm.startPrank(alice);
        game.claim();
        game.claimPrize();
        vm.expectRevert(Game.NothingToClaim.selector);
        game.claim();
        vm.stopPrank();
        assertEq(game.rewardsOf(alice).power, 13);
        assertEq(game.rewardsOf(alice).epoch, FIRST_DAY + 1);
        assertEq(_epoch(FIRST_DAY + 1).creditedPower, 0);
        assertEq(game.claimable(alice), 0);
        _close(FIRST_DAY + 1);
        assertEq(game.claimable(alice), 33);
        assertEq(game.prizeClaimable(alice), 44);
    }

    function test_partialAccrualCannotRecycleOrChangeTheLastPlayersShare() public {
        _fundAndOpen(101, 103);
        _win(alice, 0, 3);
        _win(bob, 0, 3);
        _close(FIRST_DAY);
        vm.prank(alice);
        game.claim();
        bytes memory bobsState = game.state(bob);
        bytes32 epochState = keccak256(abi.encode(_epoch(FIRST_DAY)));
        vm.expectRevert(Game.EpochNotClosed.selector);
        game.recycle(FIRST_DAY);
        assertEq(game.state(bob), bobsState);
        assertEq(keccak256(abi.encode(_epoch(FIRST_DAY))), epochState);
        game.accrue(bob);
        game.recycle(FIRST_DAY);
        assertEq(game.claimable(bob), 50);
        assertEq(game.prizeClaimable(alice), 51);
        assertEq(game.prizeClaimable(bob), 51);
        vm.warp(block.timestamp + 365 days);
        vm.prank(bob);
        game.claim();
        vm.prank(bob);
        game.claimPrize();
        vm.prank(alice);
        game.claimPrize();
        assertEq(game.totalTokenLiability(), 1);
        assertEq(game.totalPrizeLiability(), 1);
        _assertSolvent();
    }

    function test_maxUint128PrizeDepositsAccumulateWithoutNarrowingAndRefundExactly() public {
        uint128 maximum = type(uint128).max;
        imd.mint(alice, maximum);
        imd.mint(bob, maximum);
        address[2] memory sponsors = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(sponsors[i]);
            imd.approve(address(game), maximum);
            game.fund(FIRST_DAY, 0, maximum);
            vm.stopPrank();
        }
        assertEq(_epoch(FIRST_DAY).prizeBudget, uint256(maximum) * 2);
        assertEq(game.totalPrizeLiability(), uint256(maximum) * 2);
        _close(FIRST_DAY);
        vm.prank(alice);
        game.refundPrize(FIRST_DAY);
        vm.prank(bob);
        game.refund(FIRST_DAY);
        assertEq(imd.balanceOf(alice), maximum);
        assertEq(imd.balanceOf(bob), maximum);
        assertEq(game.totalPrizeLiability(), 0);
    }

    function test_maxUint128PrizeBudgetPaysFractionalSharesAndOnlyRecyclesDust() public {
        uint128 maximum = type(uint128).max;
        imd.mint(sponsor, maximum);
        vm.prank(sponsor);
        imd.approve(address(game), maximum);
        _fundAndOpen(0, maximum);
        _win(alice, 0, 3);
        _win(bob, 2, 3);
        _close(FIRST_DAY);
        uint256 aliceShare = uint256(maximum) * 13 / 36;
        uint256 bobShare = uint256(maximum) * 23 / 36;
        vm.prank(alice);
        game.claimPrize();
        vm.prank(bob);
        game.claimPrize();
        assertEq(imd.balanceOf(alice), aliceShare);
        assertEq(imd.balanceOf(bob), bobShare);
        uint256 dust = uint256(maximum) - aliceShare - bobShare;
        assertLe(dust, 1);
        if (dust == 0) vm.expectRevert(Game.InvalidAmount.selector);
        game.recycle(FIRST_DAY);
        assertEq(game.totalPrizeLiability(), dust);
        assertEq(_epoch(FIRST_DAY + 2).prizeBudget, dust);
    }

    function test_prizeRefundRemainsIndependentWhenLaunchTokenCodeDisappears() public {
        _fund(FIRST_DAY, 100, 200);
        _close(FIRST_DAY);
        bytes memory runtime = address(token).code;
        vm.etch(address(token), hex"");
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(Game.AssetUnavailable.selector, address(token)));
        game.refund(FIRST_DAY);
        vm.prank(sponsor);
        game.refundPrize(FIRST_DAY);
        assertEq(game.totalPrizeLiability(), 0);
        assertEq(game.totalTokenLiability(), 100);
        vm.etch(address(token), runtime);
        vm.prank(sponsor);
        game.refundToken(FIRST_DAY);
        assertEq(game.totalTokenLiability(), 0);
    }

    function test_dayZeroAndLastFundingHorizonUseTheSameBoundaries() public {
        vm.warp(0);
        vm.startPrank(sponsor);
        game.fund(1, 1, 0);
        game.fund(30, 0, 1);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(0, 1, 0);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(31, 1, 0);
        vm.warp(2 days - 1);
        vm.expectRevert(Game.EpochNotClosed.selector);
        game.refund(1);
        vm.warp(2 days);
        game.refund(1);
        vm.stopPrank();
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 1);
    }
}

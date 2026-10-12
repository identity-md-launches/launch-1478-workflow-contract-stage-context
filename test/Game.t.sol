// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture, MockAsset} from "./helpers/GameFixture.sol";
import {Game} from "../src/Game.sol";
import {Battlefield} from "../src/lib/Battlefield.sol";
import {CommandPower} from "../src/lib/CommandPower.sol";

contract GamePlayTest is GameFixture {
    function test_allFactionsAndDifficultiesWinLegally() public {
        for (uint8 selection; selection < 6; ++selection) {
            _win(alice, selection, 3);
            assertEq(game.battleOf(alice).faction, selection % 2);
            assertEq(game.battleOf(alice).difficulty, selection / 2);
        }
        assertEq(game.claimable(alice), 0);
        assertEq(game.rewardsOf(alice).power, 0);
    }

    function test_attackDestroysEnemyBase() public {
        _start(alice, 0);
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        _step(alice, 1, 0);
        _step(alice, 3, 0);
        _step(alice, 3, 0);
        uint256 started = game.battleOf(alice).startedAt;
        vm.warp(started + 5 minutes);
        for (uint8 i; i < 8; ++i) {
            _step(alice, 4, 0);
        }
        assertEq(game.battleOf(alice).enemyHP, 0);
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Won));
    }

    function test_powerBarracksFactoryTechGateRankedUnits() public {
        _start(alice, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        vm.expectRevert(Battlefield.PrerequisiteMissing.selector);
        game.act(_action(3, 1, 0, 0));
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        for (uint8 i; i < 9; ++i) {
            _step(alice, 1, 0);
        }
        _step(alice, 2, 3);
        _step(alice, 3, 1);
        _step(alice, 2, 4);
        _step(alice, 3, 2);
        Battlefield.Battle memory battle = game.battleOf(alice);
        assertEq(battle.tech, 4);
        assertEq(battle.tanks, 1);
        assertEq(battle.commandos, 1);
        uint16 hp = battle.baseHP;
        _step(alice, 6, 0);
        assertGt(game.battleOf(alice).baseHP, hp);
    }

    function test_invalidArgumentsTechSequenceAndOreRollback() public {
        _start(alice, 1);
        vm.warp(block.timestamp + 10);
        vm.startPrank(alice);
        vm.expectRevert(Battlefield.PrerequisiteMissing.selector);
        game.act(_action(2, 1, 0, 2));
        vm.expectRevert(Battlefield.InvalidMove.selector);
        game.act(_action(1, 1, 0, 1));
        vm.expectRevert(Battlefield.PrerequisiteMissing.selector);
        game.act(_action(4, 1, 0, 0));
        vm.stopPrank();
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        vm.expectRevert(Battlefield.InsufficientOre.selector);
        game.act(_action(2, 1, 2, 3));
        assertEq(game.battleOf(alice).ore, 30);
        assertEq(game.battleOf(alice).turn, 2);
    }

    function test_captureRequiresStrengthAndConsecutiveMoves() public {
        _start(alice, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        vm.expectRevert(Battlefield.PrerequisiteMissing.selector);
        game.act(_action(5, 1, 0, 0));
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        _step(alice, 1, 0);
        _step(alice, 3, 0);
        _step(alice, 3, 0);
        _step(alice, 5, 0);
        assertEq(game.battleOf(alice).points, 1);
        _step(alice, 1, 0);
        assertEq(game.battleOf(alice).points, 0);
    }

    function test_armyCapRejectsThirteenthUnitWithoutSpending() public {
        _start(alice, 0);
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        for (uint8 i; i < 10; ++i) {
            _step(alice, 1, 0);
        }
        for (uint8 i; i < 12; ++i) {
            _step(alice, 3, 0);
        }
        Battlefield.Battle memory battle = game.battleOf(alice);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        vm.expectRevert(Battlefield.ArmyFull.selector);
        game.act(_action(3, battle.id, battle.turn, 0));
        assertEq(game.battleOf(alice).ore, battle.ore);
        assertEq(game.battleOf(alice).recruits, 12);
        assertEq(game.battleOf(alice).turn, battle.turn);
    }

    function test_minimumTurnAndMatchTime() public {
        _start(alice, 0);
        vm.prank(alice);
        vm.expectRevert(Battlefield.TooEarly.selector);
        game.act(_action(1, 1, 0, 0));
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        _step(alice, 1, 0);
        _step(alice, 3, 0);
        _step(alice, 3, 0);
        _step(alice, 5, 0);
        _step(alice, 5, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        vm.expectRevert(Battlefield.TooEarly.selector);
        game.act(_action(5, 1, 7, 0));
        assertEq(game.battleOf(alice).points, 2);
        vm.warp(uint256(game.battleOf(alice).startedAt) + 5 minutes);
        _step(alice, 5, 0);
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Won));
    }

    function test_turnSessionAndCrossWalletReplayCannotChangeOthers() public {
        _start(alice, 0);
        vm.warp(block.timestamp + 10);
        bytes memory move = _action(1, 1, 0, 0);
        vm.prank(bob);
        vm.expectRevert(Battlefield.NotActive.selector);
        game.act(move);
        vm.prank(alice);
        game.act(move);
        vm.prank(alice);
        vm.expectRevert(Battlefield.WrongTurn.selector);
        game.act(move);
        _step(alice, 7, 0);
        _start(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Battlefield.WrongSession.selector);
        game.act(move);
        _start(bob, 0);
        vm.warp(block.timestamp + 10);
        vm.prank(bob);
        game.act(move);
        assertEq(game.battleOf(alice).turn, 0);
        assertEq(game.battleOf(bob).turn, 1);
    }

    function test_startCannotOverwriteActiveAndNonceMustAdvance() public {
        _start(alice, 0);
        vm.prank(alice);
        vm.expectRevert(Battlefield.MatchActive.selector);
        game.act(_action(0, 2, 0, 0));
        _step(alice, 7, 0);
        vm.prank(alice);
        vm.expectRevert(Battlefield.WrongSession.selector);
        game.act(_action(0, 1, 0, 0));
        _start(alice, 0);
        assertEq(game.battleOf(alice).id, 2);
    }

    function test_permissionlessExpiryExactBoundary() public {
        _start(alice, 0);
        uint64 deadline = game.battleOf(alice).deadline;
        vm.warp(deadline - 1);
        vm.expectRevert(Game.NotExpired.selector);
        game.expire(alice, 1);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(Battlefield.DeadlinePassed.selector);
        game.act(_action(1, 1, 0, 0));
        vm.prank(outsider);
        game.expire(alice, 1);
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Expired));
        vm.expectRevert(Battlefield.NotActive.selector);
        game.expire(alice, 1);
        _start(alice, 0);
    }

    function test_defeatByEnemyAndTurnLimit() public {
        _start(alice, 5);
        for (uint8 i; i < 48; ++i) {
            if (game.battleOf(alice).status != Battlefield.Status.Active) break;
            _step(alice, 1, 0);
        }
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Lost));
        assertEq(game.battleOf(alice).baseHP, 0);
        _start(alice, 0);
        for (uint8 i; i < 48; ++i) {
            Battlefield.Battle memory battle = game.battleOf(alice);
            if (battle.baseHP < 150 && battle.ore >= 25) _step(alice, 6, 0);
            else _step(alice, 1, 0);
        }
        assertEq(game.battleOf(alice).turn, 48);
        assertGt(game.battleOf(alice).baseHP, 0);
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Lost));
    }

    function test_malformedUnknownAndNoncanonicalActionsRejected() public {
        vm.expectRevert(Game.InvalidAction.selector);
        game.act("");
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(bytes.concat(_action(0, 1, 0, 0), hex"00"));
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(_action(10, 0, 0, 0));
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(_action(0, 1, 1, 0));
        vm.expectRevert(Battlefield.InvalidMove.selector);
        game.act(_action(0, 1, 0, 6));
        vm.expectRevert();
        game.act(abi.encode(uint256(256), uint64(1), uint8(0), uint8(0)));
    }

    function test_stateRoundTrip() public {
        _fundAndOpen(100 ether, 50 ether);
        _win(alice, 0, 2);
        _close(FIRST_DAY);
        (
            uint8 version,
            Battlefield.Battle memory battle,
            CommandPower.Account memory command,
            Game.RewardAccount memory rewards,
            uint256 skins,
            uint256 tokens,
            uint256 prizes
        ) = abi.decode(
            game.state(alice),
            (uint8, Battlefield.Battle, CommandPower.Account, Game.RewardAccount, uint256, uint256, uint256)
        );
        assertEq(version, 1);
        assertEq(battle.id, 1);
        assertEq(command.wins, 1);
        assertEq(rewards.power, 12);
        assertEq(skins, 0);
        assertEq(tokens, 100 ether);
        assertEq(prizes, 50 ether);
    }

    function test_nativeValueRejectedAndDirectSendRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Game.NativeValueNotAccepted.selector);
        game.act{value: 1}(_action(0, 1, 0, 0));
        vm.prank(alice);
        (bool ok,) = address(game).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(game).balance, 0);
    }
}

contract GameRewardsTest is GameFixture {
    function test_fundedWinPullClaimsOnlyAfterEpochClose() public {
        _fundAndOpen(1_000 ether, 200 ether);
        _win(alice, 0, 2);
        assertEq(game.claimable(alice), 0);
        vm.prank(alice);
        vm.expectRevert(Game.NothingToClaim.selector);
        game.claim();
        _close(FIRST_DAY);
        assertEq(game.claimable(alice), 1_000 ether);
        assertEq(game.prizeClaimable(alice), 200 ether);
        uint256 beforeTokens = token.balanceOf(alice);
        vm.startPrank(alice);
        game.claim();
        game.claimPrize();
        vm.expectRevert(Game.NothingToClaim.selector);
        game.claim();
        vm.expectRevert(Game.NothingToClaim.selector);
        game.claimPrize();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), beforeTokens + 1_000 ether);
        assertEq(imd.balanceOf(alice), 200 ether);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
        _assertSolvent();
    }

    function test_budgetSharedProRataAndMoreWalletsCannotExpandIt() public {
        _fundAndOpen(999, 777);
        _win(alice, 0, 1);
        _win(bob, 2, 2);
        uint256 ap = game.rewardsOf(alice).power;
        uint256 bp = game.rewardsOf(bob).power;
        _close(FIRST_DAY);
        uint256 at = game.claimable(alice);
        uint256 bt = game.claimable(bob);
        assertEq(at, 999 * ap / (ap + bp));
        assertEq(bt, 999 * bp / (ap + bp));
        assertLe(at + bt, 999);
        assertLe(game.prizeClaimable(alice) + game.prizeClaimable(bob), 777);
        vm.prank(outsider);
        vm.expectRevert(Game.NothingToClaim.selector);
        game.claim();
        vm.prank(outsider);
        game.accrue(alice);
        assertEq(game.claimable(alice), at);
        assertEq(game.claimable(outsider), 0);
        _assertSolvent();
    }

    function test_cooldown24HoursFreeReplayAndHarvestCap() public {
        _fund(FIRST_DAY, 1_000 ether, 0);
        _fund(FIRST_DAY + 1, 1_000 ether, 0);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        _win(alice, 0, 8);
        assertEq(game.rewardsOf(alice).power, 15);
        CommandPower.Account memory command = game.commandOf(alice);
        assertEq(command.harvests, 5);
        assertFalse(game.rewardAvailable(alice));
        _win(alice, 0, 0);
        assertFalse(game.battleOf(alice).rewarded);
        assertEq(game.rewardsOf(alice).power, 15);
        assertEq(game.commandOf(alice).lastRewardAt, command.lastRewardAt);
        vm.warp(uint256(command.lastRewardAt) + 1 days - 1);
        assertFalse(game.rewardAvailable(alice));
        vm.warp(uint256(command.lastRewardAt) + 1 days);
        assertTrue(game.rewardAvailable(alice));
        _win(alice, 0, 1);
        assertEq(game.claimable(alice), 1_000 ether);
        assertEq(game.commandOf(alice).wins, 1);
        assertEq(game.commandOf(alice).harvests, 1);
    }

    function test_emptyFundingFreePlayAndLossNeverPays() public {
        _win(alice, 0, 2);
        assertEq(game.rewardsOf(alice).power, 0);
        assertFalse(game.commandOf(alice).rewardedBefore);
        _fund(FIRST_DAY, 1_000 ether, 0);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        _start(alice, 0);
        _step(alice, 1, 0);
        _step(alice, 7, 0);
        assertEq(game.rewardsOf(alice).power, 0);
        assertTrue(game.rewardAvailable(alice));
        _start(alice, 0);
        vm.warp(game.battleOf(alice).deadline);
        game.expire(alice, 2 + 1);
        _close(FIRST_DAY);
        assertEq(game.claimable(alice), 0);
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        _assertSolvent();
    }

    function test_lateStartsFreeAndRewardedDeadlineCannotCrossEpoch() public {
        _fundAndOpen(1_000 ether, 0);
        vm.warp((uint256(FIRST_DAY) + 1) * 1 days - 20 minutes);
        assertTrue(game.rewardAvailable(alice));
        _start(alice, 0);
        assertTrue(game.battleOf(alice).rewarded);
        assertEq(game.battleOf(alice).deadline, (uint256(FIRST_DAY) + 1) * 1 days);
        vm.warp(block.timestamp + 1);
        assertFalse(game.rewardAvailable(bob));
        _win(bob, 0, 1);
        assertFalse(game.battleOf(bob).rewarded);
        assertEq(game.rewardsOf(bob).power, 0);
        vm.warp(game.battleOf(alice).deadline);
        vm.prank(alice);
        vm.expectRevert(Battlefield.DeadlinePassed.selector);
        game.act(_action(1, 1, 0, 0));
        game.expire(alice, 1);
        assertEq(game.claimable(alice), 0);
    }

    function test_fundingAndRefundBoundaries() public {
        vm.startPrank(sponsor);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(100, 1, 0);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(131, 1, 0);
        vm.expectRevert(Game.InvalidAmount.selector);
        game.fund(FIRST_DAY, 0, 0);
        game.fund(FIRST_DAY, 100, 200);
        vm.expectRevert(Game.EpochNotClosed.selector);
        game.refund(FIRST_DAY);
        vm.stopPrank();
        vm.warp(uint256(FIRST_DAY) * 1 days);
        vm.prank(sponsor);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(FIRST_DAY, 1, 0);
        _close(FIRST_DAY);
        vm.prank(outsider);
        vm.expectRevert(Game.NoRefund.selector);
        game.refund(FIRST_DAY);
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        vm.prank(sponsor);
        vm.expectRevert(Game.NoRefund.selector);
        game.refund(FIRST_DAY);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
    }

    function test_fundedEpochWithWinnersCannotRefundOrBeAltered() public {
        _fundAndOpen(100, 100);
        _win(alice, 0, 1);
        _close(FIRST_DAY);
        vm.prank(sponsor);
        vm.expectRevert(Game.NoRefund.selector);
        game.refund(FIRST_DAY);
        vm.prank(creator);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(FIRST_DAY, 10, 10);
        assertEq(game.claimable(alice), 100);
    }

    function test_IMDOnlyRewardsViaActBridge() public {
        _fundAndOpen(0, 50 ether);
        _win(alice, 0, 1);
        _close(FIRST_DAY);
        assertEq(game.claimable(alice), 0);
        vm.prank(alice);
        game.act(_action(9, 0, 0, 0));
        assertEq(imd.balanceOf(alice), 50 ether);
        vm.prank(alice);
        vm.expectRevert(Game.NothingToClaim.selector);
        game.act(_action(9, 0, 0, 0));
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(_action(9, 1, 0, 0));
    }

    function test_epochRoundingDustRecyclePreservesUnclaimedCredits() public {
        _fundAndOpen(101, 51);
        _win(alice, 0, 1);
        _win(bob, 0, 1);
        _close(FIRST_DAY);
        vm.expectRevert(Game.EpochNotClosed.selector);
        game.recycle(FIRST_DAY);
        game.accrue(alice);
        game.accrue(bob);
        assertEq(game.claimable(alice), 50);
        assertEq(game.prizeClaimable(alice), 25);
        game.recycle(FIRST_DAY);
        Game.Epoch memory next = _epoch(FIRST_DAY + 2);
        assertEq(next.tokenBudget, 1);
        assertEq(next.prizeBudget, 1);
        assertEq(next.prizeRevenue, 1);
        assertEq(game.claimable(bob), 50);
        assertEq(game.totalTokenLiability(), 101);
        vm.prank(alice);
        game.claim();
        vm.prank(bob);
        game.claim();
        assertEq(game.totalTokenLiability(), 1);
        _close(FIRST_DAY + 2);
        game.recycle(FIRST_DAY + 2);
        assertEq(_epoch(FIRST_DAY + 4).tokenBudget, 1);
        assertEq(_epoch(FIRST_DAY + 4).prizeBudget, 1);
        vm.expectRevert(Game.InvalidAmount.selector);
        game.recycle(FIRST_DAY + 2);
        _assertSolvent();
    }

    function testFuzz_payoutConservation(uint128 tokenBudget, uint128 prizeBudget) public {
        tokenBudget = uint128(bound(tokenBudget, 2, 10_000 ether));
        prizeBudget = uint128(bound(prizeBudget, 2, 10_000 ether));
        _fundAndOpen(tokenBudget, prizeBudget);
        _win(alice, 0, 1);
        _win(bob, 2, 2);
        _close(FIRST_DAY);
        uint256 paidTokens = game.claimable(alice) + game.claimable(bob);
        uint256 paidPrizes = game.prizeClaimable(alice) + game.prizeClaimable(bob);
        if (game.claimable(alice) != 0) {
            vm.prank(alice);
            game.claim();
        }
        if (game.prizeClaimable(alice) != 0) {
            vm.prank(alice);
            game.claimPrize();
        }
        if (game.claimable(bob) != 0) {
            vm.prank(bob);
            game.claim();
        }
        if (game.prizeClaimable(bob) != 0) {
            vm.prank(bob);
            game.claimPrize();
        }
        assertEq(game.totalTokenLiability(), uint256(tokenBudget) - paidTokens);
        assertEq(game.totalPrizeLiability(), uint256(prizeBudget) - paidPrizes);
        assertLt(game.totalTokenLiability(), 2);
        assertLt(game.totalPrizeLiability(), 2);
        _assertSolvent();
    }
}

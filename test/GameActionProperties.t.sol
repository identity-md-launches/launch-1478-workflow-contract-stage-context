// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture} from "./helpers/GameFixture.sol";
import {Game} from "src/Game.sol";
import {Battlefield} from "src/lib/Battlefield.sol";

contract GameActionPropertiesTest is GameFixture {
    event BattleStarted(
        address indexed player, uint64 indexed id, uint64 indexed epoch, uint8 selection, bool rewarded
    );
    event Move(address indexed player, uint64 indexed id, uint8 turn, uint8 command, uint8 argument);
    event BattleFinished(address indexed player, uint64 indexed id, Battlefield.Status result, uint256 power);

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_wrongActionLengthCannotMutatePlayer(uint16 lengthSeed) public {
        _start(alice, 0);
        uint256 length = bound(lengthSeed, 0, 512);
        if (length == 128) length++;
        bytes memory beforeState = game.state(alice);
        vm.prank(alice);
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(new bytes(length));
        assertEq(game.state(alice), beforeState);
    }

    /// @dev Exercise dirty high bits in every ABI word, not just the opcode word.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_noncanonicalActionWordsCannotTruncateIntoValidActions(uint8 slotSeed, uint8 bitSeed) public {
        uint256 slot = slotSeed % 4;
        uint256 bits = slot == 1 ? 64 : 8;
        uint256[4] memory words = [uint256(0), uint256(1), uint256(0), uint256(0)];
        words[slot] |= uint256(1) << bound(bitSeed, bits, 255);
        bytes memory beforeState = game.state(alice);
        vm.prank(alice);
        vm.expectRevert(); // Solidity's ABI decoder rejects noncanonical integer words without a custom error.
        game.act(abi.encode(words[0], words[1], words[2], words[3]));
        assertEq(game.state(alice), beforeState);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nativeValueRollbackPreservesBalanceAndSession(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        _start(alice, 0);
        bytes memory beforeState = game.state(alice);
        vm.deal(alice, amount);
        vm.prank(alice);
        vm.expectRevert(Game.NativeValueNotAccepted.selector);
        game.act{value: amount}(_action(7, 1, 0, 0));
        assertEq(alice.balance, amount);
        assertEq(address(game).balance, 0);
        assertEq(game.state(alice), beforeState);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everyOrderRejectsAtDeadlineWithoutConsumingSession(uint8 command, uint8 argument) public {
        command = uint8(bound(command, 1, 7));
        _start(alice, 0);
        vm.warp(game.battleOf(alice).deadline);
        bytes memory beforeState = game.state(alice);
        vm.prank(alice);
        vm.expectRevert(Battlefield.DeadlinePassed.selector);
        game.act(_action(command, 1, 0, argument));
        assertEq(game.state(alice), beforeState);
        vm.prank(outsider);
        game.expire(alice, 1);
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Expired));
        assertEq(game.rewardsOf(alice).power, 0);
    }

    function test_prematureLethalAttackRollsBackDamageOreTurnAndRewards() public {
        _fundAndOpen(100, 200);
        _start(alice, 0);
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        _step(alice, 1, 0);
        _step(alice, 3, 0);
        _step(alice, 3, 0);
        for (uint256 i; i < 7; ++i) {
            _step(alice, 4, 0);
        }
        Battlefield.Battle memory beforeBattle = game.battleOf(alice);
        assertEq(beforeBattle.enemyHP, 8);
        vm.warp(uint256(beforeBattle.startedAt) + 5 minutes - 1);
        bytes memory beforeState = game.state(alice);
        vm.prank(alice);
        vm.expectRevert(Battlefield.TooEarly.selector);
        game.act(_action(4, beforeBattle.id, beforeBattle.turn, 0));
        assertEq(game.state(alice), beforeState);
        assertEq(_epoch(FIRST_DAY).totalPower, 0);
        vm.warp(uint256(beforeBattle.startedAt) + 5 minutes);
        _step(alice, 4, 0);
        assertEq(uint8(game.battleOf(alice).status), uint8(Battlefield.Status.Won));
        assertEq(game.battleOf(alice).enemyHP, 0);
        assertEq(_epoch(FIRST_DAY).totalPower, 11);
    }

    function test_eventStreamBindsPlayerSessionTurnAndAwardedPower() public {
        _fundAndOpen(100, 200);
        vm.expectEmit(true, true, true, true, address(game));
        emit BattleStarted(alice, 1, FIRST_DAY, 0, true);
        _start(alice, 0);
        vm.expectEmit(true, true, false, true, address(game));
        emit Move(alice, 1, 0, 2, 1);
        _step(alice, 2, 1);
        _step(alice, 2, 2);
        _step(alice, 1, 0);
        _step(alice, 3, 0);
        _step(alice, 3, 0);
        _step(alice, 5, 0);
        _step(alice, 5, 0);
        vm.warp(uint256(game.battleOf(alice).startedAt) + 5 minutes);
        vm.expectEmit(true, true, false, true, address(game));
        emit Move(alice, 1, 7, 5, 0);
        vm.expectEmit(true, true, false, true, address(game));
        emit BattleFinished(alice, 1, Battlefield.Status.Won, 11);
        _step(alice, 5, 0);
        assertEq(game.rewardsOf(alice).power, 11);
        bytes memory terminal = game.state(alice);
        vm.prank(alice);
        vm.expectRevert(Battlefield.NotActive.selector);
        game.act(_action(5, 1, 8, 0));
        assertEq(game.state(alice), terminal);
    }

    function test_practiceEligibilityRemainsFixedWhenCooldownEndsMidMatch() public {
        _fund(FIRST_DAY, 100, 200);
        _fund(FIRST_DAY + 1, 100, 200);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        _win(alice, 0, 3);
        uint256 lastReward = game.commandOf(alice).lastRewardAt;
        vm.warp(lastReward + 1 days - 1);
        _win(alice, 0, 3); // Ends after cooldown, but began before it.
        assertFalse(game.battleOf(alice).rewarded);
        assertEq(game.commandOf(alice).lastRewardAt, lastReward);
        assertEq(_epoch(FIRST_DAY + 1).totalPower, 0);
        assertEq(game.claimable(alice), 100);
        assertTrue(game.rewardAvailable(alice));
        _win(alice, 0, 3);
        assertEq(_epoch(FIRST_DAY + 1).totalPower, 13);
    }
}

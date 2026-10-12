// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Bounded deterministic strategy rules; no client score, seed or privileged settlement.
library Battlefield {
    uint256 internal constant MIN_MATCH_TIME = 5 minutes;
    uint256 internal constant MAX_MATCH_TIME = 20 minutes;
    uint256 internal constant TURN_TIME = 10 seconds;
    uint8 internal constant MAX_TURNS = 48;

    enum Status {
        None,
        Active,
        Won,
        Lost,
        Expired,
        Surrendered
    }

    struct Battle {
        uint64 id;
        uint64 startedAt;
        uint64 deadline;
        uint64 epoch;
        Status status;
        uint8 faction;
        uint8 difficulty;
        uint8 turn;
        uint8 tech;
        uint8 recruits;
        uint8 tanks;
        uint8 commandos;
        uint8 harvests;
        uint8 points;
        uint16 ore;
        uint16 baseHP;
        uint16 enemyHP;
        bool rewarded;
    }

    error InvalidMove();
    error MatchActive();
    error NotActive();
    error WrongSession();
    error WrongTurn();
    error TooEarly();
    error DeadlinePassed();
    error InsufficientOre();
    error PrerequisiteMissing();
    error ArmyFull();

    function start(Battle storage battle, uint64 id, uint8 selection, bool rewarded) internal {
        if (battle.status == Status.Active) revert MatchActive();
        if (id != battle.id + 1) revert WrongSession();
        if (selection > 5) revert InvalidMove();
        uint8 faction = selection % 2;
        uint8 difficulty = selection / 2;
        battle.id = id;
        battle.startedAt = uint64(block.timestamp);
        battle.deadline = uint64(block.timestamp + MAX_MATCH_TIME);
        battle.epoch = uint64(block.timestamp / 1 days);
        battle.status = Status.Active;
        battle.faction = faction;
        battle.difficulty = difficulty;
        battle.turn = 0;
        battle.tech = 0;
        battle.recruits = 0;
        battle.tanks = 0;
        battle.commandos = 0;
        battle.harvests = 0;
        battle.points = 0;
        battle.ore = 100;
        battle.baseHP = faction == 0 ? 200 : 160;
        battle.enemyHP = uint16(120 + uint256(difficulty) * 60);
        battle.rewarded = rewarded;
    }

    function step(Battle storage battle, uint64 id, uint8 turn, uint8 command, uint8 argument) internal {
        if (battle.status != Status.Active) revert NotActive();
        if (id != battle.id) revert WrongSession();
        if (turn != battle.turn) revert WrongTurn();
        if (block.timestamp >= battle.deadline) revert DeadlinePassed();
        if (command == 7) {
            if (argument != 0) revert InvalidMove();
            battle.status = Status.Surrendered;
            return;
        }
        if (block.timestamp < uint256(battle.startedAt) + (uint256(turn) + 1) * TURN_TIME) revert TooEarly();
        if (command != 5) battle.points = 0;
        if (command == 1) {
            if (argument != 0) revert InvalidMove();
            battle.ore += battle.faction == 0 ? 30 : 35;
            battle.harvests += 1;
        } else if (command == 2) {
            if (argument == 0 || argument > 4 || argument != battle.tech + 1) revert PrerequisiteMissing();
            uint16 cost = argument == 1 ? 30 : argument == 2 ? 40 : argument == 3 ? 60 : 80;
            _spend(battle, cost);
            battle.tech = argument;
        } else if (command == 3) {
            if (argument > 2) revert InvalidMove();
            if (battle.tech < argument + 2) revert PrerequisiteMissing();
            if (uint256(battle.recruits) + battle.tanks + battle.commandos >= 12) revert ArmyFull();
            uint16 cost = argument == 0 ? 20 : argument == 1 ? 45 : 60;
            if (battle.faction == 0) cost += 5;
            _spend(battle, cost);
            if (argument == 0) battle.recruits += 1;
            else if (argument == 1) battle.tanks += 1;
            else battle.commandos += 1;
        } else if (command == 4) {
            if (argument != 0) revert InvalidMove();
            uint256 damage = strength(battle);
            uint256 armor = uint256(battle.difficulty) * 3;
            if (damage <= armor) revert PrerequisiteMissing();
            damage -= armor;
            battle.enemyHP = damage >= battle.enemyHP ? 0 : uint16(battle.enemyHP - damage);
        } else if (command == 5) {
            if (argument != 0) revert InvalidMove();
            if (strength(battle) < 12 + uint256(battle.difficulty) * 8) revert PrerequisiteMissing();
            battle.points += 1;
        } else if (command == 6) {
            if (argument != 0) revert InvalidMove();
            uint16 cap = battle.faction == 0 ? 200 : 160;
            if (battle.baseHP == cap) revert InvalidMove();
            _spend(battle, 25);
            uint16 healed = battle.baseHP + 30;
            battle.baseHP = healed < cap ? healed : cap;
        } else {
            revert InvalidMove();
        }
        battle.turn += 1;
        if (battle.enemyHP == 0 || battle.points == 3) {
            if (block.timestamp < uint256(battle.startedAt) + MIN_MATCH_TIME) revert TooEarly();
            battle.status = Status.Won;
            return;
        }
        uint256 defense = battle.faction == 0 ? 3 : 1;
        defense += uint256(battle.recruits) + uint256(battle.tanks) * 2 + battle.commandos;
        uint256 incoming = 5 + uint256(battle.difficulty) * 2 + uint256(battle.turn) / 6;
        if (incoming > defense) {
            uint256 damage = incoming - defense;
            battle.baseHP = damage >= battle.baseHP ? 0 : uint16(battle.baseHP - damage);
        }
        if (battle.baseHP == 0 || battle.turn == MAX_TURNS) battle.status = Status.Lost;
    }

    function strength(Battle storage battle) internal view returns (uint256) {
        return uint256(battle.recruits) * 8 + uint256(battle.tanks) * 20 + uint256(battle.commandos) * 32;
    }

    function _spend(Battle storage battle, uint16 amount) private {
        if (battle.ore < amount) revert InsufficientOre();
        battle.ore -= amount;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameFixture, MockAsset} from "./helpers/GameFixture.sol";
import {Game} from "../src/Game.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Battlefield} from "../src/lib/Battlefield.sol";

contract AccountingHandler is Test {
    Game public game;
    LaunchToken public token;
    MockAsset public imd;
    address public sponsor;
    address[3] public players;
    uint64 public firstEpoch;
    uint256 public depositedTokens;
    uint256 public depositedPrizes;
    uint256 public spentTokens;
    uint256 public withdrawnTokens;
    uint256 public withdrawnPrizes;
    uint256 public victories;

    constructor(Game game_, LaunchToken token_, MockAsset imd_, address sponsor_, address[3] memory players_) {
        game = game_;
        token = token_;
        imd = imd_;
        sponsor = sponsor_;
        players = players_;
        firstEpoch = uint64(block.timestamp / 1 days + 1);
        vm.startPrank(sponsor);
        game.fund(firstEpoch, 100 ether, 100 ether);
        vm.stopPrank();
        depositedTokens = 100 ether;
        depositedPrizes = 100 ether;
    }

    function fund(uint96 tokens, uint96 prizes, uint8 offset) external {
        tokens = uint96(bound(tokens, 1, 100 ether));
        prizes = uint96(bound(prizes, 1, 100 ether));
        uint64 epoch = uint64(block.timestamp / 1 days + 1 + offset % 3);
        vm.prank(sponsor);
        game.fund(epoch, tokens, prizes);
        depositedTokens += tokens;
        depositedPrizes += prizes;
    }

    function passTime(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    function win(uint8 actor, uint8 selection) external {
        address player = players[actor % 3];
        selection %= 6;
        Battlefield.Battle memory battle = game.battleOf(player);
        if (battle.status == Battlefield.Status.Active) {
            if (block.timestamp >= battle.deadline) {
                game.expire(player, battle.id);
            } else {
                vm.prank(player);
                game.act(abi.encode(uint8(7), battle.id, battle.turn, uint8(0)));
            }
        }
        battle = game.battleOf(player);
        vm.prank(player);
        game.act(abi.encode(uint8(0), battle.id + 1, uint8(0), selection));
        _move(player, 2, 1);
        _move(player, 2, 2);
        uint8 recruits = selection / 2 == 0 ? 2 : selection / 2 == 1 ? 3 : 4;
        for (uint8 i; i < 3; ++i) {
            _move(player, 1, 0);
        }
        for (uint8 i; i < recruits; ++i) {
            _move(player, 3, 0);
        }
        _move(player, 5, 0);
        _move(player, 5, 0);
        battle = game.battleOf(player);
        vm.warp(uint256(battle.startedAt) + 5 minutes);
        _move(player, 5, 0);
        assertEq(uint8(game.battleOf(player).status), uint8(Battlefield.Status.Won));
        victories += 1;
    }

    function _move(address player, uint8 command, uint8 argument) private {
        Battlefield.Battle memory battle = game.battleOf(player);
        uint256 earliest = uint256(battle.startedAt) + (uint256(battle.turn) + 1) * 10;
        if (block.timestamp < earliest) vm.warp(earliest);
        vm.prank(player);
        game.act(abi.encode(command, battle.id, battle.turn, argument));
    }

    function buy(uint8 actor, uint8 cosmetic) external {
        address player = players[actor % 3];
        cosmetic %= 8;
        if ((game.cosmetics(player) & (uint256(1) << cosmetic)) != 0) return;
        vm.startPrank(player);
        token.approve(address(game), 100 ether);
        game.act(abi.encode(uint8(8), uint64(0), uint8(0), cosmetic));
        vm.stopPrank();
        spentTokens += 100 ether;
    }

    function claim(uint8 actor) external {
        address player = players[actor % 3];
        uint256 tokens = game.claimable(player);
        uint256 prizes = game.prizeClaimable(player);
        vm.startPrank(player);
        if (tokens != 0) {
            game.claim();
            withdrawnTokens += tokens;
        }
        if (prizes != 0) {
            game.claimPrize();
            withdrawnPrizes += prizes;
        }
        vm.stopPrank();
        assertEq(game.claimable(player), 0);
        assertEq(game.prizeClaimable(player), 0);
    }

    function accrue(uint8 actor) external {
        address player = players[actor % 3];
        uint256 tokens = game.claimable(player);
        uint256 prizes = game.prizeClaimable(player);
        game.accrue(player);
        assertEq(game.claimable(player), tokens);
        assertEq(game.prizeClaimable(player), prizes);
    }

    function refund(uint8 seed) external {
        uint64 today = uint64(block.timestamp / 1 days);
        if (today <= firstEpoch) return;
        uint64 epoch = firstEpoch + seed % (today - firstEpoch);
        (uint256 tokens, uint256 prizes) = game.contributions(epoch, sponsor);
        (,,,, uint256 power,,,) = game.epochs(epoch);
        if (power != 0 || (tokens == 0 && prizes == 0)) return;
        vm.prank(sponsor);
        game.refund(epoch);
        withdrawnTokens += tokens;
        withdrawnPrizes += prizes;
    }

    function recycle(uint8 seed) external {
        uint64 today = uint64(block.timestamp / 1 days);
        if (today <= firstEpoch) return;
        uint64 epoch = firstEpoch + seed % (today - firstEpoch);
        (
            uint256 tokens,
            uint256 prizes,
            uint256 tr,
            uint256 pr,
            uint256 power,
            uint256 credited,
            uint256 ta,
            uint256 pa
        ) = game.epochs(epoch);
        if (power == 0) {
            if (tr == 0 && pr == 0) return;
        } else {
            if (credited != power || (tokens == ta && prizes == pa)) return;
        }
        uint256 tokenLiability = game.totalTokenLiability();
        uint256 prizeLiability = game.totalPrizeLiability();
        game.recycle(epoch);
        assertEq(game.totalTokenLiability(), tokenLiability);
        assertEq(game.totalPrizeLiability(), prizeLiability);
    }
}

contract GameInvariantTest is GameFixture {
    AccountingHandler private handler;

    function setUp() public override {
        super.setUp();
        token.transfer(outsider, 10_000 ether);
        handler = new AccountingHandler(game, token, imd, sponsor, [alice, bob, outsider]);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.passTime.selector;
        selectors[2] = handler.win.selector;
        selectors[3] = handler.buy.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.accrue.selector;
        selectors[6] = handler.refund.selector;
        selectors[7] = handler.recycle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allFundsConservedAndEveryLiabilityBacked() public view {
        assertEq(
            token.balanceOf(address(game)),
            handler.depositedTokens() + handler.spentTokens() - handler.withdrawnTokens()
        );
        assertEq(imd.balanceOf(address(game)), handler.depositedPrizes() - handler.withdrawnPrizes());
        assertEq(token.balanceOf(address(game)), game.totalTokenLiability() + game.retiredTokens());
        assertEq(imd.balanceOf(address(game)), game.totalPrizeLiability());
        assertEq(game.retiredTokens(), handler.spentTokens() * 3 / 4);
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_totalClaimableDoesNotExceedReserves() public view {
        uint256 tokens;
        uint256 prizes;
        for (uint256 i; i < 3; ++i) {
            address player = handler.players(i);
            tokens += game.claimable(player);
            prizes += game.prizeClaimable(player);
            assertLe(game.commandOf(player).wins, 3);
            assertLe(game.commandOf(player).harvests, 5);
            assertLe(game.battleOf(player).turn, 48);
        }
        assertLe(tokens, game.totalTokenLiability());
        assertLe(prizes, game.totalPrizeLiability());
    }
}

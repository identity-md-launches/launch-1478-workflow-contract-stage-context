// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Game} from "../../src/Game.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Battlefield} from "../../src/lib/Battlefield.sol";

contract MockAsset is ERC20 {
    bool public failTransfers;
    bool public takeFee;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bool private _calling;

    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(bool fail, bool fee) external {
        failTransfers = fail;
        takeFee = fee;
    }

    function setCallback(address target, bytes memory data) external {
        callbackTarget = target;
        callbackData = data;
        callbackAttempted = false;
        callbackSucceeded = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!failTransfers, "asset unavailable");
            if (callbackTarget != address(0) && !_calling) {
                _calling = true;
                callbackAttempted = true;
                (callbackSucceeded,) = callbackTarget.call(callbackData);
                _calling = false;
            }
            if (takeFee && amount != 0) {
                super._update(from, address(0), 1);
                amount -= 1;
            }
        }
        super._update(from, to, amount);
    }
}

abstract contract GameFixture is Test {
    LaunchToken internal token;
    MockAsset internal imd;
    Game internal game;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal sponsor = makeAddr("sponsor");
    address internal outsider = makeAddr("outsider");
    uint64 internal constant FIRST_DAY = 101;

    function setUp() public virtual {
        vm.warp(100 days);
        token = new LaunchToken();
        game = new Game(creator, address(token));
        MockAsset implementation = new MockAsset();
        vm.etch(address(game.prizeToken()), address(implementation).code);
        imd = MockAsset(address(game.prizeToken()));
        token.transfer(sponsor, 1_000_000 ether);
        token.transfer(alice, 10_000 ether);
        token.transfer(bob, 10_000 ether);
        imd.mint(sponsor, 1_000_000 ether);
        vm.startPrank(sponsor);
        token.approve(address(game), 1_000_000 ether);
        imd.approve(address(game), 1_000_000 ether);
        vm.stopPrank();
    }

    function _fund(uint64 day, uint128 tokens, uint128 prizes) internal {
        vm.prank(sponsor);
        game.fund(day, tokens, prizes);
    }

    function _fundAndOpen(uint128 tokens, uint128 prizes) internal {
        _fund(FIRST_DAY, tokens, prizes);
        vm.warp(uint256(FIRST_DAY) * 1 days);
    }

    function _action(uint8 command, uint64 id, uint8 turn, uint8 argument) internal pure returns (bytes memory) {
        return abi.encode(command, id, turn, argument);
    }

    function _start(address player, uint8 selection) internal {
        uint64 id = game.battleOf(player).id + 1;
        vm.prank(player);
        game.act(_action(0, id, 0, selection));
    }

    function _step(address player, uint8 command, uint8 argument) internal {
        Battlefield.Battle memory battle = game.battleOf(player);
        uint256 earliest = uint256(battle.startedAt) + (uint256(battle.turn) + 1) * 10;
        if (block.timestamp < earliest) vm.warp(earliest);
        vm.prank(player);
        game.act(_action(command, battle.id, battle.turn, argument));
    }

    /// @dev Legal economy and point-control strategy, usable with all factions/difficulties.
    function _win(address player, uint8 selection, uint8 harvests) internal {
        _start(player, selection);
        _step(player, 2, 1);
        _step(player, 2, 2);
        uint8 count = selection / 2 == 0 ? 2 : selection / 2 == 1 ? 3 : 4;
        for (uint8 i; i < harvests; ++i) {
            _step(player, 1, 0);
        }
        for (uint8 i; i < count; ++i) {
            uint16 cost = selection % 2 == 0 ? 25 : 20;
            if (game.battleOf(player).ore < cost) _step(player, 1, 0);
            _step(player, 3, 0);
        }
        _step(player, 5, 0);
        _step(player, 5, 0);
        Battlefield.Battle memory battle = game.battleOf(player);
        uint256 minFinish = uint256(battle.startedAt) + 5 minutes;
        if (block.timestamp < minFinish) vm.warp(minFinish);
        _step(player, 5, 0);
        assertEq(uint8(game.battleOf(player).status), uint8(Battlefield.Status.Won));
    }

    function _close(uint64 day) internal {
        vm.warp((uint256(day) + 1) * 1 days);
    }

    function _epoch(uint64 day) internal view returns (Game.Epoch memory pool) {
        (
            pool.tokenBudget,
            pool.prizeBudget,
            pool.tokenRevenue,
            pool.prizeRevenue,
            pool.totalPower,
            pool.creditedPower,
            pool.tokenAllocated,
            pool.prizeAllocated
        ) = game.epochs(day);
    }

    function _assertSolvent() internal view {
        assertGe(token.balanceOf(address(game)), game.totalTokenLiability() + game.retiredTokens());
        assertGe(imd.balanceOf(address(game)), game.totalPrizeLiability());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccountingHandler} from "./GameInvariant.t.sol";
import {GameFixture, MockAsset} from "./helpers/GameFixture.sol";
import {Game} from "src/Game.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev Extends the existing legal-gameplay driver with multiple sponsors, partial refunds,
/// unsolicited transfers and rejected operations. Ghost cashflows never come from liabilities.
contract MultiSponsorAccountingHandler is AccountingHandler {
    uint256 public donatedTokens;
    uint256 public donatedPrizes;
    uint256 public partialRefunds;
    uint256 public rejectedOperations;

    constructor(Game game_, LaunchToken token_, MockAsset imd_, address sponsor_, address[3] memory players_)
        AccountingHandler(game_, token_, imd_, sponsor_, players_)
    {}

    function fundAsPlayer(uint8 actor, uint96 tokens, uint96 prizes, uint8 offset) external {
        address player = players[actor % 3];
        tokens = uint96(bound(tokens, 0, 10 ether));
        prizes = uint96(bound(prizes, 0, 10 ether));
        if (tokens == 0 && prizes == 0) tokens = 1;
        uint64 epoch = uint64(block.timestamp / 1 days + 1 + offset % 3);
        vm.startPrank(player);
        token.approve(address(game), tokens);
        imd.approve(address(game), prizes);
        game.fund(epoch, tokens, prizes);
        vm.stopPrank();
        depositedTokens += tokens;
        depositedPrizes += prizes;
    }

    function donate(uint8 actor, uint96 tokens, uint96 prizes) external {
        address player = players[actor % 3];
        tokens = uint96(bound(tokens, 0, 10 ether));
        prizes = uint96(bound(prizes, 0, 10 ether));
        vm.startPrank(player);
        token.transfer(address(game), tokens);
        imd.transfer(address(game), prizes);
        vm.stopPrank();
        donatedTokens += tokens;
        donatedPrizes += prizes;
    }

    function refundPart(uint8 actor, uint8 epochSeed, uint8 part) external {
        address player = actor % 4 == 3 ? sponsor : players[actor % 4];
        uint64 today = uint64(block.timestamp / 1 days);
        // Includes current/future epochs so failures are exercised as well as successful refunds.
        uint64 epoch = firstEpoch + uint64(epochSeed % (today + 4 - firstEpoch));
        (uint256 tokens, uint256 prizes) = game.contributions(epoch, player);
        (,,,, uint256 power,,,) = game.epochs(epoch);
        part %= 3;
        if (part == 1) prizes = 0;
        if (part == 2) tokens = 0;
        bytes memory callData = part == 0
            ? abi.encodeCall(Game.refund, (epoch))
            : part == 1 ? abi.encodeCall(Game.refundToken, (epoch)) : abi.encodeCall(Game.refundPrize, (epoch));
        uint256 beforeTokens = token.balanceOf(player);
        uint256 beforePrizes = imd.balanceOf(player);
        vm.prank(player);
        (bool success, bytes memory reason) = address(game).call(callData);
        if (today <= epoch || power != 0 || tokens + prizes == 0) {
            assertFalse(success, "ineligible refund succeeded");
            assertEq(
                reason, abi.encodeWithSelector(today <= epoch ? Game.EpochNotClosed.selector : Game.NoRefund.selector)
            );
            assertEq(token.balanceOf(player), beforeTokens);
            assertEq(imd.balanceOf(player), beforePrizes);
            rejectedOperations++;
            return;
        }
        assertTrue(success, "eligible refund must be live");
        assertEq(token.balanceOf(player) - beforeTokens, tokens);
        assertEq(imd.balanceOf(player) - beforePrizes, prizes);
        withdrawnTokens += tokens;
        withdrawnPrizes += prizes;
        partialRefunds++;
    }

    function rejectClosedFunding(uint8 actor, uint96 amount) external {
        address player = players[actor % 3];
        uint64 today = uint64(block.timestamp / 1 days);
        bytes32 beforeEpoch = _epochDigest(today);
        uint256 beforeTokens = token.balanceOf(player);
        uint128 deposit = uint128(bound(amount, 1, 100 ether));
        vm.prank(player);
        vm.expectRevert(Game.InvalidEpoch.selector);
        game.fund(today, deposit, 0);
        assertEq(_epochDigest(today), beforeEpoch);
        assertEq(token.balanceOf(player), beforeTokens);
        rejectedOperations++;
    }

    function _epochDigest(uint64 epoch) private view returns (bytes32) {
        (uint256 t, uint256 p, uint256 tr, uint256 pr, uint256 power, uint256 credited, uint256 ta, uint256 pa) =
            game.epochs(epoch);
        return keccak256(abi.encode(t, p, tr, pr, power, credited, ta, pa));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GameLedgerInvariantTest is GameFixture {
    MultiSponsorAccountingHandler private handler;

    function setUp() public override {
        super.setUp();
        token.transfer(outsider, 10_000 ether);
        imd.mint(alice, 10_000 ether);
        imd.mint(bob, 10_000 ether);
        imd.mint(outsider, 10_000 ether);
        handler = new MultiSponsorAccountingHandler(game, token, imd, sponsor, [alice, bob, outsider]);

        // Seed every sequence with earned, unclaimed credits and a separate refundable epoch.
        // This makes the accounting properties meaningful even before the first random call.
        handler.fundAsPlayer(1, 17, 19, 1);
        handler.buy(2, 0);
        handler.donate(0, 1, 1);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        handler.win(0, 0);
        handler.win(1, 2);
        vm.warp(uint256(FIRST_DAY + 1) * 1 days);
        handler.accrue(0);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.passTime.selector;
        selectors[2] = handler.win.selector;
        selectors[3] = handler.buy.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.accrue.selector;
        selectors[6] = handler.refund.selector;
        selectors[7] = handler.recycle.selector;
        selectors[8] = handler.fundAsPlayer.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.refundPart.selector;
        selectors[11] = handler.rejectClosedFunding.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_cashflowsBackLiabilitiesRetirementAndUnownedDonations() public view {
        assertEq(
            token.balanceOf(address(game)),
            handler.depositedTokens() + handler.spentTokens() + handler.donatedTokens() - handler.withdrawnTokens()
        );
        assertEq(
            imd.balanceOf(address(game)),
            handler.depositedPrizes() + handler.donatedPrizes() - handler.withdrawnPrizes()
        );
        assertEq(
            token.balanceOf(address(game)), game.totalTokenLiability() + game.retiredTokens() + handler.donatedTokens()
        );
        assertEq(imd.balanceOf(address(game)), game.totalPrizeLiability() + handler.donatedPrizes());
        assertEq(game.retiredTokens(), handler.spentTokens() * 3 / 4);
        assertEq(token.totalSupply(), 1e27);
    }

    /// @dev Unlike checking only two total counters against balances, this traverses every
    /// reachable epoch and actor: liabilities = unallocated budgets + permanent credits.
    function invariant_sumOfIndividualReservesAndCreditsEqualsLiabilities() public view {
        uint256 tokenReserves;
        uint256 prizeReserves;
        uint64 lastPossibleEpoch = uint64(block.timestamp / 1 days + 3);
        for (uint64 epoch = FIRST_DAY; epoch <= lastPossibleEpoch; ++epoch) {
            Game.Epoch memory pool = _epoch(epoch);
            assertLe(pool.tokenAllocated, pool.tokenBudget);
            assertLe(pool.prizeAllocated, pool.prizeBudget);
            assertLe(pool.creditedPower, pool.totalPower);
            tokenReserves += pool.tokenBudget - pool.tokenAllocated;
            prizeReserves += pool.prizeBudget - pool.prizeAllocated;

            uint256 unaccruedPower;
            for (uint256 i; i < 3; ++i) {
                Game.RewardAccount memory rewards = game.rewardsOf(handler.players(i));
                if (rewards.epoch == epoch) unaccruedPower += rewards.power;
            }
            assertEq(pool.totalPower, pool.creditedPower + unaccruedPower, "power is neither lost nor counted twice");

            if (pool.totalPower == 0) {
                uint256 sponsorTokens;
                uint256 sponsorPrizes;
                for (uint256 i; i < 4; ++i) {
                    address account = i == 3 ? sponsor : handler.players(i);
                    (uint256 tokens, uint256 prizes) = game.contributions(epoch, account);
                    sponsorTokens += tokens;
                    sponsorPrizes += prizes;
                }
                assertEq(
                    pool.tokenBudget, sponsorTokens + pool.tokenRevenue, "empty-day token deposits stay refundable"
                );
                assertEq(
                    pool.prizeBudget, sponsorPrizes + pool.prizeRevenue, "empty-day prize deposits stay refundable"
                );
            }
        }
        for (uint256 i; i < 3; ++i) {
            Game.RewardAccount memory rewards = game.rewardsOf(handler.players(i));
            tokenReserves += rewards.tokens;
            prizeReserves += rewards.prizes;
        }
        assertEq(tokenReserves, game.totalTokenLiability(), "token liabilities equal individual reserves");
        assertEq(prizeReserves, game.totalPrizeLiability(), "prize liabilities equal individual reserves");
    }

    function test_handlerExercisesRefundsRecyclingClaimsAndRejections() public {
        handler.claim(0);
        handler.accrue(1);
        handler.recycle(0);
        vm.warp(uint256(FIRST_DAY + 2) * 1 days);
        handler.refundPart(1, 1, 1);
        handler.refundPart(1, 1, 2);
        handler.refundPart(1, 1, 0);
        handler.rejectClosedFunding(0, 1);
        assertEq(handler.partialRefunds(), 2);
        assertEq(handler.rejectedOperations(), 2);
        assertGt(handler.withdrawnTokens(), 17);
        assertGt(handler.withdrawnPrizes(), 19);
        invariant_cashflowsBackLiabilitiesRetirementAndUnownedDonations();
        invariant_sumOfIndividualReservesAndCreditsEqualsLiabilities();
    }
}

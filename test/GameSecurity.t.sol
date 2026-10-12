// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture, MockAsset} from "./helpers/GameFixture.sol";
import {Game} from "../src/Game.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Battlefield} from "../src/lib/Battlefield.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RejectingOwner {
    function recover(Game game) external {
        game.recoverForcedEther();
    }
}

contract ReenteringOwner {
    Game public game;
    bool public tried;
    bool public reentered;

    function configure(Game game_) external {
        game = game_;
    }

    function recover() external {
        game.recoverForcedEther();
    }

    receive() external payable {
        tried = true;
        (reentered,) = address(game).call(abi.encodeCall(Game.recoverForcedEther, ()));
    }
}

contract ReenteringPlayer {
    Game public immutable game;
    bool public tried;
    bool public reentered;

    constructor(Game game_) {
        game = game_;
    }

    function claim() external {
        game.claimPrize();
    }

    function reenter() external {
        tried = true;
        (reentered,) = address(game).call(abi.encodeCall(Game.claimPrize, ()));
    }
}

contract NoReturnAsset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address to, uint256 amount) external {
        allowance[msg.sender][to] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FalseReturnAsset {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract GameSecurityTest is GameFixture {
    function test_constructorIsFullyConfiguredWithoutCalls() public {
        address tokenWithoutCode = makeAddr("futureToken");
        Game configured = new Game(creator, tokenWithoutCode);
        assertEq(configured.owner(), creator);
        assertEq(address(configured.launchToken()), tokenWithoutCode);
        assertEq(address(configured.prizeToken()), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        assertEq(configured.totalTokenLiability(), 0);
        assertEq(configured.totalPrizeLiability(), 0);
        vm.expectRevert();
        configured.fund(FIRST_DAY, 1, 0);
    }

    function test_constructorRejectsInvalidConfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Game(address(0), address(token));
        vm.expectRevert(Game.InvalidAddress.selector);
        new Game(creator, address(0));
        vm.expectRevert(Game.InvalidAddress.selector);
        new Game(creator, address(imd));
    }

    function test_factoryDeploymentPreservesEntireLaunchSupply() public {
        LaunchToken fresh = new LaunchToken();
        Game application = new Game(creator, address(fresh));
        assertEq(fresh.balanceOf(address(this)), 1e27);
        assertEq(fresh.balanceOf(address(application)), 0);
        assertEq(application.owner(), creator);
        assertNotEq(application.owner(), address(this));
    }

    function test_ownershipTransferRequiresAcceptanceAndCanRenounce() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        game.transferOwnership(bob);
        vm.prank(creator);
        game.transferOwnership(bob);
        assertEq(game.owner(), creator);
        assertEq(game.pendingOwner(), bob);
        vm.prank(outsider);
        vm.expectRevert();
        game.acceptOwnership();
        vm.prank(bob);
        game.acceptOwnership();
        assertEq(game.owner(), bob);
        vm.prank(bob);
        game.renounceOwnership();
        assertEq(game.owner(), address(0));
        _win(alice, 0, 1);
    }

    function test_ownerHasNoRewardSeizureOrResultSetter() public {
        _fundAndOpen(100, 100);
        _win(alice, 0, 1);
        string[5] memory signatures = [
            "withdraw(address,uint256)",
            "setScore(address,uint256)",
            "settle(address,uint256)",
            "setReward(uint256)",
            "upgradeTo(address)"
        ];
        vm.startPrank(creator);
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(game).call(abi.encodeWithSignature(signatures[i], creator, uint256(100)));
            assertFalse(ok);
        }
        game.renounceOwnership();
        vm.stopPrank();
        _close(FIRST_DAY);
        vm.prank(alice);
        game.claim();
        vm.prank(alice);
        game.claimPrize();
        assertEq(imd.balanceOf(alice), 100);
    }

    function test_forcedEtherRecoveryAndReentrancyGuard() public {
        vm.deal(address(game), 1 ether);
        vm.prank(outsider);
        vm.expectRevert();
        game.recoverForcedEther();
        uint256 beforeBalance = creator.balance;
        vm.prank(creator);
        game.recoverForcedEther();
        assertEq(creator.balance, beforeBalance + 1 ether);
        assertEq(address(game).balance, 0);

        ReenteringOwner receiver = new ReenteringOwner();
        Game guarded = new Game(address(receiver), address(token));
        receiver.configure(guarded);
        vm.deal(address(guarded), 1 ether);
        receiver.recover();
        assertTrue(receiver.tried());
        assertFalse(receiver.reentered());
        assertEq(address(receiver).balance, 1 ether);
    }

    function test_rejectedForcedEtherRecoveryRollsBack() public {
        RejectingOwner receiver = new RejectingOwner();
        Game owned = new Game(address(receiver), address(token));
        vm.deal(address(owned), 1 ether);
        vm.expectRevert(Game.NativeTransferFailed.selector);
        receiver.recover(owned);
        assertEq(address(owned).balance, 1 ether);
    }

    function test_failedFundingRollsBackBothAssetsAndLedgers() public {
        imd.configure(true, false);
        uint256 beforeBalance = token.balanceOf(sponsor);
        vm.prank(sponsor);
        vm.expectRevert();
        game.fund(FIRST_DAY, 100, 100);
        assertEq(token.balanceOf(sponsor), beforeBalance);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(_epoch(FIRST_DAY).prizeBudget, 0);
        (uint256 contributedTokens, uint256 contributedPrizes) = game.contributions(FIRST_DAY, sponsor);
        assertEq(contributedTokens + contributedPrizes, 0);
    }

    function test_feeOnTransferFundingIsRejected() public {
        imd.configure(false, true);
        vm.prank(sponsor);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.fund(FIRST_DAY, 0, 100);
        assertEq(imd.balanceOf(address(game)), 0);
        assertEq(game.totalPrizeLiability(), 0);
    }

    function test_missingApprovalCannotCreateCredit() public {
        vm.prank(alice);
        vm.expectRevert();
        game.fund(FIRST_DAY, 100, 0);
        assertEq(_epoch(FIRST_DAY).tokenBudget, 0);
        vm.prank(alice);
        vm.expectRevert();
        game.act(_action(8, 0, 0, 0));
        assertEq(game.cosmetics(alice), 0);
        assertEq(game.retiredTokens(), 0);
    }

    function test_failedPrizeClaimPreservesCreditAndTokenClaimStillWorks() public {
        _fundAndOpen(100, 100);
        _win(alice, 0, 1);
        _close(FIRST_DAY);
        imd.configure(true, false);
        vm.prank(alice);
        vm.expectRevert();
        game.claimPrize();
        assertEq(game.prizeClaimable(alice), 100);
        assertEq(game.totalPrizeLiability(), 100);
        assertGt(game.rewardsOf(alice).power, 0);
        vm.prank(alice);
        game.claim();
        assertEq(game.claimable(alice), 0);
        assertEq(game.prizeClaimable(alice), 100);
        imd.configure(false, false);
        vm.prank(alice);
        game.claimPrize();
        assertEq(imd.balanceOf(alice), 100);
    }

    function test_feeOnTransferClaimAndRefundRollback() public {
        _fundAndOpen(0, 100);
        _win(alice, 0, 1);
        _close(FIRST_DAY);
        imd.configure(false, true);
        vm.prank(alice);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.claimPrize();
        assertEq(game.prizeClaimable(alice), 100);
        assertEq(imd.balanceOf(alice), 0);
        imd.configure(false, false);
        _fund(FIRST_DAY + 2, 100, 100);
        _close(FIRST_DAY + 2);
        uint256 sponsorBalance = token.balanceOf(sponsor);
        imd.configure(false, true);
        vm.prank(sponsor);
        vm.expectRevert(Game.InexactTransfer.selector);
        game.refund(FIRST_DAY + 2);
        assertEq(token.balanceOf(sponsor), sponsorBalance);
        (uint256 contributed,) = game.contributions(FIRST_DAY + 2, sponsor);
        assertEq(contributed, 100);
        _assertSolvent();
    }

    function test_independentRefundDoesNotDependOnOtherAssetAvailability() public {
        _fund(FIRST_DAY, 100, 200);
        _close(FIRST_DAY);
        imd.configure(true, false);
        vm.prank(sponsor);
        game.refundToken(FIRST_DAY);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 200);
        (uint256 tokens, uint256 prizes) = game.contributions(FIRST_DAY, sponsor);
        assertEq(tokens, 0);
        assertEq(prizes, 200);
        vm.prank(sponsor);
        vm.expectRevert();
        game.refundPrize(FIRST_DAY);
        imd.configure(false, false);
        vm.prank(sponsor);
        game.refundPrize(FIRST_DAY);
        assertEq(game.totalPrizeLiability(), 0);
        vm.prank(sponsor);
        vm.expectRevert(Game.NoRefund.selector);
        game.refund(FIRST_DAY);
        _assertSolvent();
    }

    function test_reentrantTokenCannotStartGameDuringFunding() public {
        imd.setCallback(address(game), abi.encodeCall(Game.act, (_action(0, 1, 0, 0))));
        _fund(FIRST_DAY, 0, 100);
        assertTrue(imd.callbackAttempted());
        assertFalse(imd.callbackSucceeded());
        assertEq(uint8(game.battleOf(address(imd)).status), uint8(Battlefield.Status.None));
        _assertSolvent();
    }

    function test_reentrantTokenCannotDoubleClaimOrCorruptAccrual() public {
        _fundAndOpen(100, 100);
        _win(alice, 0, 1);
        _close(FIRST_DAY);
        imd.setCallback(address(game), abi.encodeCall(Game.claimPrize, ()));
        vm.prank(alice);
        game.claimPrize();
        assertTrue(imd.callbackAttempted());
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.balanceOf(alice), 100);
        assertEq(game.prizeClaimable(alice), 0);
        assertEq(game.claimable(alice), 100);
    }

    function test_sameWalletReentrancyCannotSpendEntitlementTwice() public {
        ReenteringPlayer player = new ReenteringPlayer(game);
        _fundAndOpen(0, 100);
        _win(address(player), 0, 1);
        _close(FIRST_DAY);
        imd.setCallback(address(player), abi.encodeCall(ReenteringPlayer.reenter, ()));
        player.claim();
        assertTrue(player.tried());
        assertFalse(player.reentered());
        assertEq(imd.balanceOf(address(player)), 100);
        assertEq(game.totalPrizeLiability(), 0);
        assertEq(game.prizeClaimable(address(player)), 0);
    }

    function test_missingAssetOnPayoutPreservesEntitlement() public {
        _fundAndOpen(0, 100);
        _win(alice, 0, 1);
        _close(FIRST_DAY);
        bytes memory runtime = address(imd).code;
        vm.etch(address(imd), hex"");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Game.AssetUnavailable.selector, address(imd)));
        game.claimPrize();
        assertEq(game.prizeClaimable(alice), 100);
        vm.etch(address(imd), runtime);
        vm.prank(alice);
        game.claimPrize();
        assertEq(imd.balanceOf(alice), 100);
    }

    function test_reentrantRefundCannotWithdrawTwice() public {
        _fund(FIRST_DAY, 100, 100);
        _close(FIRST_DAY);
        imd.setCallback(address(game), abi.encodeCall(Game.refund, (FIRST_DAY)));
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        assertTrue(imd.callbackAttempted());
        assertFalse(imd.callbackSucceeded());
        assertEq(game.totalPrizeLiability(), 0);
        _assertSolvent();
    }

    function test_nonReturningERC20WorksButFalseReturningFails() public {
        NoReturnAsset legacy = new NoReturnAsset();
        vm.etch(address(imd), address(legacy).code);
        NoReturnAsset asset = NoReturnAsset(address(imd));
        asset.mint(sponsor, 100);
        vm.prank(sponsor);
        asset.approve(address(game), 100);
        _fund(FIRST_DAY, 0, 100);
        _close(FIRST_DAY);
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        assertEq(asset.balanceOf(address(game)), 0);
        FalseReturnAsset broken = new FalseReturnAsset();
        vm.etch(address(imd), address(broken).code);
        vm.prank(sponsor);
        vm.expectRevert();
        game.fund(FIRST_DAY + 2, 0, 100);
        assertEq(game.totalPrizeLiability(), 0);
    }

    function test_unsolicitedTransferCreatesNoRewardCredit() public {
        token.transfer(address(game), 100);
        imd.mint(address(game), 100);
        assertEq(game.totalTokenLiability(), 0);
        assertEq(game.totalPrizeLiability(), 0);
        assertFalse(game.rewardAvailable(alice));
        _assertSolvent();
    }

    function test_deployedBytecodeMeetsProtectedFloor() public view {
        _checkRuntime(address(game).code);
        _checkRuntime(address(token).code);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}

contract GameCosmeticsTest is GameFixture {
    function test_cosmeticRetirementAndFutureFunding() public {
        vm.startPrank(alice);
        token.approve(address(game), 100 ether);
        game.act(_action(8, 0, 0, 3));
        vm.stopPrank();
        assertEq(game.cosmetics(alice), 8);
        assertEq(game.retiredTokens(), 75 ether);
        assertEq(game.totalTokenLiability(), 25 ether);
        assertEq(_epoch(FIRST_DAY).tokenBudget, 25 ether);
        assertEq(_epoch(FIRST_DAY).tokenRevenue, 25 ether);
        assertEq(token.balanceOf(address(game)), 100 ether);
        assertEq(token.allowance(alice, address(game)), 0);
        assertEq(token.totalSupply(), 1e27);
        vm.warp(uint256(FIRST_DAY) * 1 days);
        _win(bob, 0, 1);
        _close(FIRST_DAY);
        vm.prank(bob);
        game.claim();
        assertEq(token.balanceOf(address(game)), 75 ether);
        assertEq(game.totalTokenLiability(), 0);
        _assertSolvent();
    }

    function test_duplicateOrInvalidSkinCannotChargeAgain() public {
        vm.startPrank(alice);
        token.approve(address(game), 200 ether);
        game.act(_action(8, 0, 0, 7));
        vm.expectRevert(Game.AlreadyOwned.selector);
        game.act(_action(8, 0, 0, 7));
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(_action(8, 0, 0, 8));
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(_action(8, 1, 0, 0));
        vm.expectRevert(Game.InvalidAction.selector);
        game.act(_action(8, 0, 1, 0));
        vm.stopPrank();
        assertEq(token.balanceOf(address(game)), 100 ether);
        assertEq(game.cosmetics(alice), 128);
        assertEq(game.cosmetics(bob), 0);
    }

    function test_emptyDayRevenueRecyclesAndSponsorsRefundIndependently() public {
        _fund(FIRST_DAY, 100 ether, 50 ether);
        vm.startPrank(alice);
        token.approve(address(game), 100 ether);
        game.act(_action(8, 0, 0, 0));
        vm.stopPrank();
        _close(FIRST_DAY);
        game.recycle(FIRST_DAY);
        assertEq(_epoch(FIRST_DAY).tokenBudget, 100 ether);
        assertEq(_epoch(FIRST_DAY + 2).tokenRevenue, 25 ether);
        vm.prank(sponsor);
        game.refund(FIRST_DAY);
        assertEq(game.totalTokenLiability(), 25 ether);
        assertEq(game.totalPrizeLiability(), 0);
        assertEq(game.retiredTokens(), 75 ether);
        _assertSolvent();
    }
}

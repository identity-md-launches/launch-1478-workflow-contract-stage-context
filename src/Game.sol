// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Battlefield} from "./lib/Battlefield.sol";
import {CommandPower} from "./lib/CommandPower.sol";

/// @notice RH PEPEFRONT: deterministic solo battles and deposit-backed daily rewards.
/// @dev No admin can settle a result, change rules, or withdraw reward liabilities.
contract Game is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Battlefield for Battlefield.Battle;
    using CommandPower for CommandPower.Account;

    uint256 public constant DAY = 1 days;
    uint256 public constant MATCH_DURATION = 20 minutes;
    uint256 public constant COSMETIC_PRICE = 100 ether;
    uint256 public constant FUNDING_HORIZON = 30;
    IERC20 public constant prizeToken = IERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    IERC20 public immutable launchToken;

    struct Epoch {
        uint256 tokenBudget;
        uint256 prizeBudget;
        uint256 tokenRevenue;
        uint256 prizeRevenue;
        uint256 totalPower;
        uint256 creditedPower;
        uint256 tokenAllocated;
        uint256 prizeAllocated;
    }

    struct Contribution {
        uint256 tokens;
        uint256 prizes;
    }

    struct RewardAccount {
        uint64 epoch;
        uint256 power;
        uint256 tokens;
        uint256 prizes;
    }

    mapping(address => Battlefield.Battle) private _battles;
    mapping(address => CommandPower.Account) private _command;
    mapping(address => RewardAccount) private _rewards;
    mapping(uint64 => Epoch) public epochs;
    mapping(uint64 => mapping(address => Contribution)) public contributions;
    mapping(address => uint256) public cosmetics;

    uint256 public totalTokenLiability;
    uint256 public totalPrizeLiability;
    uint256 public retiredTokens;

    error InvalidAddress();
    error InvalidAction();
    error NativeValueNotAccepted();
    error InvalidEpoch();
    error InvalidAmount();
    error NothingToClaim();
    error EpochNotClosed();
    error NoRefund();
    error AlreadyOwned();
    error InexactTransfer();
    error AssetUnavailable(address asset);
    error NativeTransferFailed();
    error NotExpired();

    event BattleStarted(
        address indexed player, uint64 indexed id, uint64 indexed epoch, uint8 selection, bool rewarded
    );
    event Move(address indexed player, uint64 indexed id, uint8 turn, uint8 command, uint8 argument);
    event BattleFinished(address indexed player, uint64 indexed id, Battlefield.Status result, uint256 power);
    event Funded(address indexed sponsor, uint64 indexed epoch, uint256 tokens, uint256 prizes);
    event RewardsAccrued(address indexed player, uint64 indexed epoch, uint256 power, uint256 tokens, uint256 prizes);
    event Claimed(address indexed player, uint8 indexed asset, uint256 amount);
    event Refunded(address indexed sponsor, uint64 indexed epoch, uint256 tokens, uint256 prizes);
    event Recycled(uint64 indexed source, uint64 indexed destination, uint256 tokens, uint256 prizes);
    event CosmeticBought(address indexed player, uint8 indexed cosmetic, uint256 retired, uint256 rewardFunding);
    event ForcedEtherRecovered(address indexed recipient, uint256 amount);

    /// @dev Only stores configuration. No external calls or code checks during construction.
    constructor(address initialOwner, address token) Ownable(initialOwner) {
        if (token == address(0) || token == address(this) || token == address(prizeToken)) revert InvalidAddress();
        launchToken = IERC20(token);
    }

    /// @notice ABI encoding is documented in docs/INTERFACE.md. ETH is always rejected.
    function act(bytes calldata action) external payable nonReentrant {
        if (msg.value != 0) revert NativeValueNotAccepted();
        if (action.length != 128) revert InvalidAction();
        (uint8 command, uint64 id, uint8 turn, uint8 argument) = abi.decode(action, (uint8, uint64, uint8, uint8));
        if (command == 0) {
            if (turn != 0) revert InvalidAction();
            _start(msg.sender, id, argument);
        } else if (command <= 7) {
            Battlefield.Battle storage battle = _battles[msg.sender];
            battle.step(id, turn, command, argument);
            emit Move(msg.sender, id, turn, command, argument);
            if (battle.status != Battlefield.Status.Active) _finish(msg.sender);
        } else if (command == 8) {
            if (id != 0 || turn != 0) revert InvalidAction();
            _buyCosmetic(msg.sender, argument);
        } else if (command == 9) {
            if (id != 0 || turn != 0 || argument != 0) revert InvalidAction();
            _claimPrize(msg.sender);
        } else {
            revert InvalidAction();
        }
    }

    /// @notice Anyone may close an abandoned session; no third party can redirect rewards.
    function expire(address player, uint64 id) external nonReentrant {
        Battlefield.Battle storage battle = _battles[player];
        if (battle.status != Battlefield.Status.Active) revert Battlefield.NotActive();
        if (battle.id != id) revert Battlefield.WrongSession();
        if (block.timestamp < battle.deadline) revert NotExpired();
        battle.status = Battlefield.Status.Expired;
        emit BattleFinished(player, id, battle.status, 0);
    }

    /// @notice Sponsor a future UTC day. Funding closes before that day's first battle.
    /// @dev Contributions are refundable only if the epoch ends with zero earned power.
    function fund(uint64 epoch, uint128 tokens, uint128 prizes) external nonReentrant {
        uint256 today = block.timestamp / DAY;
        if (epoch <= today || epoch > today + FUNDING_HORIZON) revert InvalidEpoch();
        if (tokens == 0 && prizes == 0) revert InvalidAmount();
        Epoch storage pool = epochs[epoch];
        Contribution storage contribution = contributions[epoch][msg.sender];
        pool.tokenBudget += tokens;
        pool.prizeBudget += prizes;
        contribution.tokens += tokens;
        contribution.prizes += prizes;
        totalTokenLiability += tokens;
        totalPrizeLiability += prizes;
        if (tokens != 0) _pull(launchToken, tokens);
        if (prizes != 0) _pull(prizeToken, prizes);
        emit Funded(msg.sender, epoch, tokens, prizes);
    }

    function refund(uint64 epoch) external nonReentrant {
        _refund(epoch, true, true);
    }

    /// @notice Recover an empty-day token deposit independently of IMD availability.
    function refundToken(uint64 epoch) external nonReentrant {
        _refund(epoch, true, false);
    }

    /// @notice Recover an empty-day IMD deposit independently of launch-token availability.
    function refundPrize(uint64 epoch) external nonReentrant {
        _refund(epoch, false, true);
    }

    function _refund(uint64 epoch, bool tokenRefund, bool prizeRefund) private {
        if (block.timestamp / DAY <= epoch) revert EpochNotClosed();
        Epoch storage pool = epochs[epoch];
        if (pool.totalPower != 0) revert NoRefund();
        Contribution storage source = contributions[epoch][msg.sender];
        Contribution memory contribution =
            Contribution({tokens: tokenRefund ? source.tokens : 0, prizes: prizeRefund ? source.prizes : 0});
        if (contribution.tokens == 0 && contribution.prizes == 0) revert NoRefund();
        if (tokenRefund) source.tokens = 0;
        if (prizeRefund) source.prizes = 0;
        pool.tokenBudget -= contribution.tokens;
        pool.prizeBudget -= contribution.prizes;
        totalTokenLiability -= contribution.tokens;
        totalPrizeLiability -= contribution.prizes;
        if (contribution.tokens != 0) _push(launchToken, msg.sender, contribution.tokens);
        if (contribution.prizes != 0) _push(prizeToken, msg.sender, contribution.prizes);
        emit Refunded(msg.sender, epoch, contribution.tokens, contribution.prizes);
    }

    /// @notice Move unused cosmetic revenue or fully allocated epoch rounding dust to tomorrow.
    /// @dev Unclaimed credits and refundable sponsor deposits remain reserved.
    function recycle(uint64 epoch) external nonReentrant {
        if (block.timestamp / DAY <= epoch) revert EpochNotClosed();
        Epoch storage source = epochs[epoch];
        uint256 tokens;
        uint256 prizes;
        if (source.totalPower == 0) {
            tokens = source.tokenRevenue;
            prizes = source.prizeRevenue;
        } else {
            if (source.creditedPower != source.totalPower) revert EpochNotClosed();
            tokens = source.tokenBudget - source.tokenAllocated;
            prizes = source.prizeBudget - source.prizeAllocated;
        }
        if (tokens == 0 && prizes == 0) revert InvalidAmount();
        source.tokenRevenue = 0;
        source.prizeRevenue = 0;
        source.tokenBudget -= tokens;
        source.prizeBudget -= prizes;
        uint64 destination = uint64(block.timestamp / DAY + 1);
        Epoch storage target = epochs[destination];
        target.tokenBudget += tokens;
        target.prizeBudget += prizes;
        target.tokenRevenue += tokens;
        target.prizeRevenue += prizes;
        emit Recycled(epoch, destination, tokens, prizes);
    }

    function claim() external nonReentrant {
        _accrue(msg.sender);
        uint256 amount = _rewards[msg.sender].tokens;
        if (amount == 0) revert NothingToClaim();
        _rewards[msg.sender].tokens = 0;
        totalTokenLiability -= amount;
        _push(launchToken, msg.sender, amount);
        emit Claimed(msg.sender, 0, amount);
    }

    function claimPrize() external nonReentrant {
        _claimPrize(msg.sender);
    }

    /// @notice Permissionless accounting only; funds stay credited to the named player.
    function accrue(address player) external nonReentrant {
        _accrue(player);
    }

    function claimable(address player) public view returns (uint256) {
        (uint256 tokens,) = _pending(player);
        return _rewards[player].tokens + tokens;
    }

    function prizeClaimable(address player) public view returns (uint256) {
        (, uint256 prizes) = _pending(player);
        return _rewards[player].prizes + prizes;
    }

    function battleOf(address player) external view returns (Battlefield.Battle memory) {
        return _battles[player];
    }

    function commandOf(address player) external view returns (CommandPower.Account memory) {
        return _command[player];
    }

    function rewardsOf(address player) external view returns (RewardAccount memory) {
        return _rewards[player];
    }

    function state(address player) external view returns (bytes memory) {
        return abi.encode(
            uint8(1),
            _battles[player],
            _command[player],
            _rewards[player],
            cosmetics[player],
            claimable(player),
            prizeClaimable(player)
        );
    }

    function rewardAvailable(address player) public view returns (bool) {
        uint256 day = block.timestamp / DAY;
        if (block.timestamp + MATCH_DURATION > (day + 1) * DAY) return false;
        Epoch storage pool = epochs[uint64(day)];
        return (pool.tokenBudget != 0 || pool.prizeBudget != 0) && _command[player].eligible();
    }

    /// @notice ETH is never accepted by act. Only forcibly sent ETH can reach this balance.
    function recoverForcedEther() external nonReentrant onlyOwner {
        uint256 amount = address(this).balance;
        address recipient = owner();
        emit ForcedEtherRecovered(recipient, amount);
        if (amount > 0) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        }
    }

    function _start(address player, uint64 id, uint8 selection) private {
        bool rewarded = rewardAvailable(player);
        _battles[player].start(id, selection, rewarded);
        emit BattleStarted(player, id, _battles[player].epoch, selection, rewarded);
    }

    function _finish(address player) private {
        Battlefield.Battle storage battle = _battles[player];
        uint256 power = 0;
        if (battle.status == Battlefield.Status.Won && battle.rewarded) {
            // A rewarded battle must finish in its original epoch; the start gate ensures this.
            if (block.timestamp >= (uint256(battle.epoch) + 1) * DAY) revert InvalidEpoch();
            _accrue(player);
            power = _command[player].record(battle.difficulty, battle.harvests);
            RewardAccount storage account = _rewards[player];
            account.epoch = battle.epoch;
            account.power += power;
            epochs[battle.epoch].totalPower += power;
        }
        emit BattleFinished(player, battle.id, battle.status, power);
    }

    function _buyCosmetic(address player, uint8 cosmetic) private {
        if (cosmetic >= 8) revert InvalidAction();
        uint256 bit = uint256(1) << cosmetic;
        if ((cosmetics[player] & bit) != 0) revert AlreadyOwned();
        cosmetics[player] |= bit;
        uint256 retired = COSMETIC_PRICE * 3 / 4;
        uint256 funding = COSMETIC_PRICE - retired;
        retiredTokens += retired;
        totalTokenLiability += funding;
        Epoch storage pool = epochs[uint64(block.timestamp / DAY + 1)];
        pool.tokenBudget += funding;
        pool.tokenRevenue += funding;
        _pull(launchToken, COSMETIC_PRICE);
        emit CosmeticBought(player, cosmetic, retired, funding);
    }

    function _accrue(address player) private {
        RewardAccount storage account = _rewards[player];
        if (account.power == 0 || block.timestamp / DAY <= account.epoch) return;
        (uint256 tokens, uint256 prizes) = _pending(player);
        Epoch storage pool = epochs[account.epoch];
        uint256 power = account.power;
        account.power = 0;
        account.tokens += tokens;
        account.prizes += prizes;
        pool.creditedPower += power;
        pool.tokenAllocated += tokens;
        pool.prizeAllocated += prizes;
        emit RewardsAccrued(player, account.epoch, power, tokens, prizes);
    }

    function _pending(address player) private view returns (uint256 tokens, uint256 prizes) {
        RewardAccount storage account = _rewards[player];
        if (account.power == 0 || block.timestamp / DAY <= account.epoch) return (0, 0);
        Epoch storage pool = epochs[account.epoch];
        tokens = Math.mulDiv(pool.tokenBudget, account.power, pool.totalPower);
        prizes = Math.mulDiv(pool.prizeBudget, account.power, pool.totalPower);
    }

    function _claimPrize(address player) private {
        _accrue(player);
        uint256 amount = _rewards[player].prizes;
        if (amount == 0) revert NothingToClaim();
        _rewards[player].prizes = 0;
        totalPrizeLiability -= amount;
        _push(prizeToken, player, amount);
        emit Claimed(player, 1, amount);
    }

    function _pull(IERC20 token, uint256 amount) private {
        if (address(token).code.length == 0) revert AssetUnavailable(address(token));
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert InexactTransfer();
    }

    function _push(IERC20 token, address to, uint256 amount) private {
        if (address(token).code.length == 0) revert AssetUnavailable(address(token));
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) != beforeBalance - amount || token.balanceOf(to) != beforeRecipient + amount)
        {
            revert InexactTransfer();
        }
    }
}

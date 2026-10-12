// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Wallet rate limits. These are not proof of identity or human play.
library CommandPower {
    uint256 internal constant DAY = 1 days;
    uint8 internal constant MAX_WINS = 3;
    uint8 internal constant MAX_HARVESTS = 5;

    struct Account {
        uint64 day;
        uint64 lastRewardAt;
        uint8 wins;
        uint8 harvests;
        bool rewardedBefore;
    }

    function eligible(Account storage account) internal view returns (bool) {
        if (account.rewardedBefore && block.timestamp < uint256(account.lastRewardAt) + DAY) return false;
        return account.day != block.timestamp / DAY || account.wins < MAX_WINS;
    }

    function record(Account storage account, uint8 difficulty, uint8 harvests) internal returns (uint256 power) {
        if (!eligible(account)) return 0;
        uint64 day = uint64(block.timestamp / DAY);
        if (account.day != day) {
            account.day = day;
            account.wins = 0;
            account.harvests = 0;
        }
        uint8 room = MAX_HARVESTS - account.harvests;
        uint8 counted = harvests < room ? harvests : room;
        account.harvests += counted;
        account.wins += 1;
        account.lastRewardAt = uint64(block.timestamp);
        account.rewardedBefore = true;
        return 10 * (uint256(difficulty) + 1) + counted;
    }
}

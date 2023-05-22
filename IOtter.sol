// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "./IOtterManager.sol";

interface IOtter is IOtterManager {
    enum StreamStatus {
        Joinable,
        Earning
    }

    struct Stream {
        bytes32 name;
        address organizer;
        uint256 createdAt;
        uint256 capacity;
        StreamStatus status;
        uint256 currentJoinableRaft;
        uint256 earningRafts;
        // total rafts
        uint256 totalRafts;
        uint256 firstEarningDate;
        uint256 reserveRate;
        uint256 firstWithdrawRate;
        // 项目保证金
        uint256 reserve;
        // 返还的收益
        uint256 term; // 利益返回最新周期(start from 0)
        uint256 cumulativeProfit;
        // 2442/100 = 24.22%
        uint256 expectedAPY;
        uint256 actuaAPY;
        // total contribution
        uint256 contribution;
        // withdrawed means organizer already started to withdraw the contribution
        bool withdrawed;
        // contibution which is undrawn
        uint256 undrawnContribution;
    }

    struct Term {
        uint256 index;
        uint256 earningRafts;
        uint256 profit;
        uint256 startAt;
        uint256 endAt;
        uint256 earnRaftsCapacity;
    }

    // (amount - cleared) => otter manager
    struct RaftProfit {
        uint256 term;
        uint256 amount;
        uint256 cleared; // by investors
        bool managerCleared; // by otter manager
    }

    enum RaftStatus {
        Unopen,
        Joinable,
        Earning
    }

    struct Raft {
        bytes32 stream;
        uint256 capacity;
        uint256 contribution;
        uint256 totalProfit;
        uint256 profitPerShare;
        RaftStatus status;
        bytes32 raftId;
    }

    struct Transfer {
        address from;
        address to;
        uint256 term;
        bytes32 stream;
        bytes32 raft;
        uint256 amount;
        uint256 profitPerShare;
        uint256 transferedAt;
    }

    function getTransfers() external view returns (Transfer[] memory);

    struct Exit {
        address investor;
        uint256 term;
        bytes32 stream;
        bytes32 raft;
        uint256 amount;
        uint256 beforeContribution;
        uint256 afterContribution;
        uint256 afterrofitPerDay;
        uint256 exitAt;
    }

    /// investor收益计算需要考虑多个情况：
    /// - 用户中途退出部分投资 (contibutionAtTermStart - contribution)
    /// - 用户中途向其他用户转出了部分投资(transfer out)
    /// - 用户中途接收到了其他用户的部分投资(transfer in)
    /// 即用户当前的投资总额： contribution + ins - outs
    struct Investor {
        address account;
        uint256 contribution;
        uint256 totalEarned;
        uint256 undrawnEarnings;
        uint256 lastCalTerm;
        uint256 lastCalTime;
        uint256[] transferIns;
        uint256[] transferOuts;
        uint256[] exits;
    }

    function getTimelock() external view returns(uint256);

    function getStream(bytes32 _streamId) external view returns (Stream memory);

    function getRafts(bytes32 _streamId) external view returns (Raft[] memory);

    function getTerms(bytes32 _streamId) external view returns (Term[] memory);

    function getExitableAmount(bytes32 _streamId,bytes32 _raftId,address _investor) external returns(uint256);

    function getInvestor(bytes32 _raftId, address _investor) external returns(uint256,Investor memory);

    function getInvestors(bytes32 _raftId) external view returns (Investor[] memory);

    function addStream(
        string memory _name,
        uint256 _capacity,
        uint256[] memory _raftsInStream,
        uint256 _reserveRatio,
        uint256 _firstWithdrawRate
    ) external returns (bytes32);

    // User(Investor)
    function joinStream(
        bytes32 _streamId,
        bytes32 _raftIndex,
        uint256 _amount
    ) external returns (bool);

    function exitStream(
        bytes32 _streamId,
        bytes32 _raftId,
        uint256 _amount
    ) external;

    function transferInvestment(
        bytes32 _raftId,
        address _toInvestor,
        uint256 _amount
    ) external;

    function withdrawProfit(bytes32 _raftId, uint256 _amount) external;

    // by organizer
    function withdraw(bytes32 _streamId, uint256 _amount) external;

    function returnProfit(
        bytes32 _streamId,
        uint256 _profit,
        uint256 _startAt
    ) external returns (uint256);
}

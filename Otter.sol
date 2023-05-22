// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "./IOtter.sol";
import "./OtterManager.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

/**
    @dev Otter合约
 */
contract Otter is IOtter, OtterManager {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeMathUpgradeable for uint256;

    uint256 public constant TIMELOCK_DAY = 30 minutes;

    /// MAX_RAFTS代表一个Stream允许的最大Raft数量
    uint256 public constant MAX_RAFTS = 10;

    /// _nonce 递增，用于计算位移StreamId
    CountersUpgradeable.Counter private _nonce;

    /// _streams 存储当前的Stream列表
    mapping(bytes32 => Stream) private _streams;
    /// _rafts 存储当前所有的Raft
    /// raft id = keccak256(abi.encodePacked(_streamId, _raftIndex))
    mapping(bytes32 => Raft) private _rafts;
    // _investors 记录当前raft下所有的投资者
    mapping(bytes32 => Investor[]) private _investors;
    // _investorsIndexes 记录当前raft下所有的投资者对应的索引
    mapping(bytes32 => mapping(address => uint256)) private _investorsIndexes;

    // _streamTerms 记录Stream的返还收益的周期
    mapping(bytes32 => Term[]) private _streamTerms;

    // _profits RAFT所有的收益记录
    mapping(bytes32 => RaftProfit[]) private _profits;
    // _profitsMapper 记录 (raftId => (term => index))
    mapping(bytes32 => mapping(uint256 => uint256)) private _profitsMapper;

    Transfer[] private _transfers;
    Exit[] private _exits;

    /// USDC合约(ERC20 Compatiable)
    IERC20Upgradeable private _usdc;

    /// @dev 用于Otter合约的初始化
    /// @param _usdcContract USDC合约地址
    function initialize(address _usdcContract) public initializer {
        __OtterManagerInit();
        _usdc = IERC20Upgradeable(_usdcContract);
    }

    event AddStream(
        string name,
        bytes32 streamId,
        address organizer,
        uint256 capacity,
        bytes32[] raftIds,
        uint256[] rafts
    );

    function getTimelock() public pure override returns (uint256) {
        return TIMELOCK_DAY;
    }

    /// @dev 添加一个新的Stream
    /// @param _name stream名称
    /// @param _capacity stream总量
    /// @param _raftsInStream stream中的raft数量和各自的份额
    /// @param _reserveRate 收益留存率
    /// @param _firstWithdrawRate 首次提取留存率
    /// @return steamId stream的唯一id
    function addStream(
        string memory _name,
        uint256 _capacity,
        uint256[] memory _raftsInStream,
        uint256 _reserveRate,
        uint256 _firstWithdrawRate
    ) public override returns (bytes32) {
        address _organizer = msg.sender;

        bytes32 streamId = _beforeAddStream(
            _organizer,
            _capacity,
            _raftsInStream,
            _reserveRate,
            _firstWithdrawRate
        );

        bytes32[] memory raftIds = _addStream(streamId, _capacity, _raftsInStream);

        _afterAddStream(
            _name,
            streamId,
            _organizer,
            _capacity,
            _raftsInStream.length,
            _reserveRate,
            _firstWithdrawRate
        );

        emit AddStream(_name, streamId, _organizer, _capacity, raftIds, _raftsInStream);

        return streamId;
    }

    function _beforeAddStream(
        address _organizer,
        uint256 _capacity,
        uint256[] memory _raftsInStream,
        uint256 _reserveRate,
        uint256 _firstWithdrawRate
    ) internal returns (bytes32) {
        require(_capacity > 0, "capacity must > 0");
        require(_raftsInStream.length > 0, "raftcount must > 0");
        require(_raftsInStream.length <= MAX_RAFTS, "excceedes MAX_RAFTS(10)");

        require(_reserveRate < MAX_RATE, "invalid reserve ratio");
        require(_firstWithdrawRate < MAX_RATE, "invalid first ratio");

        return _nextStreamId(_organizer);
    }

    function _addStream(
        bytes32 _streamId,
        uint256 _capacity,
        uint256[] memory _raftsInStream
    ) internal returns (bytes32[] memory) {
        uint256 total;
        bytes32[] memory raftIds = new bytes32[](_raftsInStream.length);
        for (uint256 i = 0; i < _raftsInStream.length; i++) {
            Raft memory raft;
            raft.stream = _streamId;
            raft.capacity = _raftsInStream[i];

            if (i == 0) {
                raft.status = RaftStatus.Joinable;
            } else {
                raft.status = RaftStatus.Unopen;
            }

            bytes32 _raftId = _calculateRaftId(_streamId, i);
            _rafts[_raftId] = raft;
            raftIds[i] = _raftId;

            total = total + _raftsInStream[i];
        }
        require(total == _capacity, "stream's capacity mistmatch with the sum(rafts)");
        return raftIds;
    }

    function _afterAddStream(
        string memory _name,
        bytes32 _streamId,
        address _organizer,
        uint256 _capacity,
        uint256 _raftCount,
        uint256 _reserveRate,
        uint256 _firstWithdrawRate
    ) internal {
        Stream memory stream;
        stream.name = keccak256(bytes(_name));
        stream.capacity = _capacity;
        stream.organizer = _organizer;
        stream.status = StreamStatus.Joinable;

        stream.earningRafts = 0;
        stream.currentJoinableRaft = 0;
        stream.totalRafts = _raftCount;

        stream.reserveRate = _reserveRate;
        stream.firstWithdrawRate = _firstWithdrawRate;

        _streams[_streamId] = stream;
    }

    function _getRaft(bytes32 _streamId, uint256 _raftIndex) internal view returns (Raft memory) {
        return _rafts[_calculateRaftId(_streamId, _raftIndex)];
    }

    function _getRaft(bytes32 _raftId) internal view returns (Raft memory) {
        return _rafts[_raftId];
    }

    function _calculateRaftId(bytes32 _streamId, uint256 _raftIndex)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_streamId, _raftIndex));
    }

    function getInvestor(bytes32 _raftId, address _investor)
        public
        override
        returns (uint256, Investor memory)
    {
        (uint256 index, Investor memory investor) = _getInvestor(_raftId, _investor);
        return (index, investor);
    }

    function _getInvestor(bytes32 _raftId, address _investor)
        internal
        returns (uint256, Investor storage)
    {
        Investor[] memory raftInvestors = _investors[_raftId];
        uint256 index = _investorsIndexes[_raftId][_investor];
        /*if (raftInvestors.length != 0 && _investors[_raftId][index].account != address(_investor)) {
            index = _newInvestor(_raftId, _investor);
        }

        if (raftInvestors.length == 0) {
            index = _newInvestor(_raftId, _investor);
        }*/
        if (raftInvestors.length == 0 || _investors[_raftId][index].account != _investor) {
            index = _newInvestor(_raftId, _investor);
        }

        return (index, _investors[_raftId][index]);
    }

    function _newInvestor(bytes32 _raftId, address _investor) internal returns (uint256) {
        Investor memory newInvestor;
        newInvestor.account = _investor;
        _investorsIndexes[_raftId][_investor] = _investors[_raftId].length;
        _investors[_raftId].push(newInvestor);
        return _investors[_raftId].length - 1;
    }

    function clear(bytes32 _streamId, bytes32 _raftId) public {
        _clearing(_streamId, _raftId, msg.sender);
    }

    event Clearing(bytes32 stream, bytes32 raftId, address investor, uint256 earning);

    // 清算期间，没有transfer/exit(每次transfer/exit都直接清算)
    // 只需要再扣除一个准入的收益差额
    function _clearing(
        bytes32 _streamId,
        bytes32 _raftId,
        address _investor
    ) internal {
        (, Investor storage investor) = _getInvestor(_raftId, _investor);

        uint256 currCalTerm = investor.lastCalTerm;
        uint256 lastCalTime = investor.lastCalTime;

        uint256 earning;
        uint256 _days;
        (Term memory lastTerm, ) = _getLastTerm(_streamId);

        for (; currCalTerm <= lastTerm.index; currCalTerm++) {
            Term memory term = _streamTerms[_streamId][currCalTerm];
            // 1. 计算当前时间相对周期开始时间，已经过了多久
            // 1.1 如果是最后一个结算周期,则计算当前时间和周期的开始时间差值,获得 elapsed days
            if (term.index == lastTerm.index) {
                _days = (block.timestamp - lastCalTime) / TIMELOCK_DAY;
                lastCalTime = block.timestamp;
            } else {
                // 1.2 如果不是最后一个计算周期,则通过周期结束时间和上一次结算的时间，获得elapsed days
                _days = (term.endAt - lastCalTime) / TIMELOCK_DAY;
                lastCalTime = term.endAt;
            }
            // 1.3 周期中的days最大不超过RELEASE_PERIOD(30days)
            if (_days > RELEASE_PERIOD) {
                _days = RELEASE_PERIOD;
            }

            // 2. 计算差额(直接转给otter)
            uint256 realContribution = investor.contribution;
            uint256 margin;
            for (uint256 indexIn = 0; indexIn < investor.transferIns.length; indexIn++) {
                Transfer memory tin = _transfers[investor.transferIns[indexIn]];
                // 每次transfer在当前周期前发生，需要计算差额
                if (tin.term > currCalTerm) {
                    continue;
                }
                // 如果是当前周期转出，则不应该放在本周期的收益计算中
                if (tin.term == currCalTerm) {
                    realContribution -= tin.amount;
                    continue;
                }

                // 计算差额:  trasfer时的每股收益 * 转移数量 * 损失时间
                margin = margin + _days * tin.profitPerShare * tin.amount;
            }

            if (margin > 0) {
                _transferTo(otterManager(), margin);
            }

            // 3. 计算investor此次结算时，在此周期的收益
            RaftProfit storage _profit = _getRaftProfit(currCalTerm, _raftId);
            uint256 totalContribution = _rafts[_raftId].contribution;

            uint256 thisProfit = (realContribution * _profit.amount * _days) /
                totalContribution /
                RELEASE_PERIOD;

            // 4. 扣除差额
            earning = earning + thisProfit - margin;
        }

        emit Clearing(_streamId, _raftId, _investor, earning);
        investor.lastCalTerm = lastTerm.index;
        investor.lastCalTime = block.timestamp;
        investor.totalEarned = investor.totalEarned + earning;
        investor.undrawnEarnings = investor.undrawnEarnings + earning;
    }


    event JoinStream(bytes32 streamId, bytes32 raftId, address investor, uint256 amount);
    event RaftEarning(bytes32 streamId, bytes32 raftId, uint256 raftIndex);

    /// @dev 用户发起对Stream下某个raft的投资
    /// @param _streamId stream对应的id
    /// @param _raftId  要投资的raft id
    /// @param _amount 要投资的USDC数量
    /// @return bool 是否投资成功
    function joinStream(
        bytes32 _streamId,
        bytes32 _raftId,
        uint256 _amount
    ) public override returns (bool) {
        address investor = msg.sender;

        _transferToOtterContract(_amount);

        Stream storage stream = _streams[_streamId];
        require(stream.organizer != address(0), "stream not exist");

        (
            RaftStatus status,
            uint256 currentContribution,
        ) = _joinOnRaft(_streamId, _raftId, investor, _amount);

        // increase stream's total contriution if Raft is Earning
        if (status == RaftStatus.Earning) {
            stream.undrawnContribution = stream.undrawnContribution + currentContribution;
            stream.contribution = stream.contribution + currentContribution;
            stream.earningRafts = stream.earningRafts + 1;
            emit RaftEarning(_streamId, _raftId, stream.currentJoinableRaft);
        }

        // set next raft to `Joinable`
        if (status == RaftStatus.Earning && stream.totalRafts > stream.currentJoinableRaft + 1) {
            stream.currentJoinableRaft++;
            bytes32 currentRaftId = _calculateRaftId(_streamId, stream.currentJoinableRaft);
            Raft storage raft = _rafts[currentRaftId];
            raft.status = RaftStatus.Joinable;
        }

        // when any raft is Earning,stream will be at Earning status
        if (status == RaftStatus.Earning && stream.status == StreamStatus.Joinable) {
            stream.status = StreamStatus.Earning;
            stream.firstEarningDate = block.timestamp;
        }

        emit JoinStream(_streamId, _raftId, investor, _amount);

        return true;
    }

    function _joinOnRaft(
        bytes32 _streamId,
        bytes32 _raftId,
        address _investor,
        uint256 _amount
    )
        internal
        returns (
            RaftStatus,
            uint256,
            uint256
        )
    {
        Raft storage raft = _rafts[_raftId];
        require(raft.stream == _streamId, "raft not in this stream");
        require(raft.status == RaftStatus.Joinable, "raft not joinable");

        uint256 available = raft.capacity - raft.contribution;
        require(available >= _amount, "exceedes the raft capacity");

        raft.contribution = raft.contribution + _amount;

        if (raft.contribution == raft.capacity) {
            raft.status = RaftStatus.Earning;
        }

        (, Investor storage investor) = _getInvestor(_raftId, _investor);
        investor.contribution = investor.contribution + _amount;

        return (raft.status, raft.contribution, investor.contribution);
    }

    function getExitableAmount(
        bytes32 _streamId,
        bytes32 _raftId,
        address _investor
    ) public override returns (uint256) {
        Stream memory stream = _streams[_streamId];
        (, Investor memory investor) = _getInvestor(_raftId, _investor);
        return (investor.contribution * stream.reserve) / stream.capacity;
    }

    event ExitStream(bytes32 streamId, bytes32 raftId, address investor, uint256 amount);

    /// @dev 用户退出部分RAFT投资
    /// @param _streamId Stream的ID
    /// @param _raftId raft的ID
    /// @param _amount 退出的份额数量
    function exitStream(
        bytes32 _streamId,
        bytes32 _raftId,
        uint256 _amount
    ) public override {
        (, Investor storage investor) = _getInvestor(_raftId, msg.sender);
        require(
            investor.contribution >= _amount,
            "withdraw amount cannot exceedes investor's conribution"
        );

        Raft memory raft = _rafts[_raftId];
        require(raft.stream == _streamId, "raft and stream mismatch");
        require(raft.status == RaftStatus.Earning, "raft not earning yet");

        Stream storage stream = _streams[_streamId];

        // 可退出额度计算
        require(
            (investor.contribution * stream.reserve) / stream.capacity >= _amount,
            "withdrawable amount not enough"
        );

        // 清算之前的收益
        _clearing(_streamId, _raftId, msg.sender);

        // 记录退出，并计算未到账收益应转给平台部分
        _clearExit(_raftId, _amount);

        // 更新
        stream.contribution = stream.contribution - _amount;
        raft.contribution = raft.contribution - _amount;
        stream.reserve = stream.reserve - _amount;
        investor.contribution = investor.contribution - _amount;

        // 提取到investor地址
        _transferTo(msg.sender, _amount);

        emit ExitStream(_streamId, _raftId, msg.sender, _amount);
    }

    function _clearExit(bytes32 _raftId, uint256 _exitAmount) internal {
        Raft memory raft = _getRaft(_raftId);
        (, Investor storage investor) = _getInvestor(_raftId, msg.sender);

        Exit memory exit;
        exit.investor = msg.sender;
        exit.stream = raft.stream;
        exit.raft = _raftId;
        exit.exitAt = block.timestamp;
        exit.amount = _exitAmount;

        (Term memory lastTerm, ) = _getLastTerm(raft.stream);
        exit.term = lastTerm.index;

        // 如果是在收益周期内，则需要处理给manager的损失
        if (block.timestamp < lastTerm.endAt && block.timestamp >= lastTerm.startAt) {
            uint256 lostDays = (lastTerm.endAt - block.timestamp + TIMELOCK_DAY) / TIMELOCK_DAY;
            if(lostDays > RELEASE_PERIOD){
                lostDays = RELEASE_PERIOD;
            }
            
            uint256 pi = _profitsMapper[_raftId][lastTerm.index];
            RaftProfit memory profit = _profits[_raftId][pi];

            // (损失占比)*退出前日收益*未到账收益天数
            uint256 toOtterAmount = (_exitAmount * profit.amount * lostDays) /
                raft.contribution /
                RELEASE_PERIOD;

            _transferTo(otterManager(), toOtterAmount);
        }

        _exits.push(exit);
        investor.exits.push(_exits.length - 1);
    }

    // User(Investor)
    event TransferInvestment(
        bytes32 streamId,
        bytes32 raftId,
        uint256 term,
        address from,
        address to,
        uint256 amount
    );

    /// @dev 用户转让其下Raft部分份额到其他用户
    /// @param _raftId RAFT的ID
    /// @param _toInvestor 转入用户地址
    /// @param _amount 转让的份额数量
    function transferInvestment(
        bytes32 _raftId,
        address _toInvestor,
        uint256 _amount
    ) public override {
        require(_toInvestor != address(0), "zero investor address");
        require(_amount > 0, "can not be zero amount");
        (, Investor storage fromInvestor) = _getInvestor(_raftId, msg.sender);
        require(fromInvestor.contribution >= _amount, "contribution not enough");

        (, Investor storage toInvestor) = _getInvestor(_raftId, _toInvestor);

        Raft memory raft = _rafts[_raftId];
        (Term memory lastTerm, ) = _getLastTerm(raft.stream);

        // 清算fromInvestor的收益
        _clearing(raft.stream, _raftId, msg.sender);
        // 清算toVestor的收益
        _clearing(raft.stream, _raftId, _toInvestor);

        // 存储Transfer信息
        Transfer memory trans;
        trans.from = msg.sender;
        trans.to = _toInvestor;
        trans.term = lastTerm.index;
        trans.stream = raft.stream;
        trans.raft = _raftId;
        trans.amount = _amount;
        trans.transferedAt = block.timestamp;
        trans.profitPerShare = raft.profitPerShare;

        // 如果是在收益周期内，则需要处理给manager的损失
        if (block.timestamp < lastTerm.endAt && block.timestamp >= lastTerm.startAt) {
            uint256 lostDays = (lastTerm.endAt - block.timestamp + TIMELOCK_DAY) / TIMELOCK_DAY;
            if(lostDays > RELEASE_PERIOD){
                lostDays = RELEASE_PERIOD;
            }

            uint256 pi = _profitsMapper[_raftId][lastTerm.index];
            RaftProfit memory profit = _profits[_raftId][pi];

            // (损失占比)*退出前日收益*未到账收益天数
            uint256 toOtterAmount = (_amount * profit.amount * lostDays) /
                raft.contribution /
                RELEASE_PERIOD;
            _transferTo(otterManager(), toOtterAmount);
        }

        // 更新
        _transfers.push(trans);
        fromInvestor.transferOuts.push(_transfers.length - 1);
        fromInvestor.contribution = fromInvestor.contribution - _amount;
        toInvestor.transferIns.push(_transfers.length - 1);
        toInvestor.contribution = toInvestor.contribution + _amount;

        emit TransferInvestment(
            raft.stream,
            _raftId,
            lastTerm.index,
            msg.sender,
            _toInvestor,
            _amount
        );
    }

    event WithdrawnProfit(
        bytes32 raftId,
        address investor,
        uint256 amount,
        uint256 undrawnEarnings
    );

    /// @dev 用户提取部分收益
    /// @param _raftId RAFT的ID
    /// @param _amount 提取的收益数量
    function withdrawProfit(bytes32 _raftId, uint256 _amount) public override {
        Raft memory raft = _rafts[_raftId];
        require(raft.status == RaftStatus.Earning, "raft not earning");

        _clearing(raft.stream, _raftId, msg.sender);

        (uint256 index, Investor memory investor) = _getInvestor(_raftId, msg.sender);

        // withdraw USDCs
        require(investor.undrawnEarnings >= _amount, "do not have enough undrawn earnings");

        uint256 fee = caculateWithdrawFee(OTTER_USER, _amount);

        _transferTo(msg.sender, _amount - fee);
        _transferTo(otterManager(), fee);

        investor.undrawnEarnings = investor.undrawnEarnings - _amount;

        _investors[_raftId][index] = investor;

        emit WithdrawnProfit(_raftId, msg.sender, _amount, investor.undrawnEarnings);
    }

    event Withdraw(bytes32 steamId, uint256 amount, uint256 fee, uint256 reserved);

    /// @dev Stream组织者提取用户贡献的USDC资金
    /// @param _streamId 要提取的Stream id
    /// @param _amount 提取的资金数量
    function withdraw(bytes32 _streamId, uint256 _amount) public override {
        Stream storage stream = _streams[_streamId];
        require(stream.organizer == msg.sender, "only stream's organizer can withdraw");
        require(stream.undrawnContribution >= _amount, "undrawnContribution not enough");

        uint256 fee = caculateWithdrawFee(OTTER_ORGANIZER, _amount);

        uint256 reserve;
        // keep some usdc as reserved at the first time
        if (!stream.withdrawed) {
            reserve = (_amount * stream.firstWithdrawRate) / MAX_RATE;
            stream.withdrawed = true;
        }

        // transfer usdc to organizer
        require(_transferTo(msg.sender, _amount - fee - reserve), "transfer usdc to organizer");

        // transfer fee to otter manager
        require(_transferTo(otterManager(), fee), "transfer fee to otter manager");

        stream.reserve = stream.reserve + reserve;
        stream.undrawnContribution = stream.undrawnContribution - _amount;

        emit Withdraw(_streamId, _amount, fee, reserve);
    }

    // Organizer refund profit to investors
    // 每次返回收益时，清算上一次收益
    event ReturnProfit(
        bytes32 streamId,
        uint256 term,
        uint256 profit,
        uint256 startAt,
        uint256 endAt
    );

    /// @dev Stream组织者返还收益
    /// @param _streamId 要提取的Stream id
    /// @param _profit 返还的USDC数量
    /// @param _startAt 返利开始时间
    /// @return uint256 stream下返还利润周期的index
    function returnProfit(
        bytes32 _streamId,
        uint256 _profit,
        uint256 _startAt
    ) public override returns (uint256) {
        require(_profit > 0, "zero profit not allowed");
        Stream storage stream = _streams[_streamId];
        require(stream.organizer == msg.sender, "only stream's organizer can return profit");
        require(stream.withdrawed, "can't return profit before first time withdraw contribution");

        // make sure current term finished
        (Term memory lastTerm, uint256 length) = _getLastTerm(_streamId);
        // last term mut finished
        require(
            length == 0 || lastTerm.endAt < block.timestamp,
            "curren stream term not finished yet"
        );

        _transferToOtterContract(_profit);

        // calculate reserved profit
        uint256 reserved = (_profit * stream.reserveRate) / MAX_RATE;
        if (stream.reserve + reserved > stream.contribution) {
            reserved = stream.contribution - stream.reserve;
        }

        // save reserved USDC
        stream.reserve = stream.reserve + reserved;

        // save total USDC
        stream.cumulativeProfit = stream.cumulativeProfit + _profit;

        Term memory term;
        term.index = stream.term++;
        term.earningRafts = stream.earningRafts;
        term.profit = _profit - reserved;

        term.startAt = _startAt;
        term.endAt = _startAt + RELEASE_PERIOD * TIMELOCK_DAY;

        _streamTerms[_streamId].push(term);

        _returnProfitToRafts(_streamId, term);
        emit ReturnProfit(_streamId, term.index, _profit, term.startAt, term.endAt);

        return term.index;
    }

    function _returnProfitToRafts(bytes32 streamId, Term memory term) internal {
        uint256 profitPerRaft = term.profit / term.earningRafts;
        uint256 accuracyLoss = term.profit - profitPerRaft * term.earningRafts;
        uint256 earningRaftsTolCap = 0;
        for (uint256 index = 0; index < term.earningRafts; index++) {
            bytes32 _raftId = _calculateRaftId(streamId, index);
            Raft storage raft = _rafts[_raftId];
            require(raft.status == RaftStatus.Earning, "raft is not earning");

            if (index + 1 == term.earningRafts) {
                profitPerRaft = profitPerRaft + accuracyLoss;
            }

            // update raft
            raft.totalProfit = raft.totalProfit + profitPerRaft;
            raft.profitPerShare = raft.profitPerShare + profitPerRaft / raft.capacity;

            // save raft profit share
            RaftProfit memory profit;
            profit.term = term.index;
            profit.amount = profitPerRaft;
            _profits[_raftId].push(profit);
            _profitsMapper[_raftId][term.index] = _profits[_raftId].length - 1;

            earningRaftsTolCap = earningRaftsTolCap + raft.capacity;
        }
        term.earnRaftsCapacity = term.profit / earningRaftsTolCap;
    }

    function _getRaftProfit(uint256 term, bytes32 _raftId)
        internal
        view
        returns (RaftProfit storage)
    {
        uint256 index = _profitsMapper[_raftId][term];
        return _profits[_raftId][index];
    }

    /// @dev 转移USDC到当前Otter合约
    /// @param _amount 转账数量
    function _transferToOtterContract(uint256 _amount) internal {
        require(_usdc.transferFrom(msg.sender, address(this), _amount), "Do no have enough USDC");
    }

    /// @dev 从otter合约转移USDC到某个账户地址
    /// @param _account 账户地址
    /// @param _amount 转移数量
    /// @return bool 返回校验结果
    function _transferTo(address _account, uint256 _amount) internal returns (bool) {
        return _usdc.transfer(_account, _amount);
    }

    /// @dev 计算下一个StreamId
    /// @param _organizer stream的组织者地址
    /// @return bytes32 streamId
    function _nextStreamId(address _organizer) internal returns (bytes32) {
        _nonce.increment();
        return keccak256(abi.encodePacked(_organizer, _nonce.current()));
    }

    /// @dev 通过stream id查看Stream
    /// @param _streamId stream对应的id
    /// @return Stream stream详细信息
    function getStream(bytes32 _streamId) public view override returns (Stream memory) {
        Stream memory stream = _streams[_streamId];
        require(stream.organizer != address(0), "stream not found");
        return stream;
    }

    /// @dev 通过stream id查看Stream下所有的收益返还周期
    /// @param _streamId stream对应的id
    /// @return Term[] 收益返还周期列表
    function getTerms(bytes32 _streamId) public view override returns (Term[] memory) {
        return _streamTerms[_streamId];
    }

    /// @dev 查看某stream下所有的raft
    /// @return Raft[] raft列表
    function getRafts(bytes32 _streamId) public view override returns (Raft[] memory) {
        Stream memory stream = getStream(_streamId);
        Raft[] memory rafts = new Raft[](stream.totalRafts);
        for (uint256 index = 0; index < stream.totalRafts; index++) {
            bytes32 raftId = _calculateRaftId(_streamId, index);
            Raft memory raft = _rafts[raftId];
            raft.raftId = raftId;
            rafts[index] = raft;
        }
        return rafts;
    }

    /// @dev 查询当前所有的transfer
    /// @return Transfer[] transfer列表
    function getTransfers() public view override returns (Transfer[] memory) {
        return _transfers;
    }

    /// @dev 查询某RAFT下investor列表
    /// @param _raftId raft id
    /// @return Investor[]  返回investor列表
    function getInvestors(bytes32 _raftId) public view override returns (Investor[] memory) {
        return _investors[_raftId];
    }

    function _getTerm(bytes32 _streamId, uint256 index) internal view returns (Term memory) {
        Term[] memory terms = _streamTerms[_streamId];
        Term memory term;
        if (terms.length == 0) {
            return term;
        }
        return terms[index];
    }

    function _getLastTerm(bytes32 _streamId) internal view returns (Term memory, uint256) {
        Term[] memory terms = _streamTerms[_streamId];
        Term memory term;
        if (terms.length == 0) {
            return (term, 0);
        }
        return (terms[terms.length - 1], terms.length);
    }

    function getRaftProfit(bytes32 _raftId, uint256 index) public view returns (RaftProfit memory) {
        return _profits[_raftId][index];
    }
}

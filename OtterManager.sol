// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "./IOtterManager.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
    @dev Otter配置参数管理合约
 */
contract OtterManager is
    Initializable,
    OwnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    IOtterManager
{
    ///  Otter管理员角色
    bytes32 public constant OTTER_MANAGER = keccak256("OTTER_MANAGER");
    ///  Stream组建者角色
    bytes32 public constant OTTER_ORGANIZER = keccak256("OTTER_ORGANIZER");
    /// Otter普通用户(投资者)
    bytes32 public constant OTTER_USER = keccak256("OTTER_USER");

    /// 精度(小数点后两位)
    // 10000
    // 9999 / 100  = 99.99
    uint256 public constant MAX_RATE = 10000; // 2442/100 = 24.22%

    /// 收益释放周期(30天)
    uint256 public constant RELEASE_PERIOD = 30; // 30days

    /// 用户提取USDC的费率，按角色划分
    mapping(bytes32 => uint256) private _withdrawRates;

    function __OtterManagerInit() internal onlyInitializing {
        __Ownable_init();
        __AccessControl_init();

        _setRoleAdmin(OTTER_MANAGER, OTTER_MANAGER);
        _setRoleAdmin(OTTER_ORGANIZER, OTTER_MANAGER);

        _setupRole(OTTER_MANAGER, owner());
    }

    /// @dev 查看otter管理员用户
    /// @return address 管理员用户地址
    function otterManager() public view override returns (address) {
        return owner();
    }

    event SetWithdrawRate(bytes32 role, uint256 oldRate, uint256 newRate);

    /// @dev 设置收益提取费率(仅允许Otter管理员)
    /// @param _role 角色类型
    /// @param _newRate 角色对应的提取费率
    function setWithdrawRate(bytes32 _role, uint256 _newRate)
        public
        override
        onlyRole(OTTER_MANAGER)
    {
        require(1000<=_newRate && _newRate<= 9000,"excceedes max rate");
        emit SetWithdrawRate(_role, _withdrawRates[_role], _newRate);
        _withdrawRates[_role] = _newRate;
    }

    /// @dev 查询角色对应的提取费率
    /// @param _role 角色类型
    /// @return uint256 收取的费用
    function getWithdrawRate(bytes32 _role) public view override returns (uint256) {
        return _withdrawRates[_role];
    }

    /// @dev 计算提取一定收益的费率
    /// @param _role 角色类型
    /// @param _total 需提取的收益总量
    /// @return uint256 收取的费用
    function caculateWithdrawFee(bytes32 _role, uint256 _total) public view returns (uint256) {
        uint256 rate = getWithdrawRate(_role);
        return (_total * rate) / MAX_RATE;
    }
}

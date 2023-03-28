// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

interface IOtterManager {
    function otterManager() external view returns (address);

    function setWithdrawRate(bytes32 _role, uint256 _newRate) external;

    function getWithdrawRate(bytes32 _role) external view returns (uint256);
}

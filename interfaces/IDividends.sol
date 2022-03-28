pragma solidity ^0.8.0;


interface IDividends {
  function setUserStakedAmount(uint256 _pid, address _userAddress, uint256 _totalShares) external;
  function calculateUnclaimedDividends(address _userAddress) external view returns (uint256);
  function collectDividends() external;
  function updateOperator(address _operator, bool _status) external;
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

*/
contract Dividends is ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  struct UserState {
    bool tracked;

    uint256 paidDividends;
    uint256 unpaidDividends;
  }

  struct PoolState {
    bool tracked;
    uint256 lastUpdatedAt;
    uint256 totalShares;
  }

  struct PeriodState {
    bool prepared;
    uint256 totalAllocationPoints;
    uint256 accumulatedDividends;
    uint256 dividendsPerSecond;
    uint256 totalDividends;
  }

  struct PoolPeriodState {
    uint256 allocationPoints;
    uint256 accumulatedDividendsPerShare;
  }

  struct UserPoolState {
    uint256 shares;
    uint256 rewardDebt;
    uint256 lastUpdatedAt;
  }

  // Length of dividends period
  uint256 public constant periodDurationSeconds = 1 weeks;
  
  uint256 public constant firstPeriodStartSeconds = 1648309240;

  IERC20 public dividendToken;

  mapping(uint256 => PeriodState) public periods;

  uint256[] public poolIds;
  mapping(uint256 => PoolState) public pools;
  
  address[] public userIds;
  mapping(address => UserState) public users;
  
  mapping(uint256 => mapping(uint256 => PoolPeriodState)) public poolPeriods;
  mapping(uint256 => mapping(address => UserPoolState)) public poolUsers;

  mapping(uint256 => uint256) public poolAllocation;

  mapping(address => bool) public operators;


  event OperatorUpdated(address indexed operator, bool indexed status);


  modifier onlyOperator() {
      require(operators[msg.sender], "CornFi Dividends: Caller is not an operator");
      _;
  }

  // ---------------------------------------------------------------------------------
  // ---------------------------------------------------------------------------------
  
  constructor(address _dividendToken) {
      // Set ERC20 token to pay out as dividend 
      dividendToken = IERC20(_dividendToken);

      // Set caller as an operator
      operators[msg.sender] = true;
  }

  // ---------------------------------------------------------------------------------

  function firstSecond(uint256 _period) public view returns (uint256) {
    return (_period * periodDurationSeconds) + firstPeriodStartSeconds;
  }

  // ---------------------------------------------------------------------------------

  function lastSecond(uint256 _period) public view returns (uint256) {
    return firstSecond(_period + 1);
  }

  // ---------------------------------------------------------------------------------

  function fromSeconds(uint256 _seconds) public view returns (uint256) {
    _seconds = _seconds - firstPeriodStartSeconds;
    return _seconds > periodDurationSeconds ? 
      _seconds / periodDurationSeconds : 0;
  }
  
  // ---------------------------------------------------------------------------------

  function currentPeriod() public view returns (uint256) {
    return fromSeconds(block.timestamp);
  }

  // ---------------------------------------------------------------------------------

  function poolCount() external view returns (uint256) {
    return poolIds.length;
  }

  // ---------------------------------------------------------------------------------

  function userCount() external view returns (uint256) {
    return userIds.length;
  }

  // ---------------------------------------------------------------------------------

  function calculatePeriodMultiplier(
    uint256 _period, 
    uint256 _pid, 
    uint256 _from, 
    uint256 _to
  ) public view returns (uint256) {
      require(_from <= _to, "CornFi Dividends: _from > _to");
      if(!pools[_pid].tracked) {
        return 0;
      }

      PeriodState storage period = periods[_period];
      if(period.accumulatedDividends >= period.totalDividends) {
        return 0;
      }

      uint256 periodFirstSecond = firstSecond(_period);
      uint256 periodLastSecond = lastSecond(_period);
      _from = clamp(_from, periodFirstSecond, periodLastSecond);
      _to = clamp(_to, periodFirstSecond, periodLastSecond);

      return _to.sub(_from);
  }

  // ---------------------------------------------------------------------------------

  function calculatePoolUserPendingDividends(
    uint256 _pid, 
    address _userAddress, 
    uint256 _maxPeriod
  ) public view returns (uint256) {
      uint256 rawDividends = _calculateRawUserReward(_pid, _userAddress, _maxPeriod);
      uint256 rewardDebt = poolUsers[_pid][_userAddress].rewardDebt;
      return rawDividends.sub(rewardDebt);
  }

  // ---------------------------------------------------------------------------------  

  function calculateUnclaimedDividends(
    address _userAddress
  ) public view returns (uint256) {
    // Get total unpaid dividends from last update
    uint256 totalUnpaid = users[_userAddress].unpaidDividends.sub(
      users[_userAddress].paidDividends
    );
    
    // Loop through all the pools and get unpaid dividends since last update
    for(uint256 i = 0; i < poolIds.length; i++) {
      uint256 _pid = poolIds[i];

      // Get unpaid dividends for current pool and period
      uint256 owed = calculatePoolUserPendingDividends(
        _pid, 
        _userAddress, 
        currentPeriod()
      );

      // Add to total unpaid dividends
      totalUnpaid = totalUnpaid.add(owed);
    }

    return totalUnpaid;
  }
  
  // ---------------------------------------------------------------------------------
  // --------------------------- State Changing Functions ----------------------------
  // ---------------------------------------------------------------------------------

  function collectDividends() external nonReentrant {
    // Loop through all pools
    for(uint256 i = 0; i < poolIds.length; i++) {
      uint256 _pid = poolIds[i];

      // Update the pool
      _updatePool(_pid);

      // Update user data
      _updateUser(_pid, msg.sender, currentPeriod());

      // Calculate users reward
      poolUsers[_pid][msg.sender].rewardDebt = _calculateRawUserReward(
        _pid, 
        msg.sender, 
        currentPeriod()
      );
    }

    // Calculate unpaid dividends
    uint256 totalUnpaid = users[msg.sender].unpaidDividends.sub(
      users[msg.sender].paidDividends
    );

    users[msg.sender].paidDividends = users[msg.sender].unpaidDividends;

    require(totalUnpaid > 0, "CornFi Dividends: Nothing to Claim");

    // Transfer dividend token to user
    dividendToken.safeTransfer(msg.sender, totalUnpaid);
  }

  // ---------------------------------------------------------------------------------
  // ----------------------------- Only Owner Functions ------------------------------
  // ---------------------------------------------------------------------------------

  function transferOwnership(address newOwner) public override onlyOwner {
    require(newOwner != address(0), "CornFi Dividends: New owner is the zero address");
    operators[newOwner] = true;
    emit OperatorUpdated(newOwner, true);
    _transferOwnership(newOwner);
  }

  // ---------------------------------------------------------------------------------

  function setUserStakedAmount(
    uint256 _pid, 
    address _userAddress, 
    uint256 _userShares
  ) external nonReentrant onlyOwner {
    
    _updatePool(_pid);
    _updateUser(_pid, _userAddress, currentPeriod());

    UserPoolState storage user = poolUsers[_pid][_userAddress];
    PoolState storage pool = pools[_pid];
    if(user.shares > _userShares) {
      // withdrawal
      pool.totalShares = pool.totalShares.sub(user.shares.sub(_userShares));
    } else {
      // deposit
      pool.totalShares = pool.totalShares.add(_userShares.sub(user.shares));
    }

    user.shares = _userShares;
    user.rewardDebt = _calculateRawUserReward(_pid, _userAddress, currentPeriod());
  }

  // ---------------------------------------------------------------------------------
  // ---------------------------- Only Operator Functions ----------------------------
  // ---------------------------------------------------------------------------------
  
  function updateOperator(address _operator, bool _status) external onlyOperator {
      operators[_operator] = _status;
      
      emit OperatorUpdated(_operator, _status);
  }

  // ---------------------------------------------------------------------------------

  function operatorUpdateUser(
    uint256 _pid, 
    address _userAddress, 
    uint256 _maxPeriod
  ) external onlyOperator {
    
    require(_maxPeriod < currentPeriod(), "CornFi Dividends: _maxPeriod < current period");

    _updateUser(_pid, _userAddress, _maxPeriod);
    poolUsers[_pid][_userAddress].rewardDebt = _calculateRawUserReward(
      _pid, 
      _userAddress, 
      _maxPeriod
    );
  }

  // ---------------------------------------------------------------------------------

  function updatePoolAllocation(uint256 _pid, uint256 _points) external onlyOperator {
    // Untracked pool
    if(!pools[_pid].tracked) {
      // Add pool
      poolIds.push(_pid);
      pools[_pid].lastUpdatedAt = firstSecond(currentPeriod());
      pools[_pid].tracked = true;
    }

    // Set allocation points for pool
    poolAllocation[_pid] = _points;
  }

  // ---------------------------------------------------------------------------------

  function preparePeriod(uint256 _period, uint256 _totalDividends) external onlyOperator {
    // Only unprepared periods
    require(!periods[_period].prepared, "CornFi Dividends: Period Already Prepared");

    // Only the last completed period can be prepared
    require(
      _period == currentPeriod().sub(1), 
      "CornFi Dividends: Period is Not the Last Completed"
    );

    // Transfer total dividends to distribute from the operator to this contract
    dividendToken.safeTransferFrom(msg.sender, address(this), _totalDividends);

    uint256 totalPoints = 0;

    // Loop through all pools receiving dividends
    for(uint256 i = 0; i < poolIds.length; i++) {
      uint256 pid = poolIds[i];

      // Set pool allocation points for the current period
      poolPeriods[pid][_period].allocationPoints = poolAllocation[pid];

      // Calculate total allocation points for all pools
      totalPoints = totalPoints.add(poolPeriods[pid][_period].allocationPoints);
    }

    require(totalPoints > 0, "CornFi Dividends: No Allocation Points Set");

    // Set period information
    periods[_period].prepared = true;
    periods[_period].totalAllocationPoints = totalPoints;
    periods[_period].totalDividends = _totalDividends;
    periods[_period].dividendsPerSecond = _totalDividends.div(periodDurationSeconds);
  }

  // ---------------------------------------------------------------------------------
  // ------------------------------ Internal Functions -------------------------------
  // ---------------------------------------------------------------------------------

  function _calcateUserPoolPeriodDividends(
    uint256 _period, 
    uint256 _pid, 
    address _userAddress
  ) internal view returns (uint256) {
      
      PeriodState storage period = periods[_period];
      PoolState storage pool = pools[_pid];
      PoolPeriodState storage poolPeriod = poolPeriods[_pid][_period];
      UserPoolState storage user = poolUsers[_pid][_userAddress];

      if(!period.prepared || poolPeriod.allocationPoints == 0) {
        return 0;
      }

      // Last second of the period not exceeding the current time
      uint256 periodLastSecond = min(block.timestamp, lastSecond(_period));
      uint256 accDividendPerShare = poolPeriod.accumulatedDividendsPerShare;

      // Pool has shares and is not updated
      if(pool.totalShares > 0 && pool.lastUpdatedAt < periodLastSecond) {
          // Calculate period multiplier
          uint256 multiplier = calculatePeriodMultiplier(
            _period, 
            _pid, 
            pool.lastUpdatedAt, 
            periodLastSecond
          );

          uint256 dividendReward = multiplier.mul(
            period.dividendsPerSecond
          ).mul(poolPeriod.allocationPoints).div(period.totalAllocationPoints);
          
          accDividendPerShare = accDividendPerShare.add(
            dividendReward.mul(1e18).div(pool.totalShares)
          );
      }

      return user.shares.mul(accDividendPerShare).div(1e18);
  }

  // ---------------------------------------------------------------------------------

  function _calculateRawUserReward(
    uint256 _pid, 
    address _userAddress, 
    uint256 _maxPeriod
  ) internal view returns (uint256) {
      UserPoolState storage user = poolUsers[_pid][_userAddress];

      uint256 updatedAt = user.lastUpdatedAt == 0 ? _maxPeriod : fromSeconds(user.lastUpdatedAt);
      
      uint256 total = 0;
      for(uint256 i = updatedAt; i <= _maxPeriod; i++) {
        uint256 _inc = _calcateUserPoolPeriodDividends(i, _pid, _userAddress);

        total = total.add(_inc);
      }

      return total;
  }

  // ---------------------------------------------------------------------------------

  function _updatePoolPeriod(uint256 _period, uint256 _pid) internal returns (bool) {

      PeriodState storage period = periods[_period];

      // Cannot update an unprepared period
      if(!period.prepared) {
        return false;
      }

      PoolState storage pool = pools[_pid];

      // Cannot update an already updated pool
      if (block.timestamp <= pool.lastUpdatedAt) {
        return false;
      }

      // Cannot update a pool with no shares
      if (pool.totalShares == 0) {
        return false;
      }

      uint256 previousLastUpdatedSeconds = max(pool.lastUpdatedAt, firstSecond(_period));

      // Pool is last updated at either the current time or last second of the period, 
      // whichever comes first
      pool.lastUpdatedAt = min(block.timestamp, lastSecond(_period));

      PoolPeriodState storage poolPeriod = poolPeriods[_pid][_period];

      // No need to continue with pools that have no allocation points
      if(poolPeriod.allocationPoints == 0) {
        return true;
      }

      // Update pool period data
      uint256 multiplier = calculatePeriodMultiplier(
        _period, _pid, previousLastUpdatedSeconds, pool.lastUpdatedAt
      );
      uint256 dividendReward = multiplier.mul(
        period.dividendsPerSecond
      ).mul(poolPeriod.allocationPoints).div(period.totalAllocationPoints);

      period.accumulatedDividends = period.accumulatedDividends.add(dividendReward);
      poolPeriod.accumulatedDividendsPerShare = poolPeriod.accumulatedDividendsPerShare.add(
        dividendReward.mul(1e18).div(pool.totalShares)
      );
      
      return true;
  }

  // ---------------------------------------------------------------------------------

  function _updatePool(uint256 _pid) internal {
  
    PoolState storage pool = pools[_pid];

    // Pool is not currently tracked
    if(!pool.tracked) {
      // Add pool
      poolIds.push(_pid);

      // Last updated at the first second of the current period
      pools[_pid].lastUpdatedAt = firstSecond(currentPeriod());

      // Set pool as tracked
      pool.tracked = true;
    }

    // Get last period pool was updated
    uint256 updatedPeriod = fromSeconds(pool.lastUpdatedAt);

    // Get current period
    uint256 currPeriod = currentPeriod();

    // Loop through each period that has not been updated
    for(uint256 i = updatedPeriod; i <= currPeriod; i++) {
      if(!_updatePoolPeriod(i, _pid)) {
        break;
      }
    }
  }

  // ---------------------------------------------------------------------------------

  function _updateUser(uint256 _pid, address _userAddress, uint256 _maxPeriod) internal {
    
    if(!users[_userAddress].tracked) {
      userIds.push(_userAddress);
      users[_userAddress].tracked = true;
    }

    uint256 unpaidDividends = calculatePoolUserPendingDividends(_pid, _userAddress, _maxPeriod);
    UserPoolState storage user = poolUsers[_pid][_userAddress];
    user.lastUpdatedAt = min(block.timestamp, lastSecond(_maxPeriod));
    users[_userAddress].unpaidDividends = users[_userAddress].unpaidDividends.add(unpaidDividends);
  }

  // ---------------------------------------------------------------------------------

  function min(uint256 _a, uint256 _b) internal pure returns (uint256) {
    return _a <= _b ? _a
      : _b;
  }

  // ---------------------------------------------------------------------------------

  function max(uint256 _a, uint256 _b) internal pure returns (uint256) {
    return _a >= _b ? _a
      : _b;
  }

  // ---------------------------------------------------------------------------------

  function clamp(uint256 _a, uint256 _min, uint256 _max) internal pure returns (uint256) {

    // _a is in range
    return _a >= _min && _a <= _max ? _a
      // _a is too small
      : _a < _min ? _min
        // _a is too large
        : _max;
  }

}

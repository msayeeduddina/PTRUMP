// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract PTRUMPStaking is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;
    using SafeMath for uint;

    IERC20 private rewardsToken;
    IERC20 private stakingToken;

    //Uint
    uint private feePerc;
    uint private poolIndex;
    uint[] private poolIndexArray;

    //Address
    address private feeReceiver;

    //Struct
    struct PoolType {
        string poolName;
        uint stakingDuration;
        uint APY;
        uint minimumDeposit;
        uint totalStaked;
        mapping(address => uint256) userStakedBalance;
        mapping(address => bool) hasStaked;
        mapping(address => uint) lastTimeUserStaked;
        address[] stakers;
        bool stakingIsPaused;
        bool poolIsInitialized;
    }

    //Mapping
    mapping(uint => PoolType) public pool;

    //Modifier
    modifier validTokenAddress(address tokenAddress) {
        require(tokenAddress != address(0), "Invalid token address");
        _;
    }

    //Event
    event PoolCreated(uint indexed poolId, string poolName, uint stakingDuration, uint APY, uint minimumDeposit);
    event Staked(address indexed user, uint indexed poolId, uint amount);
    event Unstaked(address indexed user, uint indexed poolId, uint amount);
    event RewardClaimed(address indexed user, uint indexed poolId, uint reward);
    event PoolPaused(uint indexed poolId, bool isPaused);
    event FeeUpdated(uint newFeePercentage);
    event FeeReceiverUpdated(address newFeeReceiver);
    event RewardsTokenUpdated(address newRewardsToken);
    event StakingTokenUpdated(address newStakingToken);
    event MinimumDepositUpdated(uint indexed poolId, uint newMinimumDeposit);
    event APYUpdated(uint indexed poolId, uint newAPY);
    event StakingDurationUpdated(uint indexed poolId, uint newStakingDuration);


    //Constructor
    constructor(address _stakingToken, address _rewardsToken, address _feeReceiver, uint _feePerc) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        feeReceiver = _feeReceiver;
        feePerc = _feePerc;
        poolIndex = 0;
    }

    //Initialize
    function createPool(
        string memory _poolName,
        uint _stakingDuration,
        uint _APY,
        uint _minimumDeposit
    ) public onlyOwner returns(uint _createdPoolIndex) {
        pool[poolIndex].poolName = _poolName;
        pool[poolIndex].stakingDuration = _stakingDuration;
        pool[poolIndex].APY = _APY;
        pool[poolIndex].minimumDeposit = _minimumDeposit;
        pool[poolIndex].poolIsInitialized = true;
        poolIndexArray.push(poolIndex);
        emit PoolCreated(poolIndex, _poolName, _stakingDuration, _APY, _minimumDeposit);
        poolIndex = poolIndex.add(1);
        return (poolIndex.sub(1));
    }

    //User
    function stake(uint _amount, uint poolID) public nonReentrant {
        require(pool[poolID].poolIsInitialized == true, "Pool does not exist");
        require(pool[poolID].stakingIsPaused == false, "Staking in this pool is currently Paused. Please contact admin");
        require(pool[poolID].hasStaked[msg.sender] == false, "You currently have a stake in this pool. You have to Unstake.");
        require(_amount >= pool[poolID].minimumDeposit, "stake(): You are trying to stake below the minimum for this pool");
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        pool[poolID].totalStaked = pool[poolID].totalStaked.add(_amount);
        pool[poolID].userStakedBalance[msg.sender] = pool[poolID].userStakedBalance[msg.sender].add(_amount);
        pool[poolID].stakers.push(msg.sender);
        pool[poolID].hasStaked[msg.sender] = true;
        pool[poolID].lastTimeUserStaked[msg.sender] = block.timestamp;
        emit Staked(msg.sender, poolID, _amount);
    }

    function claimReward(uint _poolID) public nonReentrant {
        require(pool[_poolID].hasStaked[msg.sender] == true, "You currently have no stake in this pool.");
        uint stakeTime = pool[_poolID].lastTimeUserStaked[msg.sender];
        uint claimerStakedBalance = pool[_poolID].userStakedBalance[msg.sender];
        if ((block.timestamp.sub(stakeTime)) < pool[_poolID].stakingDuration) {
            uint stakedBalance_notWei = claimerStakedBalance.div(1e6);
            uint feePercValue_wei = (stakedBalance_notWei.mul(feePerc)).mul(1e4);
            claimerStakedBalance = claimerStakedBalance.sub(feePercValue_wei);
            pool[_poolID].userStakedBalance[msg.sender] = pool[_poolID].userStakedBalance[msg.sender].sub(feePercValue_wei);
            stakingToken.safeTransfer(feeReceiver, feePercValue_wei);
            pool[_poolID].userStakedBalance[msg.sender] = 0;
            stakingToken.safeTransfer(msg.sender, claimerStakedBalance);
            pool[_poolID].totalStaked = pool[_poolID].totalStaked.sub(claimerStakedBalance.add(feePercValue_wei));
            pool[_poolID].hasStaked[msg.sender] = false;
            emit Unstaked(msg.sender, _poolID, claimerStakedBalance);
        } else {
            uint reward = calculateUserRewards(msg.sender, _poolID);
            require(reward > 0, "Rewards is too small to be claimed");
            pool[_poolID].userStakedBalance[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            stakingToken.safeTransfer(msg.sender, claimerStakedBalance);
            pool[_poolID].totalStaked = pool[_poolID].totalStaked.sub(claimerStakedBalance);
            pool[_poolID].hasStaked[msg.sender] = false;
            emit RewardClaimed(msg.sender, _poolID, reward);
            emit Unstaked(msg.sender, _poolID, claimerStakedBalance);
        }
    }

    //View
    function calculateUserRewards(address userAddress, uint poolID) public view returns(uint) {
        if (pool[poolID].hasStaked[userAddress] == true) {
            uint lastTimeStaked = pool[poolID].lastTimeUserStaked[userAddress];
            uint periodSpentStaking = block.timestamp.sub(lastTimeStaked);
            uint userStake_wei = pool[poolID].userStakedBalance[userAddress];
            require(userStake_wei > 0, "User has no staked balance");
            uint userReward_inWei = getPerSecondRewards(poolID, userStake_wei).mul(periodSpentStaking);
            return userReward_inWei;
        } else {
            return 0;
        }
    }

    function getAPY(uint _poolID) public view returns(uint) {
        return pool[_poolID].APY;
    }

    function getFeePerc() public view returns(uint) {
        return feePerc;
    }

    function getFeeReceiver() public view returns(address) {
        return feeReceiver;
    }

    function getHasStaked(uint _poolId, address _user) public view returns(bool) {
        return pool[_poolId].hasStaked[_user];
    }

    function getLastTimeUserStaked(uint _poolId, address _user) public view returns(uint) {
        return pool[_poolId].lastTimeUserStaked[_user];
    }

    function getMinimumDeposit(uint _poolId) public view returns(uint) {
        return pool[_poolId].minimumDeposit;
    }

    function getOverallPoolStaked() public view returns(uint) {
        uint totalStakedInAllPools;
        for (uint i = 0; i < poolIndexArray.length; i++) {
            totalStakedInAllPools += pool[i].totalStaked;
        }
        return totalStakedInAllPools;
    }

    function getPerSecondRewards(uint poolID, uint amountStakeWei) public view returns(uint) {
        uint apy = pool[poolID].APY;
        uint secondsInYear = 365 days;
        uint userRewardPerYearInWei = (apy > 0) ? amountStakeWei.mul(apy).div(100).div(secondsInYear) : 0;
        return userRewardPerYearInWei;
    }

    function getPoolIndex() public view returns(uint) {
        return poolIndex;
    }

    function getPoolIndexArray() public view returns(uint[] memory) {
        return poolIndexArray;
    }

    function getPoolIsInitialized(uint _poolId) public view returns(bool) {
        return pool[_poolId].poolIsInitialized;
    }

    function getPoolName(uint _poolId) public view returns(string memory) {
        return pool[_poolId].poolName;
    }

    function getPoolState(uint _poolID) public view returns(bool _stakingIsPaused) {
        return pool[_poolID].stakingIsPaused;
    }

    function getPoolTotalStaked(uint _poolId) public view returns(uint) {
        return pool[_poolId].totalStaked;
    }

    function getRewardsToken() external view returns(address) {
        return address(rewardsToken);
    }

    function getStakers(uint _poolId) public view returns(address[] memory) {
        return pool[_poolId].stakers;
    }

    function getStakersCount(uint _poolId) public view returns(uint) {
        return pool[_poolId].stakers.length;
    }

    function getStakingDuration(uint _poolId) public view returns(uint) {
        return pool[_poolId].stakingDuration;
    }

    function getStakingToken() external view returns(address) {
        return address(stakingToken);
    }

    function getUserStakedBalance(uint _poolId, address _user) public view returns(uint256) {
        return pool[_poolId].userStakedBalance[_user];
    }

    //Admin
    function recoverERC20Tokens(address tokenAddress, uint tokenAmount) public validTokenAddress(tokenAddress) onlyOwner {
        require(tokenAmount > 0, "Invalid token amount");
        require(IERC20(tokenAddress).balanceOf(address(this)) >= tokenAmount, "Insufficient balance");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }

    function recoverNativeTokens(uint tokenAmount) public onlyOwner {
        require(tokenAmount > 0, "Invalid token amount");
        require(address(this).balance >= tokenAmount, "Insufficient balance");
        payable(owner()).transfer(tokenAmount);
    }

    function setFeePerc(uint _feePerc) public onlyOwner {
        feePerc = _feePerc;
        emit FeeUpdated(_feePerc);
    }

    function setFeeReceiver(address _feeReceiver) public onlyOwner {
        feeReceiver = _feeReceiver;
        emit FeeReceiverUpdated(_feeReceiver);
    }

    function setHasStaked(uint _poolId, address _user, bool _hasStaked) public onlyOwner {
        pool[_poolId].hasStaked[_user] = _hasStaked;
    }

    function setLastTimeUserStaked(uint _poolId, address _user, uint _timestamp) public onlyOwner {
        pool[_poolId].lastTimeUserStaked[_user] = _timestamp;
    }

    function setMinimumDeposit(uint _poolIndex, uint _minimumDeposit) public onlyOwner {
        require(_minimumDeposit > 0, "Minimum deposit must be greater than zero");
        pool[_poolIndex].minimumDeposit = _minimumDeposit;
        emit MinimumDepositUpdated(_poolIndex, _minimumDeposit);
    }

    function setPoolAPY(uint _poolID, uint _newAPY) public onlyOwner {
        pool[_poolID].APY = _newAPY;
        emit APYUpdated(_poolID, _newAPY);
    }

    function setPoolIsInitialized(uint _poolId, bool _initialized) public onlyOwner {
        pool[_poolId].poolIsInitialized = _initialized;
    }

    function setPoolName(uint _poolId, string memory _poolName) public onlyOwner {
        pool[_poolId].poolName = _poolName;
    }

    function setPoolStakingStatus(uint _poolIndex, bool _isPaused) public onlyOwner {
        pool[_poolIndex].stakingIsPaused = _isPaused;
    }

    function setRewardsToken(address _rewardsToken) public validTokenAddress(_rewardsToken) onlyOwner {
        rewardsToken = IERC20(_rewardsToken);
        emit RewardsTokenUpdated(_rewardsToken);
    }

    function setStakingDuration(uint _poolIndex, uint _stakingDuration) public onlyOwner {
        require(_stakingDuration > 0, "Minimum Staking Duration must be greater than zero");
        pool[_poolIndex].stakingDuration = _stakingDuration;
        emit StakingDurationUpdated(_poolIndex, _stakingDuration);
    }

    function setStakingToken(address _stakingToken) public validTokenAddress(_stakingToken) onlyOwner {
        stakingToken = IERC20(_stakingToken);
        emit StakingTokenUpdated(_stakingToken);
    }

    function setTotalStaked(uint _poolId, uint _totalStaked) public onlyOwner {
        pool[_poolId].totalStaked = _totalStaked;
    }

    function setUserStakedBalance(uint _poolId, address _user, uint256 _balance) public onlyOwner {
        pool[_poolId].userStakedBalance[_user] = _balance;
    }

    function togglePausePool(uint _poolID) public onlyOwner {
        bool newStatus = !pool[_poolID].stakingIsPaused;
        pool[_poolID].stakingIsPaused = newStatus;
        emit PoolPaused(_poolID, newStatus);
    }

}
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IWrappedNative.sol";

/**
Similar to Pancake SousChef/SyrupPools/PolyFi MoneyPot.
Each RefillingChef contract is deployed to serve a single farm.
Stake token and output token is defined on contract creation.
Output token is refilled by calling the income(uint256 _amount) function.
*/

contract RefillingChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;                 // Address of LP token contract.
        uint256 allocPoint;             // How many allocation points assigned to this pool.
        uint256 lastRewardBlock;        // Last block number that reward distribution occurs.
        uint256 accRewardPerShare;       // Accumulated reward per share, times 1e12. See below.
        uint256 currentDepositAmount;   // Current total deposit amount in this pool
    }

    address constant public wrappedNativeAddress = address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    // The reward token
    IERC20 public rewardToken;
    // Reward tokens created per block.
    uint256 public rewardsPerBlock;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when mining starts.
    uint256 public startBlock;

    uint256 public remainingRewards = 0;

    event Harvest(address indexed user, uint256 amount);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event UpdateEmissionRate(address indexed user, uint256 rewardsPerBlock);

    constructor(IERC20 _stakeToken, IERC20 _rewardToken) public {
        rewardToken = _rewardToken;

        poolInfo.push(PoolInfo({
        lpToken : _stakeToken,
        allocPoint : 100,
        lastRewardBlock : startBlock,
        accRewardPerShare : 0,
        currentDepositAmount : 0
        }));

        totalAllocPoint = 100;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) private pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending rewards on frontend.
    function pendingRewards(address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.currentDepositAmount;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            //calculate total rewards based on remaining funds
            if (remainingRewards > 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
                uint256 totalRewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
                totalRewards = Math.min(totalRewards, remainingRewards);
                accRewardPerShare = accRewardPerShare.add(totalRewards.mul(1e12).div(lpSupply));
            }
        }
        return user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        PoolInfo storage pool = poolInfo[0];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.currentDepositAmount;
        if (lpSupply == 0 || pool.allocPoint == 0 || rewardsPerBlock == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        if (remainingRewards == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        //calculate total rewards based on remaining funds
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 totalRewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        totalRewards = Math.min(totalRewards, remainingRewards);
        remainingRewards = remainingRewards.sub(totalRewards);
        pool.accRewardPerShare = pool.accRewardPerShare.add(totalRewards.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function income(uint256 _amount) external nonReentrant {
        updatePool();
        rewardToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        remainingRewards = remainingRewards.add(_amount);
    }

    // Deposit LP tokens to Chef
    function deposit(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeRewardTransfer(msg.sender, pending);
                emit Harvest(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
            pool.currentDepositAmount = pool.currentDepositAmount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Deposit(msg.sender, _amount);
    }

    // Withdraw LP tokens from Chef.
    function withdraw(uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool();
        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeRewardTransfer(msg.sender, pending);
            emit Harvest(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.currentDepositAmount = pool.currentDepositAmount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Withdraw(msg.sender, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public nonReentrant {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.currentDepositAmount = pool.currentDepositAmount.sub(amount);
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // Safe rewards transfer function, just in case if rounding error causes pool to not have enough tokens.
    function safeRewardTransfer(address _to, uint256 _amount) internal {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 transferAmount = Math.min(balance, _amount);
        if (address(rewardToken) == wrappedNativeAddress) {
            //If the reward token is a wrapped native token, we will unwrap it and send native
            IWrappedNative(wrappedNativeAddress).withdraw(transferAmount);
            safeTransferETH(_to, transferAmount);
        } else {
            bool transferSuccess = rewardToken.transfer(_to, transferAmount);
            require(transferSuccess, "safeRewardTransfer: transfer failed");
        }
    }

    //For unwrapping native tokens
    receive() external payable {
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value : value}(new bytes(0));
        require(success, 'safeTransferETH: ETH_TRANSFER_FAILED');
    }

    function updateEmissionSettings(uint256 _rewardsPerBlock) external onlyOwner {
        updatePool();
        rewardsPerBlock = _rewardsPerBlock;
        emit UpdateEmissionRate(msg.sender, _rewardsPerBlock);
    }
}

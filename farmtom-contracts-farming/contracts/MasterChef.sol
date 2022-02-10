// SPDX-License-Identifier: MIT
pragma solidity >= 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IERC20Mintable.sol";

/**
This is the masterchef.

It has several features:

- Ownable
- ReentrancyGuard
- Farms with:
--- Lockup period (customizable)
--- Deposit fee (customizable)
--- Primary or secondary tokens as reward

Owner --> Timelock

Base is the Masterchef from Sushi/Pancake/Goose/ProtoFi with some additional changes
*/
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;           // How many LP tokens the user has provided.
        uint256 rewardDebt;       // Reward debt. See explanation below.
        uint256 rewardLockedUp;   // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of primary
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accRewardPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accRewardPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 lpSupply;         // Supply of the lp token related to the pool.
        uint256 allocPoint;       // How many allocation points assigned to this pool.
        uint256 lastRewardBlock;  // Last block number that reward distribution occurs.
        uint256 accRewardPerShare; // Accumulated reward per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points.
        uint256 harvestInterval;  // Harvest interval in seconds.
        bool isSecondaryRewards;     // Establishes which token is given as reward for each pool.
    }

    // The primary token
    IERC20Mintable public primaryToken;
    // The secondary token
    IERC20Mintable public secondaryToken;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // Tokens created per block, number including decimals.
    uint256 public rewardsPerBlock;
    // Bonus muliplier
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days; // Cannot be changed, ever!
    // Max deposit fee is at 6% - Gives us a bit of flexibility, in general it will be <= 4.5%
    uint256 public constant MAXIMUM_DEPOSIT_FEES = 600; // Cannot be changed, ever!

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Rewards Receiver
    address public nftPoolAddress;
    bool private _isNftPoolAddressSet = false;
    uint16 public nftPoolFeeBP = 0; // Starting fee base points 0 --> 0% (e.g. 2000 equals to 20%)
    uint256 public constant MAXIMUM_NFTPOOL_MINT_BP = 2000; // Cannot be changed, ever!

    // Events, always useful to keep trak
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event UpdateEmissionRate(address indexed user, uint256 indexed rewardsPerBlock);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    event UpdatedDevAddress(address indexed previousDevAddress, address indexed newDevAddress);
    event UpdatedFeeAddress(address indexed previousFeeAddress, address indexed newFeeAddress);
    event UpdatedNftPoolAddress(address indexed newPoolAddress);
    event UpdatedNftPoolFeeBP(uint16 nftPoolFeeBP);

    constructor(
        IERC20Mintable _primaryToken,
        IERC20Mintable _secondaryToken,
        uint256 _startBlock,
        uint256 _rewardsPerBlock,
        address _devaddr,
        address _feeAddress
    ) public {
        primaryToken = _primaryToken;
        secondaryToken = _secondaryToken;
        startBlock = _startBlock;
        rewardsPerBlock = _rewardsPerBlock;

        devAddress = _devaddr;
        feeAddress = _feeAddress;

        // No pools are added by default!
    }

    // Checks that poolInfo array has length at least >= _pid
    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    // Returns the number of pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _harvestInterval,
        bool _isSecondaryRewards,
        bool _withUpdate
    ) public onlyOwner {

        // First deposit fee and harvest interval must not be higher than predefined values
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEES, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");

        //This _withUpdate flag is included in case massUpdatePools() ever exceeds blockchain gas limit
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        // Update the totalAllocPoint for the whole masterchef!
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        lpSupply : 0,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accRewardPerShare : 0,
        depositFeeBP : _depositFeeBP,
        harvestInterval : _harvestInterval,
        isSecondaryRewards : _isSecondaryRewards
        }));
    }

    // Update the given pool's allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        uint256 _harvestInterval,
        bool _isSecondaryRewards,
        bool _withUpdate
    ) public onlyOwner {
        // First deposit fee and harvest interval must not be higher than predefined values
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEES, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        poolInfo[_pid].isSecondaryRewards = _isSecondaryRewards;

        if (prevAllocPoint != _allocPoint) {
            // Update the totalAllocPoint for the whole masterchef!
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending rewards on frontend.
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.lpSupply; // Taken from the poolInfo!
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 rewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accRewardPerShare = accRewardPerShare.add(rewards.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpSupply;
        if (lpSupply == 0 || pool.allocPoint == 0 || rewardsPerBlock == 0 ) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 rewards = multiplier.mul(rewardsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        // extra 10% fees to the dev address
        primaryToken.mint(devAddress, rewards.div(10));

        if (_isNftPoolAddressSet && nftPoolFeeBP > 0) {
            // This additional fee goes for the NFT APR boost
            primaryToken.mint(nftPoolAddress, rewards.mul(nftPoolFeeBP).div(10000));
        }

        if (pool.isSecondaryRewards) {
            secondaryToken.mint(address(this), rewards);
        }
        else {
            primaryToken.mint(address(this), rewards);
        }
        pool.accRewardPerShare = pool.accRewardPerShare.add(rewards.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    /**
    Deposit LP tokens to MasterChef for rewards.
    At the same time, updates the Pool and harvests if the user
    is allowed to harvest from this pool
    */
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingRewards(_pid);
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);
            if (pool.depositFeeBP > 0) {
                // Stake paying deposit fees.
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
    Withdraw LP tokens from MasterChef.
    At the same time, updates the Pool and harvests if the user
    is allowed to harvest from this pool
    */
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: user amount staked is lower than the requested amount");

        updatePool(_pid);
        payOrLockupPendingRewards(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /**
    Withdraw without caring about rewards. EMERGENCY ONLY.
    Resets user infos.
    Resets pool infos for the user (lpSupply)
    Transfers staked tokens to the user
    */
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpSupply = pool.lpSupply.sub(amount);
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending rewards.
    function payOrLockupPendingRewards(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            // Update nextHarvestTime for the user if it's set to 0
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accRewardPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // Reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // Send rewards
                if (pool.isSecondaryRewards) {
                    safeSecondaryTransfer(msg.sender, totalRewards);
                }
                else {
                    safePrimaryTransfer(msg.sender, totalRewards);
                }
                emit Harvest(msg.sender, _pid, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    function safePrimaryTransfer(address _to, uint256 _amount) internal {
        safeTokenTransfer(primaryToken, _to, _amount);
    }

    function safeSecondaryTransfer(address _to, uint256 _amount) internal {
        safeTokenTransfer(secondaryToken, _to, _amount);
    }

    // Safe transfer function, just in case if rounding error causes pool to not have enough tokens.
    function safeTokenTransfer(IERC20 token, address _to, uint256 _amount) private {
        uint256 balance = token.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > balance) {
            transferSuccess = token.transfer(_to, balance);
        } else {
            transferSuccess = token.transfer(_to, _amount);
        }
        require(transferSuccess, "safeTokenTransfer: Transfer failed");
    }

    function getPoolInfo(uint256 _pid) external view
    returns (address lpToken, uint256 allocPoint,
        uint256 lastRewardBlock, uint256 accRewardPerShare,
        uint256 depositFeeBP, uint256 harvestInterval,
        bool isSecondaryRewards) {
        return (
        address(poolInfo[_pid].lpToken),
        poolInfo[_pid].allocPoint,
        poolInfo[_pid].lastRewardBlock,
        poolInfo[_pid].accRewardPerShare,
        poolInfo[_pid].depositFeeBP,
        poolInfo[_pid].harvestInterval,
        poolInfo[_pid].isSecondaryRewards
        );
    }

    // Sets the dev address, can be changed only by the dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
        emit UpdatedDevAddress(msg.sender, _devAddress);
    }

    // Sets the fee address, can be changed only by the feeAddress.
    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
        emit UpdatedFeeAddress(msg.sender, _feeAddress);
    }

    // Update Emission Rate to control the emission per block.
    function updateEmissionRate(uint256 _rewardsPerBlock, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        rewardsPerBlock = _rewardsPerBlock;
        emit UpdateEmissionRate(msg.sender, _rewardsPerBlock);
    }

    // Sets the pool address, can be changed only by the owner.
    function setNftPoolAddress(address _nftPoolAddress) public onlyOwner {
        nftPoolAddress = _nftPoolAddress;
        _isNftPoolAddressSet = true;
        emit UpdatedNftPoolAddress(_nftPoolAddress);
    }

    // Sets amount to mint for the NFT pool, can be changed only by the owner.
    function updateNftPoolFeeBP(uint16 _nftPoolFeeBP) public onlyOwner {
        require(_nftPoolFeeBP <= MAXIMUM_NFTPOOL_MINT_BP, "set: invalid pool fee basis points");
        nftPoolFeeBP = _nftPoolFeeBP;
        emit UpdatedNftPoolFeeBP(_nftPoolFeeBP);
    }

    function harvest(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        payOrLockupPendingRewards(_pid);
        user.rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
    }

    function bulkHarvest(uint256[] calldata pidArray) external {
        uint256 length = pidArray.length;
        for (uint256 index = 0; index < length; ++index) {
            uint256 _pid = pidArray[index];
            harvest(_pid);
        }
    }
}
# farmtom-contracts-farming
### FarmtomToken.sol
This is the contract of the primary token.

Features:
- Ownable
- Strictly related to the second token
- You can use the second token to claim the primary token.
- Antiwhale,  can be set up only by operator

Owner --> Masterchef for farming features

Operator --> Team address that handles the antiwhales settings when needed

### AnimalToken.sol
This is the contract of the secondary token.

Features:
- Ownable
- Keeps track of every holder
- Can be swapped for the primary tokens
- Keeps track of the penalty over time to swap this token for the primary token

Owner --> Masterchef for farming features

Operator --> Team address that handles the swap penalty settings when needed

### MasterChef.sol

This is the MasterChef.
Base is the Masterchef from Sushi/Pancake/Goose/ProtoFi with some additional changes

It has several features:

- Ownable
- ReentrancyGuard
- Farms with:
  - Lockup period (customizable)
  - Deposit fee (customizable)
  - Primary or secondary tokens as reward

Owner --> Timelock

### RefillingChef.sol
Similar to Pancake-SousChef/SyrupPools, PolyFi-MoneyPot.

- Each RefillingChef contract is deployed to serve a single farm
- Stake token and output token is defined on contract creation
- Output token is refilled by calling the income(uint256 _amount) function

Owner --> Timelock


# farmtom-contracts-lpfactory

### LPFactory.sol
Based on the polyfi one and all the others based on Uniswap V2

Non-standard function --> setFeeAmount and feeAmount

### LPPair.sol
Pretty much standard, the only thing that slightly change is the _mintFee() function
that lets us to change the portion of fees that go to the feeAddress and to LP providers.

Other things are exactly the same as all the other UniswapV2 forks

# farmtom-contracts-router

### SwapRouter.sol
Exactly equal to other UniswapV2 forks
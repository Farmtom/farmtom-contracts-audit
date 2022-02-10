// SPDX-License-Identifier: MIT
/**
Based on the polyfi one and all the others based on Uniswap V2

Non-standard function --> setFeeAmount and feeAmount
 */
pragma solidity >= 0.5.16;

import "./interfaces/ILPFactory.sol";
import "./LPPair.sol";

contract LPFactory is ILPFactory {
    uint16 public constant SWAP_FEE_BP = 13;
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(LPPair).creationCode));

    address public feeTo;
    address public feeToSetter;
    uint16 private _feeAmount = SWAP_FEE_BP;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    event FeeToUpdated(address feeTo);
    event FeeAmountUpdated(uint16 feeAmount);

    constructor(address owner) public {
        feeToSetter = owner;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'createPair: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'createPair: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'createPair: PAIR_EXISTS');
        // single check is sufficient
        bytes memory bytecode = type(LPPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ILPPair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'setFeeTo: FORBIDDEN');
        feeTo = _feeTo;

        emit FeeToUpdated(_feeTo);
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'setFeeToSetter: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    function feeAmount() external view returns (uint16){
        return _feeAmount;
    }

    function setFeeAmount(uint16 _newFeeAmount) external {//Mod for fees
        // This parameter allow us to lower the fee which will be send to the feeTo address
        // 13 = 0.13% (all fee goes directly to the feeTo address)
        // If we update it to 5 for example, 8/13 are going to LP holder and 5/13 to the feeManager
        require(msg.sender == feeToSetter, 'setFeeAmount: FORBIDDEN');
        require(_newFeeAmount <= SWAP_FEE_BP, "amount too big");
        _feeAmount = _newFeeAmount;

        emit FeeAmountUpdated(_newFeeAmount);
    }
}
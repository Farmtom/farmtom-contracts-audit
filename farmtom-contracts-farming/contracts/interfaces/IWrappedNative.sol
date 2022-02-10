// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}
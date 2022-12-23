// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

interface ITradeFactory {
    function enable(address _tokenIn, address _tokenOut) external;
}

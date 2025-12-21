// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IETFQuoter {
    error SameTokens();

    function getAllPaths(address tokenA, address tokenB) external view returns (bytes[] memory paths);

    function quoteInvestWithToken(address etf, address srcToken, uint256 mintAmount)
        external
        view
        returns (uint256 srcAmount, bytes[] memory swapPaths);

    function quoteRedeemToToken(address etf, address dstToken, uint256 burnAmount)
        external
        view
        returns (uint256 dstAmount, bytes[] memory swapPaths);

    function quoteExactOut(address tokenIn, address tokenOut, uint256 amountOut)
        external
        view
        returns (bytes memory path, uint256 amountIn);

    function quoteExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (bytes memory path, uint256 amountOut);

    function getTokenTargetValues(address etf)
        external
        view
        returns (uint24[] memory tokenTargetWeights, uint256[] memory tokenTargetValues, uint256[] memory tokenReserves);
}

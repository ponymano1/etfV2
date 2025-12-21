// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IETFQuoter} from "./interfaces/IETFQuoter.sol";
import {IETF} from "./interfaces/IETF.sol";
import {ISwapQuoter} from "./interfaces/ISwapQuoter.sol";
import {ISwapFactory} from "./interfaces/ISwapFactory.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Path} from "./libraries/Path.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ETFQuoter is IETFQuoter {
    using FullMath for uint256;
    using Path for bytes;

    ISwapQuoter public immutable swapQuoter;
    ISwapFactory public immutable swapFactory;
    uint24[3] public fees;
    address[] public bridgeTokens;

    constructor(
        address swapQuoter_,
        address swapFactory_,
        address[] memory bridgeTokens_
    ) {
        swapQuoter = ISwapQuoter(swapQuoter_);
        swapFactory = ISwapFactory(swapFactory_);
        bridgeTokens = bridgeTokens_;
        fees = [100, 500, 2500];
    }

    function quoteInvestWithToken(
        address etf,
        address srcToken,
        uint256 mintAmount
    ) external view returns (uint256 srcAmount, bytes[] memory swapPaths) {
        address[] memory tokens = IETF(etf).getTokens();
        uint256[] memory tokenAmounts = IETF(etf).getInvestTokenAmounts(
            mintAmount
        );
        uint256 totalSrcAmount = 0;

        swapPaths = new bytes[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (srcToken == tokens[i]) {
                totalSrcAmount += tokenAmounts[i];
                swapPaths[i] = bytes.concat(
                    bytes20(srcToken),
                    bytes3(fees[0]),
                    bytes20(srcToken)
                );
            } else {
                (bytes memory path, uint256 amountIn) = quoteExactOut(
                    srcToken,
                    tokens[i],
                    tokenAmounts[i]
                );
                totalSrcAmount += amountIn;
                swapPaths[i] = path;
            }
        }
        srcAmount = totalSrcAmount;
    }

    function quoteRedeemToToken(
        address etf,
        address dstToken,
        uint256 burnAmount
    ) external view returns (uint256 dstAmount, bytes[] memory swapPaths) {
        address[] memory tokens = IETF(etf).getTokens();
        uint256[] memory tokenAmounts = IETF(etf).getRedeemTokenAmounts(
            burnAmount
        );
        uint256 totalDstAmount = 0;

        swapPaths = new bytes[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (dstToken == tokens[i]) {
                totalDstAmount += tokenAmounts[i];
                swapPaths[i] = bytes.concat(
                    bytes20(dstToken),
                    bytes3(fees[0]),
                    bytes20(dstToken)
                );
            } else {
                (bytes memory path, uint256 amountOut) = quoteExactIn(
                    tokens[i],
                    dstToken,
                    tokenAmounts[i]
                );
                totalDstAmount += amountOut;
                swapPaths[i] = path;
            }
        }
        dstAmount = totalDstAmount;
    }

    function quoteExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) public view returns (bytes memory path, uint256 amountIn) {
        bytes[] memory allPaths = getAllPaths(tokenOut, tokenIn);
        uint256 minAmountIn = type(uint256).max;
        bytes memory bestPath;

        for (uint256 i = 0; i < allPaths.length; i++) {
            (bool success, bytes memory result) = address(swapQuoter)
                .staticcall(
                    abi.encodeWithSelector(
                        swapQuoter.quoteExactOutput.selector,
                        allPaths[i],
                        amountOut
                    )
                );

            if (success) {
                (uint256 amountIn_, , , ) = abi.decode(
                    result,
                    (uint256, uint160[], uint32[], uint256)
                );
                if (amountIn_ < minAmountIn) {
                    minAmountIn = amountIn_;
                    bestPath = allPaths[i];
                }
            }
        }

        path = bestPath;
        amountIn = minAmountIn == type(uint256).max ? 0 : minAmountIn;
    }

    function quoteExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (bytes memory path, uint256 amountOut) {
        bytes[] memory allPaths = getAllPaths(tokenIn, tokenOut);
        uint256 maxAmountOut = 0;
        bytes memory bestPath;

        for (uint256 i = 0; i < allPaths.length; i++) {
            (bool success, bytes memory result) = address(swapQuoter)
                .staticcall(
                    abi.encodeWithSelector(
                        swapQuoter.quoteExactInput.selector,
                        allPaths[i],
                        amountIn
                    )
                );

            if (success) {
                (uint256 amountOut_, , , ) = abi.decode(
                    result,
                    (uint256, uint160[], uint32[], uint256)
                );
                if (amountOut_ > maxAmountOut) {
                    maxAmountOut = amountOut_;
                    bestPath = allPaths[i];
                }
            }
        }

        path = bestPath;
        amountOut = maxAmountOut;
    }

    function getTokenTargetValues(
        address etf
    )
        external
        view
        returns (
            uint24[] memory tokenTargetWeights,
            uint256[] memory tokenTargetValues,
            uint256[] memory tokenReserves
        )
    {
        IETF etfContract = IETF(etf);

        address[] memory tokens;
        int256[] memory tokenPrices;
        uint256[] memory tokenMarketValues;
        uint256 totalValues;
        (tokens, tokenPrices, tokenMarketValues, totalValues) = etfContract
            .getTokenMarketValues();

        tokenTargetWeights = new uint24[](tokens.length);
        tokenTargetValues = new uint256[](tokens.length);
        tokenReserves = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            tokenTargetWeights[i] = etfContract.getTokenTargetWeight(tokens[i]);
            tokenTargetValues[i] =
                (totalValues * tokenTargetWeights[i]) /
                1000000;
            tokenReserves[i] = IERC20(tokens[i]).balanceOf(etf);
        }
    }

    function getAllPaths(
        address tokenA,
        address tokenB
    ) public view returns (bytes[] memory paths) {
        if (tokenA == tokenB) return paths;

        uint256 maxPaths = fees.length +
            (fees.length * fees.length * bridgeTokens.length);
        bytes[] memory tempPaths = new bytes[](maxPaths);
        uint256 index = 0;

        // 1. Generate direct path：tokenA -> fee -> tokenB
        for (uint256 i = 0; i < fees.length; i++) {
            if (swapFactory.getPool(tokenA, tokenB, fees[i]) != address(0)) {
                tempPaths[index] = bytes.concat(
                    bytes20(tokenA),
                    bytes3(fees[i]),
                    bytes20(tokenB)
                );
                index++;
            }
        }

        // 2. Generate intermediate token paths：tokenA -> fee1 -> intermediary -> fee2 -> tokenB
        for (uint256 i = 0; i < bridgeTokens.length; i++) {
            address bridge = bridgeTokens[i];
            for (uint256 j = 0; j < fees.length; j++) {
                for (uint256 k = 0; k < fees.length; k++) {
                    if (
                        swapFactory.getPool(tokenA, bridge, fees[j]) !=
                        address(0) &&
                        swapFactory.getPool(bridge, tokenB, fees[k]) !=
                        address(0)
                    ) {
                        tempPaths[index] = bytes.concat(
                            bytes20(tokenA),
                            bytes3(fees[j]),
                            bytes20(bridge),
                            bytes3(fees[k]),
                            bytes20(tokenB)
                        );
                        index++;
                    }
                }
            }
        }

        // 3. Only valid paths are returned
        paths = new bytes[](index);
        for (uint256 i = 0; i < index; i++) {
            paths[i] = tempPaths[i];
        }
    }
}

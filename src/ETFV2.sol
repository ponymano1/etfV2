// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IETF} from "./interfaces/IETF.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IETFQuoter} from "./interfaces/IETFQuoter.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {Path} from "./libraries/Path.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ETFV2 is IETF, Initializable, ERC20Upgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using FullMath for uint256;
    using Path for bytes;

    uint24 public constant HUNDRED_PERCENT = 1000000; // 100%
    uint256 public constant INDEX_SCALE = 1e36;

    address public feeTo;
    uint24 public investFee;
    uint24 public redeemFee;
    uint256 public minMintAmount;

    address public swapRouter;
    address public weth;
    address public usdt;
    address public etfQuoter;

    uint256 public lastRebalanceTime;
    uint256 public rebalanceInterval;
    uint24 public rebalanceDeviance;

    address public miningToken;
    uint256 public miningSpeedPerSecond;
    uint256 public miningLastIndex;
    uint256 public lastIndexUpdateTime;

    mapping(address => address) public getPriceFeed;
    mapping(address => uint24) public getTokenTargetWeight;
    mapping(address => uint256) public supplierLastIndex;
    mapping(address => uint256) public supplierRewardAccrued;

    address[] private _tokens;
    // Token amount required per 1 ETF share，used in the first invest
    uint256[] private _initTokenAmountPerShares;

    modifier _checkTotalWeights() {
        address[] memory tokens = getTokens();
        uint24 totalWeights;
        for (uint256 i = 0; i < tokens.length; i++) {
            totalWeights += getTokenTargetWeight[tokens[i]];
        }
        if (totalWeights != HUNDRED_PERCENT) revert InvalidTotalWeights();

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    struct InitializeParams {
        address owner;
        string name;
        string symbol;
        address[] tokens;
        uint256[] initTokenAmountPerShares;
        uint256 minMintAmount;
        address swapRouter;
        address weth;
        address usdt;
        address etfQuoter;
        address miningToken;
    }

    function initialize(InitializeParams memory params) public initializer {
        __ERC20_init(params.name, params.symbol);
        __Ownable_init(params.owner);

        _tokens = params.tokens;
        _initTokenAmountPerShares = params.initTokenAmountPerShares;
        minMintAmount = params.minMintAmount;
        swapRouter = params.swapRouter;
        weth = params.weth;
        usdt = params.usdt;
        etfQuoter = params.etfQuoter;
        miningToken = params.miningToken;
    }

    function setFee(
        address feeTo_,
        uint24 investFee_,
        uint24 redeemFee_
    ) external onlyOwner {
        feeTo = feeTo_;
        investFee = investFee_;
        redeemFee = redeemFee_;
    }

    function updateMinMintAmount(uint256 newMinMintAmount) external onlyOwner {
        emit MinMintAmountUpdated(minMintAmount, newMinMintAmount);
        minMintAmount = newMinMintAmount;
    }

    function setPriceFeeds(
        address[] memory tokens,
        address[] memory priceFeeds
    ) external onlyOwner {
        if (tokens.length != priceFeeds.length) revert DifferentArrayLength();
        for (uint256 i = 0; i < tokens.length; i++) {
            getPriceFeed[tokens[i]] = priceFeeds[i];
        }
    }

    function setTokenTargetWeights(
        address[] memory tokens,
        uint24[] memory targetWeights
    ) external onlyOwner {
        if (tokens.length != targetWeights.length) revert InvalidArrayLength();
        for (uint256 i = 0; i < targetWeights.length; i++) {
            getTokenTargetWeight[tokens[i]] = targetWeights[i];
        }
    }

    function updateRebalanceInterval(uint256 newInterval) external onlyOwner {
        rebalanceInterval = newInterval;
    }

    function updateRebalanceDeviance(uint24 newDeviance) external onlyOwner {
        rebalanceDeviance = newDeviance;
    }

    function addToken(address token) external onlyOwner {
        _addToken(token);
    }

    function removeToken(address token) external onlyOwner {
        if (
            IERC20(token).balanceOf(address(this)) > 0 ||
            getTokenTargetWeight[token] > 0
        ) revert Forbidden();
        _removeToken(token);
    }

    function updateMiningSpeedPerSecond(uint256 speed) external onlyOwner {
        _updateMiningIndex();
        miningSpeedPerSecond = speed;
    }

    function withdrawMiningToken(
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(miningToken).safeTransfer(to, amount);
    }

    /**
     * 计算需要的每个token的数量，可以由资深用户调用，需要用户准备好所有token
     * 铸造份额给用户
     * 转移token到合约
     * 注意：invest with all tokens, msg.sender need have approved all tokens to this contract
     */
    function invest(address to, uint256 mintAmount) public {
        //根据mintAmount计算需要的每个token的数量，铸造用户份额，计算并收取手续费
        uint256[] memory tokenAmounts = _invest(to, mintAmount);

        //转移token到合约
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (tokenAmounts[i] > 0) {
                IERC20(_tokens[i]).safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmounts[i]
                );
            }
        }
    }

    function redeem(address to, uint256 burnAmount) public {
        //计算核心等式 tokenAmount / tokenReserve = burnAmount / totalSupply
        // 结果向下取整，避免出现0。如果不向下取整，用户可以销毁很少的份额，导致需要的token数量为0
        _redeem(to, burnAmount);
    }

    //普通用户的投资方式，需要用户准备好ETH，合约会自动将ETH兑换为token
    function investWithETH(
        address to,
        uint256 mintAmount,
        bytes[] memory swapPaths
    ) external payable {
        address[] memory tokens = getTokens();
        if (tokens.length != swapPaths.length) revert InvalidArrayLength();
        uint256[] memory tokenAmounts = getInvestTokenAmounts(mintAmount);

        uint256 maxETHAmount = msg.value;
        IWETH(weth).deposit{value: maxETHAmount}();
        _approveToSwapRouter(weth);

        uint256 totalPaid;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (tokens[i] == weth) {
                totalPaid += tokenAmounts[i];
            } else {
                if (!_checkSwapPath(tokens[i], weth, swapPaths[i])) {
                    revert InvalidSwapPath(swapPaths[i]);
                }
                totalPaid += ISwapRouter(swapRouter).exactOutput(
                    ISwapRouter.ExactOutputParams({
                        path: swapPaths[i],
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountOut: tokenAmounts[i],
                        amountInMaximum: type(uint256).max
                    })
                );
            }
        }

        uint256 leftAfterPaid = maxETHAmount - totalPaid;
        if (leftAfterPaid > 0) {
            IWETH(weth).withdraw(leftAfterPaid);
            payable(msg.sender).transfer(leftAfterPaid);
        }

        _invest(to, mintAmount);

        emit InvestedWithETH(to, mintAmount, totalPaid);
    }

    /**
     * 通过Token兑换为底层资产，并铸造份额给用户
     * 过程:
     * 1. 计算需要的每个token的数量
     * 2. 转移token到合约  注意：invest with all tokens, msg.sender need have approved all tokens to this contract
     * 3. 循环每个token，交易出需要的token到合约
     * 4. 计算需要返还的token数量（没有用完的token）
     * 5. 调用_invest内部函数，铸造份额给用户，并收取手续费
     */
    function investWithToken(
        address srcToken,
        address to,
        uint256 mintAmount,
        uint256 maxSrcTokenAmount,
        bytes[] memory swapPaths
    ) external {
        address[] memory tokens = getTokens();
        if (tokens.length != swapPaths.length) revert InvalidArrayLength();
        //根据mintAmount计算需要的每个token的数量
        uint256[] memory tokenAmounts = getInvestTokenAmounts(mintAmount);
        //转移token到合约
        IERC20(srcToken).safeTransferFrom(
            msg.sender,
            address(this),
            maxSrcTokenAmount
        );
        _approveToSwapRouter(srcToken);

        //循环每个token，交易出需要的token到合约
        uint256 totalPaid;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (tokens[i] == srcToken) {
                totalPaid += tokenAmounts[i];
            } else {
                if (!_checkSwapPath(tokens[i], srcToken, swapPaths[i])) {
                    revert InvalidSwapPath(swapPaths[i]);
                }
                totalPaid += ISwapRouter(swapRouter).exactOutput(
                    ISwapRouter.ExactOutputParams({
                        path: swapPaths[i],
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountOut: tokenAmounts[i],
                        amountInMaximum: type(uint256).max
                    })
                );
            }
        }
        //计算需要返还的token数量（没有用完的token）
        uint256 leftAfterPaid = maxSrcTokenAmount - totalPaid;
        if (leftAfterPaid > 0) {
            IERC20(srcToken).safeTransfer(msg.sender, leftAfterPaid);
        }
        //调用_invest内部函数，铸造份额给用户，并收取手续费
        _invest(to, mintAmount);

        emit InvestedWithToken(srcToken, to, mintAmount, totalPaid);
    }

    function redeemToETH(
        address to,
        uint256 burnAmount,
        uint256 minETHAmount,
        bytes[] memory swapPaths
    ) external {
        address[] memory tokens = getTokens();
        if (tokens.length != swapPaths.length) revert InvalidArrayLength();

        uint256[] memory tokenAmounts = _redeem(address(this), burnAmount);

        uint256 totalReceived;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (tokens[i] == weth) {
                totalReceived += tokenAmounts[i];
            } else {
                if (!_checkSwapPath(tokens[i], weth, swapPaths[i])) {
                    revert InvalidSwapPath(swapPaths[i]);
                }
                _approveToSwapRouter(tokens[i]);
                totalReceived += ISwapRouter(swapRouter).exactInput(
                    ISwapRouter.ExactInputParams({
                        path: swapPaths[i],
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: tokenAmounts[i],
                        amountOutMinimum: 1
                    })
                );
            }
        }

        if (totalReceived < minETHAmount) revert OverSlippage();
        IWETH(weth).withdraw(totalReceived);
        _safeTransferETH(to, totalReceived);

        emit RedeemedToETH(to, burnAmount, totalReceived);
    }

    /**
     * 通过底层资产兑换为Token，并返还给用户
     * 过程:
     * 1. 调用_redeem内部函数，销毁份额给用户，并收取手续费
     * 2. 循环每个token，交易出需要的token到用户
     * 3. 判断是否满足滑点要求
     *
     */
    function redeemToToken(
        address dstToken,
        address to,
        uint256 burnAmount,
        uint256 minDstTokenAmount,
        bytes[] memory swapPaths
    ) external {
        address[] memory tokens = getTokens();
        if (tokens.length != swapPaths.length) revert InvalidArrayLength();

        uint256[] memory tokenAmounts = _redeem(address(this), burnAmount);

        uint256 totalReceived;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (tokens[i] == dstToken) {
                IERC20(tokens[i]).safeTransfer(to, tokenAmounts[i]);
                totalReceived += tokenAmounts[i];
            } else {
                if (!_checkSwapPath(tokens[i], dstToken, swapPaths[i])) {
                    revert InvalidSwapPath(swapPaths[i]);
                }
                _approveToSwapRouter(tokens[i]);
                totalReceived += ISwapRouter(swapRouter).exactInput(
                    ISwapRouter.ExactInputParams({
                        path: swapPaths[i],
                        recipient: to,
                        deadline: block.timestamp,
                        amountIn: tokenAmounts[i],
                        amountOutMinimum: 1
                    })
                );
            }
        }
        //重要：判断是否满足滑点要求，不能忘了！！！
        if (totalReceived < minDstTokenAmount) revert OverSlippage();

        emit RedeemedToToken(dstToken, to, burnAmount, totalReceived);
    }

    // rebalance函数，外部调用，调用者记得充gas
    function rebalance() external _checkTotalWeights {
        // 当前是否到了允许rebalance的时间
        if (block.timestamp < lastRebalanceTime + rebalanceInterval) {
            revert NotRebalanceTime();
        }
        lastRebalanceTime = block.timestamp;

        // 计算出每个币的市值和总市值
        (
            address[] memory tokens,
            int256[] memory tokenPrices,
            uint256[] memory tokenMarketValues,
            uint256 totalValues
        ) = getTokenMarketValues();

        // 计算每个币需要rebalance进行swap的数量
        int256[] memory tokenSwapableAmounts = new int256[](tokens.length);
        uint256[] memory reservesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            reservesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));

            if (getTokenTargetWeight[tokens[i]] == 0) continue;
            //计算每个代币的目标市值 总市值*目标权重
            uint256 weightedValue = (totalValues *
                getTokenTargetWeight[tokens[i]]) / HUNDRED_PERCENT;

            //计算每个代币的上下限 目标市值*（1-重平衡偏离阈值） 目标市值*（1+重平衡偏离阈值）
            uint256 lowerValue = (weightedValue *
                (HUNDRED_PERCENT - rebalanceDeviance)) / HUNDRED_PERCENT;
            uint256 upperValue = (weightedValue *
                (HUNDRED_PERCENT + rebalanceDeviance)) / HUNDRED_PERCENT;
            if (
                tokenMarketValues[i] < lowerValue ||
                tokenMarketValues[i] > upperValue
            ) {
                int256 deltaValue = int256(weightedValue) -
                    int256(tokenMarketValues[i]);
                uint8 tokenDecimals = IERC20Metadata(tokens[i]).decimals();

                if (deltaValue > 0) {
                    //计算每个代币需要swap的数量, 数量 = 市值/价格
                    tokenSwapableAmounts[i] = int256(
                        uint256(deltaValue).mulDiv(
                            10 ** tokenDecimals,
                            uint256(tokenPrices[i])
                        )
                    );
                } else {
                    tokenSwapableAmounts[i] = -int256(
                        uint256(-deltaValue).mulDiv(
                            10 ** tokenDecimals,
                            uint256(tokenPrices[i])
                        )
                    );
                }
            }
        }
        //进行swap操作，注意要先卖后买，避免不够买的情况
        _swapTokens(tokens, tokenSwapableAmounts);

        uint256[] memory reservesAfter = new uint256[](tokens.length);
        for (uint256 i = 0; i < reservesAfter.length; i++) {
            reservesAfter[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        emit Rebalanced(reservesBefore, reservesAfter);
    }

    function claimReward() external {
        _updateMiningIndex();
        _updateSupplierIndex(msg.sender);

        uint256 claimable = supplierRewardAccrued[msg.sender];
        if (claimable == 0) revert NothingClaimable();

        supplierRewardAccrued[msg.sender] = 0;
        IERC20(miningToken).safeTransfer(msg.sender, claimable);
        emit RewardClaimed(msg.sender, claimable);
    }

    function getTokens() public view returns (address[] memory) {
        return _tokens;
    }

    function getInitTokenAmountPerShares()
        public
        view
        returns (uint256[] memory)
    {
        return _initTokenAmountPerShares;
    }

    /**
     * 根据mintAmount计算需要的每个token的数量
     * @param mintAmount 铸造的份额数量
     * @notice 结果向上取整，避免出现0。如果不向上取整，用户可以铸造很少的份额，导致需要的token数量为0
     * 计算核心等式 tokenAmount / tokenReserve = mintAmount / totalSupply
     */
    function getInvestTokenAmounts(
        uint256 mintAmount
    ) public view returns (uint256[] memory tokenAmounts) {
        uint256 totalSupply = totalSupply();
        tokenAmounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (totalSupply > 0) {
                uint256 tokenReserve = IERC20(_tokens[i]).balanceOf(
                    address(this)
                );
                // tokenAmount / tokenReserve = mintAmount / totalSupply
                tokenAmounts[i] = tokenReserve.mulDivRoundingUp(
                    mintAmount,
                    totalSupply
                );
            } else {
                tokenAmounts[i] = mintAmount.mulDivRoundingUp(
                    _initTokenAmountPerShares[i],
                    1e18
                );
            }
        }
    }

    function getRedeemTokenAmounts(
        uint256 burnAmount
    ) public view returns (uint256[] memory tokenAmounts) {
        if (redeemFee > 0) {
            uint256 fee = (burnAmount * redeemFee) / HUNDRED_PERCENT;
            burnAmount -= fee;
        }

        uint256 totalSupply = totalSupply();
        tokenAmounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 tokenReserve = IERC20(_tokens[i]).balanceOf(address(this));
            // tokenAmount / tokenReserve = burnAmount / totalSupply
            tokenAmounts[i] = tokenReserve.mulDiv(burnAmount, totalSupply);
        }
    }

    //从预言机获取每个代币的市值，通过oracle合约获取
    function getTokenMarketValues()
        public
        view
        returns (
            address[] memory tokens,
            int256[] memory tokenPrices,
            uint256[] memory tokenMarketValues,
            uint256 totalValues
        )
    {
        tokens = getTokens();
        uint256 length = tokens.length;
        tokenPrices = new int256[](length);
        tokenMarketValues = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            AggregatorV3Interface priceFeed = AggregatorV3Interface(
                getPriceFeed[tokens[i]]
            );
            if (address(priceFeed) == address(0)) {
                revert PriceFeedNotFound(tokens[i]);
            }
            (, tokenPrices[i], , , ) = priceFeed.latestRoundData();

            uint8 tokenDecimals = IERC20Metadata(tokens[i]).decimals();
            uint256 reserve = IERC20(tokens[i]).balanceOf(address(this));
            tokenMarketValues[i] = reserve.mulDiv(
                uint256(tokenPrices[i]),
                10 ** tokenDecimals
            );
            totalValues += tokenMarketValues[i];
        }
    }

    function getClaimableReward(
        address supplier
    ) external view returns (uint256) {
        uint256 claimable = supplierRewardAccrued[msg.sender];

        // 计算最新的全局指数
        uint256 globalLastIndex = miningLastIndex;
        uint256 totalSupply = totalSupply();
        uint256 deltaTime = block.timestamp - lastIndexUpdateTime;
        if (totalSupply > 0 && deltaTime > 0 && miningSpeedPerSecond > 0) {
            uint256 deltaReward = miningSpeedPerSecond * deltaTime;
            uint256 deltaIndex = deltaReward.mulDiv(INDEX_SCALE, totalSupply);
            globalLastIndex += deltaIndex;
        }

        // 计算用户可累加的奖励
        uint256 supplierIndex = supplierLastIndex[supplier];
        uint256 supplierSupply = balanceOf(supplier);
        uint256 supplierDeltaIndex;
        if (supplierIndex > 0 && supplierSupply > 0) {
            supplierDeltaIndex = globalLastIndex - supplierIndex;
            uint256 supplierDeltaReward = supplierSupply.mulDiv(
                supplierDeltaIndex,
                INDEX_SCALE
            );
            claimable += supplierDeltaReward;
        }

        return claimable;
    }

    /**
     * 根据mintAmount计算需要的每个token的数量
     * 计算手续费
     * 铸造份额给用户，并收取手续费
     * notice: 手续费是根据mintAmount计算的，而不是根据tokenAmounts计算的
     *
     */
    function _invest(
        address to,
        uint256 mintAmount
    ) internal returns (uint256[] memory tokenAmounts) {
        if (mintAmount < minMintAmount) revert LessThanMinMintAmount();

        //根据mintAmount计算需要的每个token的数量
        //计算核心等式 tokenAmount / tokenReserve = mintAmount / totalSupply
        tokenAmounts = getInvestTokenAmounts(mintAmount);

        //计算手续费，并mint给feeTo和用户
        uint256 fee;
        if (investFee > 0) {
            fee = (mintAmount * investFee) / HUNDRED_PERCENT;
            _mint(feeTo, fee);
            _mint(to, mintAmount - fee);
        } else {
            _mint(to, mintAmount);
        }

        emit Invested(to, mintAmount, fee, tokenAmounts);
    }

    function _redeem(
        address to,
        uint256 burnAmount
    ) internal returns (uint256[] memory tokenAmounts) {
        uint256 totalSupply = totalSupply();
        tokenAmounts = new uint256[](_tokens.length);
        _burn(msg.sender, burnAmount);

        uint256 fee;
        if (redeemFee > 0) {
            fee = (burnAmount * redeemFee) / HUNDRED_PERCENT;
            _mint(feeTo, fee);
        }

        uint256 actuallyBurnAmount = burnAmount - fee;
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 tokenReserve = IERC20(_tokens[i]).balanceOf(address(this));
            tokenAmounts[i] = tokenReserve.mulDiv(
                actuallyBurnAmount,
                totalSupply
            );
            if (to != address(this) && tokenAmounts[i] > 0) {
                IERC20(_tokens[i]).safeTransfer(to, tokenAmounts[i]);
            }
        }

        emit Redeemed(msg.sender, to, burnAmount, fee, tokenAmounts);
    }

    function _addToken(address token) internal returns (uint256 index) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == token) revert TokenExists();
        }
        index = _tokens.length;
        _tokens.push(token);
        emit TokenAdded(token, index);
    }

    function _removeToken(address token) internal returns (uint256 index) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == token) {
                index = i;
                _tokens[i] = _tokens[_tokens.length - 1];
                _tokens.pop();
                emit TokenRemoved(token, index);
                return index;
            }
        }
        revert TokenNotFound();
    }

    function _approveToSwapRouter(address token) internal {
        if (
            IERC20(token).allowance(address(this), swapRouter) <
            type(uint256).max
        ) {
            IERC20(token).forceApprove(swapRouter, type(uint256).max);
        }
    }

    // The first token in the path must be tokenA, the last token must be tokenB
    function _checkSwapPath(
        address tokenA,
        address tokenB,
        bytes memory path
    ) internal pure returns (bool) {
        (address firstToken, address secondToken, ) = path.decodeFirstPool();
        if (tokenA == tokenB) {
            if (
                firstToken == tokenA &&
                secondToken == tokenA &&
                !path.hasMultiplePools()
            ) {
                return true;
            } else {
                return false;
            }
        } else {
            if (firstToken != tokenA) return false;
            while (path.hasMultiplePools()) {
                path = path.skipToken();
            }
            (, secondToken, ) = path.decodeFirstPool();
            if (secondToken != tokenB) return false;
            return true;
        }
    }

    function _swapTokens(
        address[] memory tokens,
        int256[] memory tokenSwapableAmounts
    ) internal {
        // Step1: Sell tokens, make sure have enought usdt balance to buy
        uint256 usdtRemaining = _sellTokens(usdt, tokens, tokenSwapableAmounts);
        // Step2: Use usdt to buy tokens
        usdtRemaining = _buyTokens(
            usdt,
            tokens,
            tokenSwapableAmounts,
            usdtRemaining
        );
        // If there is still usdt left, buy each token proportionally
        if (usdtRemaining > 0) {
            uint256 usdtLeft = usdtRemaining;
            for (uint256 i = 0; i < tokens.length; i++) {
                uint256 amountIn = (usdtRemaining *
                    getTokenTargetWeight[tokens[i]]) / HUNDRED_PERCENT;
                if (amountIn == 0) continue;
                if (amountIn > usdtLeft) {
                    amountIn = usdtLeft;
                }
                (bytes memory path, ) = IETFQuoter(etfQuoter).quoteExactIn(
                    usdt,
                    tokens[i],
                    amountIn
                );
                ISwapRouter(swapRouter).exactInput(
                    ISwapRouter.ExactInputParams({
                        path: path,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: amountIn,
                        amountOutMinimum: 1
                    })
                );
                usdtLeft -= amountIn;
                if (usdtLeft == 0) break;
            }
        }
    }

    function _sellTokens(
        address usdt_,
        address[] memory tokens,
        int256[] memory tokenSwapableAmounts
    ) internal returns (uint256 usdtRemaining) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenSwapableAmounts[i] < 0) {
                uint256 amountIn = uint256(-tokenSwapableAmounts[i]);
                (bytes memory path, ) = IETFQuoter(etfQuoter).quoteExactIn(
                    tokens[i],
                    usdt_,
                    amountIn
                );
                _approveToSwapRouter(tokens[i]);
                usdtRemaining += ISwapRouter(swapRouter).exactInput(
                    ISwapRouter.ExactInputParams({
                        path: path,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: amountIn,
                        amountOutMinimum: 1
                    })
                );
            }
        }
    }

    function _buyTokens(
        address usdt_,
        address[] memory tokens,
        int256[] memory tokenSwapableAmounts,
        uint256 usdtRemaining
    ) internal returns (uint256 usdtLeft) {
        usdtLeft = usdtRemaining;
        _approveToSwapRouter(usdt);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenSwapableAmounts[i] > 0) {
                (bytes memory path, uint256 amountIn) = IETFQuoter(etfQuoter)
                    .quoteExactOut(
                        usdt_,
                        tokens[i],
                        uint256(tokenSwapableAmounts[i])
                    );
                if (usdtLeft >= amountIn) {
                    usdtLeft -= ISwapRouter(swapRouter).exactOutput(
                        ISwapRouter.ExactOutputParams({
                            path: path,
                            recipient: address(this),
                            deadline: block.timestamp,
                            amountOut: uint256(tokenSwapableAmounts[i]),
                            amountInMaximum: type(uint256).max
                        })
                    );
                } else if (usdtLeft > 0) {
                    (path, ) = IETFQuoter(etfQuoter).quoteExactIn(
                        usdt,
                        tokens[i],
                        usdtLeft
                    );
                    ISwapRouter(swapRouter).exactInput(
                        ISwapRouter.ExactInputParams({
                            path: path,
                            recipient: address(this),
                            deadline: block.timestamp,
                            amountIn: usdtLeft,
                            amountOutMinimum: 1
                        })
                    );
                    usdtLeft = 0;
                    break;
                }
            }
        }
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        if (!success) revert SafeTransferETHFailed();
    }

    function _updateMiningIndex() internal {
        if (miningLastIndex == 0) {
            miningLastIndex = INDEX_SCALE;
            lastIndexUpdateTime = block.timestamp;
        } else {
            uint256 totalSupply = totalSupply();
            uint256 deltaTime = block.timestamp - lastIndexUpdateTime;
            if (totalSupply > 0 && deltaTime > 0 && miningSpeedPerSecond > 0) {
                uint256 deltaReward = miningSpeedPerSecond * deltaTime;
                uint256 deltaIndex = deltaReward.mulDiv(
                    INDEX_SCALE,
                    totalSupply
                );
                miningLastIndex += deltaIndex;
                lastIndexUpdateTime = block.timestamp;
            } else if (deltaTime > 0) {
                lastIndexUpdateTime = block.timestamp;
            }
        }
    }

    function _updateSupplierIndex(address supplier) internal {
        uint256 lastIndex = supplierLastIndex[supplier];
        uint256 supply = balanceOf(supplier);
        uint256 deltaIndex;
        if (lastIndex > 0 && supply > 0) {
            deltaIndex = miningLastIndex - lastIndex;
            uint256 deltaReward = supply.mulDiv(deltaIndex, INDEX_SCALE);
            supplierRewardAccrued[supplier] += deltaReward;
        }
        supplierLastIndex[supplier] = miningLastIndex;
        emit SupplierIndexUpdated(supplier, deltaIndex, miningLastIndex);
    }

    // override ERC20 _update function
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        _updateMiningIndex();
        if (from != address(0)) _updateSupplierIndex(from);
        if (to != address(0)) _updateSupplierIndex(to);
        super._update(from, to, value);
    }

    // Storage gaps
    uint256[50] private __gap;
}

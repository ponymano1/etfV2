// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ETFBoostToken} from "../src/ETFBoostToken.sol";
import {ETFQuoter} from "../src/ETFQuoter.sol";
import {ETFV2} from "../src/ETFV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract DeployScript is Script {
    address deployer;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        deployer = vm.addr(deployerPrivateKey);

        address ept = deployProtocolToken();
        address quoter = deployQuoter();
        address proxy = deployETFUpgradeable(quoter, ept);
        console.log("Proxy", proxy);

        vm.stopBroadcast();
    }

    function deployProtocolToken() public returns (address ept) {
        address defaultAdmin = deployer;
        address minter = deployer;
        ept = address(new ETFBoostToken(defaultAdmin, minter));
    }

    function deployQuoter() public returns (address quoter) {
        // `BNB、USDT`
        address wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        address usdt = 0x55d398326f99059fF775485246999027B3197955;
        address[] memory bridgeTokens = new address[](2);
        bridgeTokens[0] = wbnb;
        bridgeTokens[1] = usdt;
        address swapQuoter = 0xf55b152071f9C1ec4A209688ba0a770acf6f579d;
        address swapFactory = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
        quoter = address(new ETFQuoter(swapQuoter, swapFactory, bridgeTokens));
    }

    function deployETFUpgradeable(
        address etfQuoter,
        address ept
    ) public returns (address proxy) {
        string memory name = "Top8Coins";
        string memory symbol = "TOP8";

        address[] memory tokens = new address[](8);
        address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        {
            address BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
            address ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
            address XRP = 0x1D2F0da169ceB9fC7B3144628dB156f3F6c60dBE;
            address SOL = 0x570A5D26f7765Ecb712C0924E4De545B89fD43dF;
            address DOGE = 0xbA2aE424d960c26247Dd6c32edC70B295c744C43; // decimals: 8
            address ADA = 0x3EE2200Efb3400fAbB9AacF31297cBdD1d435D47;
            address CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
            tokens[0] = BTCB;
            tokens[1] = ETH;
            tokens[2] = XRP;
            tokens[3] = SOL;
            tokens[4] = WBNB;
            tokens[5] = DOGE;
            tokens[6] = ADA;
            tokens[7] = CAKE;
        }

        address[] memory priceFeeds = new address[](8);
        {
            address btcPriceFeed = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
            address ethPriceFeed = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;
            address xrpPriceFeed = 0x93A67D414896A280bF8FFB3b389fE3686E014fda;
            address solPriceFeed = 0x0E8a53DD9c13589df6382F13dA6B3Ec8F919B323;
            address bnbPriceFeed = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
            address dogePriceFeed = 0x3AB0A0d137D4F946fBB19eecc6e92E64660231C8;
            address adaPriceFeed = 0xa767f745331D267c7751297D982b050c93985627;
            address cakePriceFeed = 0xB6064eD41d4f67e353768aA239cA86f4F73665a1;
            priceFeeds[0] = btcPriceFeed;
            priceFeeds[1] = ethPriceFeed;
            priceFeeds[2] = xrpPriceFeed;
            priceFeeds[3] = solPriceFeed;
            priceFeeds[4] = bnbPriceFeed;
            priceFeeds[5] = dogePriceFeed;
            priceFeeds[6] = adaPriceFeed;
            priceFeeds[7] = cakePriceFeed;
        }

        uint256[] memory initTokenAmountPerShares = new uint256[](
            tokens.length
        );
        uint24[] memory targetWeights = new uint24[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            targetWeights[i] = 125000;
            uint8 tokenDecimals = IERC20Metadata(tokens[i]).decimals();
            AggregatorV3Interface priceFeed = AggregatorV3Interface(
                priceFeeds[i]
            );
            uint8 priceDecimals = priceFeed.decimals();
            (, int256 price, , , ) = priceFeed.latestRoundData();

            // 1USD per Share
            initTokenAmountPerShares[i] =
                ((10 ** (tokenDecimals + priceDecimals)) * 125000) /
                (uint256(price) * 1000000);
        }

        {
            uint256 minMintAmount = 1e16;
            address swapRouter = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
            address usdt = 0x55d398326f99059fF775485246999027B3197955;

            ETFV2.InitializeParams memory params = ETFV2.InitializeParams(
                deployer,
                name,
                symbol,
                tokens,
                initTokenAmountPerShares,
                minMintAmount,
                swapRouter,
                WBNB,
                usdt,
                etfQuoter,
                ept
            );

            proxy = Upgrades.deployTransparentProxy(
                "ETFUpgradeable.sol",
                deployer,
                abi.encodeCall(ETFV2.initialize, (params))
            );
        }

        ETFV2 etf = ETFV2(payable(proxy));

        {
            address feeTo = 0x4e8Ebaa604a9c1f64b9a6EA2b0633f4B96723029; // safe wallet
            uint24 investFee = 1000; // 0.1%
            uint24 redeemFee = 1000; // 0.1%
            etf.setFee(feeTo, investFee, redeemFee);
        }

        etf.setPriceFeeds(tokens, priceFeeds);

        etf.setTokenTargetWeights(tokens, targetWeights);

        uint256 rebalanceInterval = 30 * 24 * 3600;
        uint24 rebalanceDeviance = 100000;
        etf.updateRebalanceInterval(rebalanceInterval);
        etf.updateRebalanceDeviance(rebalanceDeviance);

        uint256 miningSpeedPerSecond = 1e14;
        etf.updateMiningSpeedPerSecond(miningSpeedPerSecond);

        uint256 totalSupply = IERC20(ept).totalSupply();
        IERC20(ept).transfer(address(etf), totalSupply);
    }
}

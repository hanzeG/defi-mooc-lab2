//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// Oracle
// https://docs.aave.com/developers/v/2.0/the-core-protocol/price-oracle/ipriceoracle
interface IPriceOracleGetter {
    function getAssetPrice(address _asset) external view returns (uint256);
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /**
     * Returns the address of token0 and token1 in pool.
     **/
    function token0() external view returns (address);

    function token1() external view returns (address);
}

// ----------------------IMPLEMENTATION------------------------------
contract LiquidationOperator is IUniswapV2Callee {
    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    address addrTarget = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    address addrMe = address(this);
    address addrAaveLending = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address addrUsdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address addrWbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address addrWeth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address addrUniswapFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address addrOracle = 0xA50ba011c48153De246E5192C8f9258A2ba79Ca9;

    uint256 usdtLoanPrecise;
    uint256 wbtcDecimal = 10 ** 8;
    uint256 wethDecimal = 10 ** 18;
    uint256 usdtDecimal = 10 ** 6;
    uint256 liquidationPrecise = 10000; // wbtc liquidation Bonus
    uint256 liquidationBonusWbtc = 11000; // https://github.com/aave/protocol-v2/blob/ce53c4a8c8620125063168620eba0a8a92854eb8/markets/amm/reservesConfigs.ts#L26
    uint256 usdtPrice = IPriceOracleGetter(addrOracle).getAssetPrice(addrUsdt);
    uint256 wbtcPrice = IPriceOracleGetter(addrOracle).getAssetPrice(addrWbtc);

    ILendingPool lendingPool = ILendingPool(addrAaveLending);
    IUniswapV2Factory factory = IUniswapV2Factory(addrUniswapFactory);
    IUniswapV2Pair pairWethUsdt =
        IUniswapV2Pair(factory.getPair(addrWeth, addrUsdt));
    IUniswapV2Pair pairWbtcUsdt =
        IUniswapV2Pair(factory.getPair(addrWbtc, addrUsdt));
    IUniswapV2Pair pairWbtcWeth =
        IUniswapV2Pair(factory.getPair(addrWbtc, addrWeth));

    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    receive() external payable {}

    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic
        // 0. security checks and initializing variables

        // optimizer paras
        int256 x0 = 2000000e6; // initial value
        int256 epsilon = 10000e6; // step
        int256 maxIterations = 8; // max interations
        int256 threshold = 1e6; // when grad is smaller than threshold, optimizer stop
        int256 learningRate = 9000e6; // learning rate = learningRate/ precision%
        int256 dynamic = 999000; // dynamic rate = dynamic/ precision%
        int256 precision = 1e6; // precision
        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)

        usdtLoanPrecise = uint(
            optimizer(
                x0,
                learningRate,
                epsilon,
                maxIterations,
                threshold,
                precision,
                dynamic
            )
        );
        console.log("initial usdt loan amount: %s ", uint(x0));
        console.log(
            "optimzed amount with the most profit: %s ",
            usdtLoanPrecise
        );

        pairWethUsdt.swap(0, usdtLoanPrecise, addrMe, abi.encode("flash loan"));

        // 3. Convert the profit into ETH and send back to sender
        uint256 my_eth = IERC20(addrWeth).balanceOf(addrMe);
        IWETH(addrWeth).withdraw(my_eth);
        payable(msg.sender).transfer(addrMe.balance);
        // END TODO
    }

    // calculate grad = y(x) - y(x')
    function gradient(int256 x, int256 epsilon) internal view returns (int256) {
        int256 y1 = int(targetFuntion(uint(x)));
        int256 y2 = int(targetFuntion(uint(x + epsilon)));
        return (y2 - y1) / epsilon;
    }

    // calculate x with the largest output of target function
    function optimizer(
        int256 x0,
        int256 learningRate,
        int256 epsilon,
        int256 maxIterations,
        int256 threshold,
        int256 precision,
        int256 dynamic
    ) internal view returns (int256) {
        int256 x = x0;
        int256 grad;

        for (int256 i = 0; i < maxIterations; i++) {
            grad = gradient(x, epsilon);
            if (abs(grad) < threshold) {
                console.log("stop optimize at round %s", uint(i));
                break;
            }
            // make the algorithm dynamically converge
            x = x + (((learningRate * dynamic) / precision) * grad) / precision;
        }
        return x;
    }

    // get |x|
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    // profit = collateral amount in weth - flash repay amount in weth
    function targetFuntion(
        uint256 preciseAmount
    ) internal view returns (uint256 profit) {
        profit =
            getCollateralAmount(preciseAmount) -
            getFlashRepayAmount(preciseAmount);
        return profit;
    }

    // calculate repay amount in weth of the flash loan
    function getFlashRepayAmount(
        uint256 usdtPreciseAmount
    ) internal view returns (uint256 wethPreciseAmount) {
        (uint reserves_usdt, uint reserves_weth, ) = pairWethUsdt.getReserves();
        wethPreciseAmount = getAmountIn(
            usdtPreciseAmount,
            reserves_usdt,
            reserves_weth
        );
        return wethPreciseAmount;
    }

    // calculate collateral amount with bonus in weth of the liquidation
    function getCollateralAmount(
        uint256 usdtPreciseAmount
    ) internal view returns (uint256 wethPreciseAmount) {
        uint256 coverPreciseAmount = (usdtPreciseAmount / usdtDecimal) *
            usdtPrice;
        uint256 bonusPreciseAmount = (coverPreciseAmount *
            liquidationBonusWbtc) / liquidationPrecise;
        uint256 wbtcPreciseAmount = (bonusPreciseAmount * wbtcDecimal) /
            wbtcPrice;

        // swap wbtc to weth
        (uint reserves_wbtc, uint reserves_weth, ) = pairWbtcWeth.getReserves();
        wethPreciseAmount = getAmountOut(
            wbtcPreciseAmount,
            reserves_wbtc,
            reserves_weth
        );
        return wethPreciseAmount;
    }

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic
        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        // 2.1 liquidate the target user
        IERC20(addrUsdt).approve(addrAaveLending, amount1);
        lendingPool.liquidationCall(
            addrWbtc,
            addrUsdt,
            addrTarget,
            amount1,
            false
        );
        // 2.2 swap WBTC for other things or repay directly
        // swap wbtc to weth
        uint256 wbtcAmountIn = IERC20(addrWbtc).balanceOf(addrMe);
        IERC20(addrWbtc).approve(
            factory.getPair(addrWbtc, addrWeth),
            wbtcAmountIn
        );
        IERC20(addrWbtc).transfer(
            factory.getPair(addrWbtc, addrWeth),
            wbtcAmountIn
        );
        (uint wbtcReserves1, uint wethReserves1, ) = pairWbtcWeth.getReserves();
        uint wethAmountOut = getAmountOut(
            wbtcAmountIn,
            wbtcReserves1,
            wethReserves1
        );
        pairWbtcWeth.swap(0, wethAmountOut, addrMe, "");
        // 2.3 repay
        // swap weth to usdt
        (uint wethReserves2, uint usdtReserves2, ) = pairWethUsdt.getReserves();
        uint wethAmountOut2 = getAmountIn(
            usdtLoanPrecise,
            wethReserves2,
            usdtReserves2
        );
        IERC20(addrWeth).approve(
            factory.getPair(addrWeth, addrUsdt),
            wethAmountOut2
        );
        IERC20(addrWeth).transfer(
            factory.getPair(addrWeth, addrUsdt),
            wethAmountOut2
        );
        // END TODO
    }
}

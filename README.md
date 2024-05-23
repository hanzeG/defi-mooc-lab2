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
1. For Task 1, the profit is `43.823271820635151298 ETH`, with the flash loan amount of `1772750.568908 USDT` for gainning the collateral asset in `WBTC`.
2. For Task 2, the profit is `13365540.445724 USDC`, with the flash loan amount of `18309536.000000 USDC`.

## Solutions

The entry functions for Task 1 `LiquidationOperator.sol` and Task 2 `AttackOperator.sol` are both named `operate`. All optimizer-related parameters are initialized in function `operate`.

### Task 1

Implemented an optimizer based on the gradient ascent algorithm, aimed at approximating the borrowing amount `preciseAmount` that maximizes profit. The objective function `targetFuntion(uint256 preciseAmount)` computes the total profit at a specific `preciseAmount`, which is the difference between the collateral assets obtained from liquidation and the borrowing cost from flash loans (excluding gas costs). 

```javascript
    // profit = collateral amount in weth - flash repay amount in weth
    function targetFuntion( uint256 preciseAmount ) internal view returns (uint256 profit) {
        profit =
            getCollateralAmount(preciseAmount) -
            getFlashRepayAmount(preciseAmount);
        return profit;
    }
```
The function `getCollateralAmount(uint256 usdtPreciseAmount)` for calculating the collateral assets obtained is represented below. The bonus rate `liquidationBonusWbtc` for the user's collateral assets `wBTC` is defined as 10% according to [Aave's definition](https://github.com/aave/protocol-v2/blob/ce53c4a8c8620125063168620eba0a8a92854eb8/markets/amm/reservesConfigs.ts#L26). 

```javascript
   // calculate collateral amount with bonus in weth of the liquidation
    function getCollateralAmount(uint256 usdtPreciseAmount) internal view returns (uint256 wethPreciseAmount) {
        uint256 coverPreciseAmount = (usdtPreciseAmount / usdtDecimal) * usdtPrice;
        uint256 bonusPreciseAmount = (coverPreciseAmount * liquidationBonusWbtc) / liquidationPrecise;
        uint256 wbtcPreciseAmount = (bonusPreciseAmount * wbtcDecimal) / wbtcPrice;
        // swap wbtc to weth
        (uint wbtcReserves2, uint wethReserves2, ) = pairWbtcWeth.getReserves();
        wethPreciseAmount = getAmountOut(wbtcPreciseAmount, wbtcReserves2, wethReserves2);
        return wethPreciseAmount;
    }
```
The function `getFlashRepayAmount(uint256 usdtPreciseAmount)` for calculating the flash loan cost is represented below. All the calculation processes, according to [Aave protocol](https://docs.aave.com/developers/v/2.0/guides/liquidations#id-0.-prerequisites), retrieves the corresponding price in wei units priced in `ETH` by calling [the oracle interface](https://docs.aave.com/developers/v/2.0/the-core-protocol/price-oracle/ipriceoracle).

```javascript
    // calculate repay amount in weth of the flash loan
    function getFlashRepayAmount(uint256 usdtPreciseAmount) internal view returns (uint256 wethPreciseAmount) {
        (uint usdtReserves1, uint wethReserves1, ) = pairWethUsdt.getReserves();
        wethPreciseAmount = getAmountIn(usdtPreciseAmount,usdtReserves1,wethReserves1);
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

The profit results shown earlier are achieved with such a set of parameters `(2000000e6, 10000e6, 8, 1e6, 9000e6, 999000, 1e6)`. This method has high requirements for the initial value `x0` selection, which can be improved by adding algorithms such as random generation.
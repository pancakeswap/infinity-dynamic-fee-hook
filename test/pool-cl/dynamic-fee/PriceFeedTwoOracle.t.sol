// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {MockAggregatorV3} from "../../helpers/MockAggregatorV3.sol";
import {PriceFeedTwoOracle} from "../../../src/pool-cl/dynamic-fee/PriceFeedTwoOracle.sol";
import {PriceFeedLib} from "../../../src/pool-cl/dynamic-fee/libraries/PriceFeedLib.sol";

contract PriceFeedTwoOracleTest is Test {
    MockAggregatorV3 oracle0;
    MockAggregatorV3 oracle1;
    PriceFeedTwoOracle priceFeedContract;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    uint256 constant PRECISION_DECIMALS = 18;
    uint8 public constant ORACLE_DEFAULT_DECIMALS = 18;
    int256 public constant ORACLE_DEFAULT_PRICE = int256(10 * 10 ** ORACLE_DEFAULT_DECIMALS);
    // Max price is 10^18 , FixedPoint96.Q96 * 10 ** 18
    uint256 constant MAX_PRICEX96 = 79228162514264337593543950336000000000000000000;

    function setUp() public {
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        token2 = new MockERC20("Token2", "T2", 18);

        oracle0 = new MockAggregatorV3(ORACLE_DEFAULT_DECIMALS, ORACLE_DEFAULT_PRICE);
        oracle1 = new MockAggregatorV3(ORACLE_DEFAULT_DECIMALS, ORACLE_DEFAULT_PRICE);
        priceFeedContract = new PriceFeedTwoOracle(
            address(token0), address(token1), address(oracle0), address(oracle1), 0, 0, 3600 * 24, 3600 * 24
        );
    }

    // oracle0 is A\C , oracle1 is B/C , v4 pool is A/B
    function testFuzz_twoOracle_getPriceX96_case1(uint256 oracle0_price, uint256 oracle1_price) public {
        vm.assume(oracle0_price < 10 ** 36);
        vm.assume(oracle1_price < 10 ** 36);
        vm.assume(oracle0_price > 0);
        vm.assume(oracle1_price > 0);
        oracle0.updateAnswer(int256(oracle0_price));
        oracle1.updateAnswer(int256(oracle1_price));
        // oracle0_price = c / A , oracle1_price = c / B , B / A = oracle0_price / oracle1_price
        uint256 priceX96_expected = FullMath.mulDiv(oracle0_price, FixedPoint96.Q96, oracle1_price);
        if (priceX96_expected < PriceFeedLib.MIN_PRICEX96 || priceX96_expected > PriceFeedLib.MAX_PRICEX96) {
            priceX96_expected = 0;
        }

        uint256 priceX96 = priceFeedContract.getPriceX96();
        assertApproxEqRel(priceX96, priceX96_expected, 1e18 / 100);
    }

    // oracle0 is C\A , oracle1 is B/C , v4 pool is A/B
    function testFuzz_twoOracle_getPriceX96_case2(uint256 oracle0_price, uint256 oracle1_price) public {
        priceFeedContract.updateOracles(address(oracle0), address(oracle1), 1, 0, 3600 * 24, 3600 * 24);
        vm.assume(oracle0_price < 10 ** 30);
        vm.assume(oracle1_price < 10 ** 30);
        vm.assume(oracle0_price > 10 ** 6);
        vm.assume(oracle1_price > 10 ** 6);
        oracle0.updateAnswer(int256(oracle0_price));
        oracle1.updateAnswer(int256(oracle1_price));
        // oracle0_price = A / C , oracle1_price = C / B , B / A = 1 / oracle0_price * oracle1_price
        uint256 priceX96_expected = FullMath.mulDiv(10 ** 36, FixedPoint96.Q96, oracle0_price * oracle1_price);
        if (priceX96_expected < PriceFeedLib.MIN_PRICEX96 || priceX96_expected > PriceFeedLib.MAX_PRICEX96) {
            priceX96_expected = 0;
        }

        uint256 priceX96 = priceFeedContract.getPriceX96();
        assertApproxEqRel(priceX96, priceX96_expected, 1e18 / 100);
    }

    // oracle0 is A\C , oracle1 is C/B , v4 pool is A/B
    function testFuzz_twoOracle_getPriceX96_case3(uint256 oracle0_price, uint256 oracle1_price) public {
        priceFeedContract.updateOracles(address(oracle0), address(oracle1), 0, 1, 3600 * 24, 3600 * 24);
        vm.assume(oracle0_price < 10 ** 30);
        vm.assume(oracle1_price < 10 ** 30);
        vm.assume(oracle0_price > 10 ** 6);
        vm.assume(oracle1_price > 10 ** 6);
        oracle0.updateAnswer(int256(oracle0_price));
        oracle1.updateAnswer(int256(oracle1_price));
        // oracle0_price = c / A , oracle1_price = B / c , B / A = oracle0_price * oracle1_price
        uint256 priceX96_expected = FullMath.mulDiv(oracle0_price * oracle1_price, FixedPoint96.Q96, 10 ** 36);
        if (priceX96_expected < PriceFeedLib.MIN_PRICEX96 || priceX96_expected > PriceFeedLib.MAX_PRICEX96) {
            priceX96_expected = 0;
        }

        uint256 priceX96 = priceFeedContract.getPriceX96();
        assertApproxEqRel(priceX96, priceX96_expected, 1e18 / 100);
    }

    // oracle0 is C\A , oracle1 is C/B , v4 pool is A/B
    function testFuzz_twoOracle_getPriceX96_case4(uint256 oracle0_price, uint256 oracle1_price) public {
        priceFeedContract.updateOracles(address(oracle0), address(oracle1), 1, 1, 3600 * 24, 3600 * 24);
        vm.assume(oracle0_price < 10 ** 30);
        vm.assume(oracle1_price < 10 ** 30);
        vm.assume(oracle0_price > 10 ** 6);
        vm.assume(oracle1_price > 10 ** 6);
        oracle0.updateAnswer(int256(oracle0_price));
        oracle1.updateAnswer(int256(oracle1_price));
        // oracle0_price = A / C , oracle1_price = C / B , B / A = oracle1_price / oracle0_price
        uint256 priceX96_expected = FullMath.mulDiv(oracle1_price, FixedPoint96.Q96, oracle0_price);
        if (priceX96_expected < PriceFeedLib.MIN_PRICEX96 || priceX96_expected > PriceFeedLib.MAX_PRICEX96) {
            priceX96_expected = 0;
        }

        uint256 priceX96 = priceFeedContract.getPriceX96();
        assertApproxEqRel(priceX96, priceX96_expected, 1e18 / 100);
    }
}

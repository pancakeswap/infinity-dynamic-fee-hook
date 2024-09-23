// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockAggregatorV3} from "../../helpers/MockAggregatorV3.sol";

/// @dev This is a test contract for OraclePriceOrder
/// @notice Check if the reverse order price is calculated correctly
contract OraclePriceTest is Test {
    MockAggregatorV3 oracle;

    uint256 constant PRECISION_DECIMALS = 18;
    uint8 public constant ORACLE_DEFAULT_DECIMALS = 18;
    // default price is 10
    int256 public constant ORACLE_DEFAULT_PRICE = int256(10 * 10 ** ORACLE_DEFAULT_DECIMALS);

    function setUp() public {
        oracle = new MockAggregatorV3(ORACLE_DEFAULT_DECIMALS, ORACLE_DEFAULT_PRICE);
    }

    /// @dev default price is 10, so reverse order price is 0.1
    function test_oracle_order_case1() public view {
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertEq(reverseOrderPrice, 10 ** (ORACLE_DEFAULT_DECIMALS - 1));
    }

    /// @dev default price is 0.1, so reverse order price is 10
    function test_oracle_order_case2() public {
        oracle.updateAnswer(int256(10 ** (ORACLE_DEFAULT_DECIMALS - 1)));
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertEq(reverseOrderPrice, 10 ** (ORACLE_DEFAULT_DECIMALS + 1));
    }
    /// @dev default price is 3, so reverse order price is 1/3

    function test_oracle_order_case3() public {
        oracle.updateAnswer(int256(3 * 10 ** ORACLE_DEFAULT_DECIMALS));
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertEq(reverseOrderPrice, 10 ** ORACLE_DEFAULT_DECIMALS / 3);
    }

    /// @dev default price is 1/3, so reverse order price is 3
    function test_oracle_order_case4() public {
        oracle.updateAnswer(int256(10 ** ORACLE_DEFAULT_DECIMALS / 3));
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertApproxEqRel(reverseOrderPrice, 3 * 10 ** ORACLE_DEFAULT_DECIMALS, 10);
    }

    /// @dev default price is 3000, so reverse order price is 1/3000
    function test_oracle_order_case5() public {
        oracle.updateAnswer(int256(3000 * 10 ** ORACLE_DEFAULT_DECIMALS));
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertApproxEqRel(reverseOrderPrice, 10 ** ORACLE_DEFAULT_DECIMALS / 3000, 10);
    }

    /// @dev default price is 1/3000, so reverse order price is 3000
    function test_oracle_order_case6() public {
        oracle.updateAnswer(int256(10 ** ORACLE_DEFAULT_DECIMALS / 3000));
        (, int256 answer,,,) = oracle.latestRoundData();
        uint256 price = uint256(answer);
        uint256 reverseOrderPrice = calaculate_reverse_order_price(price);
        assertApproxEqRel(reverseOrderPrice, 3000 * 10 ** ORACLE_DEFAULT_DECIMALS, 1000);
    }

    /// @dev Calculate the reverse order price copied from PriceFeed.sol
    function calaculate_reverse_order_price(uint256 price) public view returns (uint256) {
        uint8 oracleDecimals = oracle.decimals();
        return 10 ** (oracleDecimals * 2 + PRECISION_DECIMALS) / price / 10 ** PRECISION_DECIMALS;
    }
}

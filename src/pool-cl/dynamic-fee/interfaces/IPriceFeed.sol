// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

interface IPriceFeed {
    struct PriceFeedInfo {
        AggregatorV3Interface oracle;
        uint8 oracleDecimal;
        uint8 token0Decimal;
        uint8 token1Decimal;
    }

    function token0() external view returns (IERC20Metadata);

    function token1() external view returns (IERC20Metadata);

    function getPriceX96() external view returns (uint160 priceX96);
}

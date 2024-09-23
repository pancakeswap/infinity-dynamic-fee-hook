// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed {
    PriceFeedInfo public info;

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    constructor(address token0_, address token1_, address oracle_, uint32 oracleExpirationThreshold_) {
        if (token0_ > token1_) {
            (token0_, token1_) = (token1_, token0_);
        }
        token0 = IERC20Metadata(token0_);
        token1 = IERC20Metadata(token1_);
        info.oracle = AggregatorV3Interface(oracle_);
        info.oracleExpirationThreshold = oracleExpirationThreshold_;
        info.oracleDecimal = info.oracle.decimals();
        info.token0Decimal = token0.decimals();
        info.token1Decimal = token1.decimals();
    }

    /// @dev Override if the oracle base quote tokens do not match the order of
    /// token0 and token1, i.e., the price from oracle needs to be inversed, or
    /// if there is no corresponding oracle for token0 token1 pair so that
    /// combination of two oracles is required
    function getPriceX96() external view virtual returns (uint160 priceX96) {
        PriceFeedInfo memory priceFeedInfo = info;
        (, int256 answer,, uint256 updatedAt,) = priceFeedInfo.oracle.latestRoundData();
        // can not revert, we must make sure hooks can still work even if the price is not available
        if (block.timestamp - updatedAt > priceFeedInfo.oracleExpirationThreshold) {
            return 0;
        }
        priceX96 = uint160(FullMath.mulDiv(uint256(answer), FixedPoint96.Q96, 10 ** priceFeedInfo.oracleDecimal));
        priceX96 = uint160(FullMath.mulDiv(priceX96, priceFeedInfo.token0Decimal, priceFeedInfo.token1Decimal));
        // TODO: Is it better to cache the result?
    }
}

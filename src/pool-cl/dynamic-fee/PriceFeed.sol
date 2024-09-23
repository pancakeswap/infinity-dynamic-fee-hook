// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed, Ownable {
    PriceFeedInfo public info;

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    uint256 constant ORACLE_MAX_DECIMALS = 18;
    uint256 constant PRECISION_DECIMALS = 18;
    /// @dev Default order of the oracle
    uint256 constant ORACLE_DEFAULT_ORDER = 0;

    error InvalidOracleDecimals();

    /// @dev Constructor
    /// @param token0_ The first token
    /// @param token1_ The second token
    /// @param oracle_ The oracle address
    /// @param oracleExpirationThreshold_ The oracle expiration threshold
    /// @param oracleTokenOrder_ The oracle token order
    constructor(
        address token0_,
        address token1_,
        address oracle_,
        uint8 oracleTokenOrder_,
        uint32 oracleExpirationThreshold_
    ) Ownable(msg.sender) {
        if (token0_ > token1_) {
            (token0_, token1_) = (token1_, token0_);
        }
        token0 = IERC20Metadata(token0_);
        token1 = IERC20Metadata(token1_);

        info.oracle = AggregatorV3Interface(oracle_);
        uint8 oracleDecimals = info.oracle.decimals();
        if (oracleDecimals > ORACLE_MAX_DECIMALS) {
            revert InvalidOracleDecimals();
        }
        info.oracleExpirationThreshold = oracleExpirationThreshold_;
        info.oracleTokenOrder = oracleTokenOrder_;
        info.oracleDecimal = oracleDecimals;
        info.token0Decimal = token0.decimals();
        info.token1Decimal = token1.decimals();
    }

    /// @dev Update the oracle and oracle expiration threshold
    /// @param oracle_ The new oracle address
    /// @param oracleExpirationThreshold_ The new oracle expiration threshold
    function updateOracle(address oracle_, uint32 oracleExpirationThreshold_) external onlyOwner {
        info.oracle = AggregatorV3Interface(oracle_);
        info.oracleExpirationThreshold = oracleExpirationThreshold_;
        uint8 oracleDecimals = info.oracle.decimals();
        if (oracleDecimals > ORACLE_MAX_DECIMALS) {
            revert InvalidOracleDecimals();
        }
        info.oracleDecimal = oracleDecimals;
    }

    /// @dev Get the latest price
    /// @return priceX96 The latest price
    function getPriceX96() external view virtual returns (uint160 priceX96) {
        PriceFeedInfo memory priceFeedInfo = info;
        (, int256 answer,, uint256 updatedAt,) = priceFeedInfo.oracle.latestRoundData();
        // can not revert, we must make sure hooks can still work even if the price is not available
        if (answer <= 0 || block.timestamp > updatedAt + priceFeedInfo.oracleExpirationThreshold) {
            return 0;
        }
        uint256 currentPrice = uint256(answer);
        if (priceFeedInfo.oracleTokenOrder != ORACLE_DEFAULT_ORDER) {
            currentPrice =
                10 ** (priceFeedInfo.oracleDecimal * 2 + PRECISION_DECIMALS) / currentPrice / 10 ** PRECISION_DECIMALS;
        }
        priceX96 = uint160(FullMath.mulDiv(currentPrice, FixedPoint96.Q96, 10 ** priceFeedInfo.oracleDecimal));
        priceX96 = uint160(FullMath.mulDiv(priceX96, priceFeedInfo.token0Decimal, priceFeedInfo.token1Decimal));
    }
}

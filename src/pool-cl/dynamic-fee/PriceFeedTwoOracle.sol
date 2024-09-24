// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IPriceFeedTwoOracle} from "./interfaces/IPriceFeedTwoOracle.sol";

/// @title PriceFeedTwoOracle
/// @notice This contract is used to calculate the price from two oracles
/// This contract supports that two oracles must have a common currency
/// OracleA pair is A/C or C/A , OracleB pair is B/C or C/B, v4 pool pair is A/B or B/A , OracleA and OracleB must have a common currency C
/// If v4 pool is A/B, Oracle0 is OracleA, Oracle1 is OracleB
/// If v4 pool is B/A, Oracle0 is OracleB, Oracle1 is OracleA
contract PriceFeedTwoOracle is IPriceFeedTwoOracle, Ownable {
    PriceFeedInfo public info;

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    uint256 constant ORACLE_MAX_DECIMALS = 18;
    uint256 constant PRECISION_DECIMALS = 18;
    /// @dev Default target token index is 0, if index is not 0 ,need to calculate the reverse price
    uint256 constant ORACLE_DEFAULT_INDEX = 0;

    error InvalidOracleDecimals();

    /// @dev Constructor
    /// @param token0_ The first token
    /// @param token1_ The second token
    /// @param oracle0_ The oracle0 address
    /// @param oracle1_ The oracle1 address
    /// @param oracle0ExpirationThreshold_ The oracle0 expiration threshold
    /// @param oracle1ExpirationThreshold_ The oracle1 expiration threshold
    constructor(
        address token0_,
        address token1_,
        address oracle0_,
        address oracle1_,
        uint8 oracle0TargetTokenIndex_,
        uint8 oracle1TargetTokenIndex_,
        uint32 oracle0ExpirationThreshold_,
        uint32 oracle1ExpirationThreshold_
    ) Ownable(msg.sender) {
        if (token0_ > token1_) {
            (token0_, token1_) = (token1_, token0_);
        }
        token0 = IERC20Metadata(token0_);
        token1 = IERC20Metadata(token1_);
        info.oracle0 = AggregatorV3Interface(oracle0_);
        uint8 oracle0Decimals = info.oracle0.decimals();
        info.oracle1 = AggregatorV3Interface(oracle1_);
        uint8 oracle1Decimals = info.oracle1.decimals();
        if (oracle0Decimals > ORACLE_MAX_DECIMALS || oracle1Decimals > ORACLE_MAX_DECIMALS) {
            revert InvalidOracleDecimals();
        }

        info.oracle0ExpirationThreshold = oracle0ExpirationThreshold_;
        info.oracle1ExpirationThreshold = oracle1ExpirationThreshold_;
        info.oracle0Decimal = oracle0Decimals;
        info.oracle1Decimal = oracle1Decimals;
        info.oracle0TargetTokenIndex = oracle0TargetTokenIndex_;
        info.oracle1TargetTokenIndex = oracle1TargetTokenIndex_;
        info.token0Decimal = token0.decimals();
        info.token1Decimal = token1.decimals();
    }

    /// @dev Update the oracles , oracles target token index, and oracles expiration threshold
    /// @param oracle0_ The new oracle0 address
    /// @param oracle1_ The new oracle1 address
    /// @param oracle0TargetTokenIndex_ The new oracle0 target token index
    /// @param oracle1TargetTokenIndex_ The new oracle1 target token index
    /// @param oracle0ExpirationThreshold_ The new oracle0 expiration threshold
    /// @param oracle1ExpirationThreshold_ The new oracle1 expiration threshold
    function updateOracles(
        address oracle0_,
        address oracle1_,
        uint8 oracle0TargetTokenIndex_,
        uint8 oracle1TargetTokenIndex_,
        uint32 oracle0ExpirationThreshold_,
        uint32 oracle1ExpirationThreshold_
    ) external onlyOwner {
        info.oracle0 = AggregatorV3Interface(oracle0_);
        uint8 oracle0Decimals = info.oracle0.decimals();
        info.oracle1 = AggregatorV3Interface(oracle1_);
        uint8 oracle1Decimals = info.oracle1.decimals();
        if (oracle0Decimals > ORACLE_MAX_DECIMALS || oracle1Decimals > ORACLE_MAX_DECIMALS) {
            revert InvalidOracleDecimals();
        }
        info.oracle0ExpirationThreshold = oracle0ExpirationThreshold_;
        info.oracle1ExpirationThreshold = oracle1ExpirationThreshold_;
        info.oracle0Decimal = oracle0Decimals;
        info.oracle1Decimal = oracle1Decimals;
        info.oracle0TargetTokenIndex = oracle0TargetTokenIndex_;
        info.oracle1TargetTokenIndex = oracle1TargetTokenIndex_;
    }

    /// @dev Get the latest price
    /// @return priceX96 The latest price
    function getPriceX96() external view virtual returns (uint160 priceX96) {
        PriceFeedInfo memory priceFeedInfo = info;
        (, int256 oracle0Answer,, uint256 oracle0UpdatedAt,) = priceFeedInfo.oracle0.latestRoundData();
        (, int256 oracle1Answer,, uint256 oracle1UpdatedAt,) = priceFeedInfo.oracle1.latestRoundData();
        // can not revert, we must make sure hooks can still work even if the price is not available
        if (
            oracle0Answer <= 0 || oracle1Answer <= 0
                || block.timestamp > oracle0UpdatedAt + priceFeedInfo.oracle0ExpirationThreshold
                || block.timestamp > oracle1UpdatedAt + priceFeedInfo.oracle1ExpirationThreshold
        ) {
            return 0;
        }
        uint256 oracle0CurrentPrice = uint256(oracle0Answer);
        if (priceFeedInfo.oracle0TargetTokenIndex != ORACLE_DEFAULT_INDEX) {
            oracle0CurrentPrice = 10 ** (priceFeedInfo.oracle0Decimal * 2 + PRECISION_DECIMALS) / oracle0CurrentPrice
                / 10 ** PRECISION_DECIMALS;
        }
        uint256 oracle1CurrentPrice = uint256(oracle1Answer);
        if (priceFeedInfo.oracle1TargetTokenIndex != ORACLE_DEFAULT_INDEX) {
            oracle1CurrentPrice = 10 ** (priceFeedInfo.oracle1Decimal * 2 + PRECISION_DECIMALS) / oracle1CurrentPrice
                / 10 ** PRECISION_DECIMALS;
        }
        // need to calculate the price based on oracle0 and oracle1 price
        // price = (oracle0_price / oracle0_decimals)  / (oracle1_price / oracle1_decimals)
        // price = oracle0_price * oracle1_decimals / (oracle1_price * oracle0_decimals)
        // becasue oracle0 and oracle1 maybe will have different decimals,so we will calculate price based on PRECISION_DECIMALS(18)
        // price = oracle0_price * 10^18 * oracle1_decimals / (oracle1_price * oracle0_decimals)
        uint256 currentPrice = oracle0CurrentPrice * 10 ** (PRECISION_DECIMALS + priceFeedInfo.oracle1Decimal)
            / oracle1CurrentPrice / 10 ** priceFeedInfo.oracle0Decimal;

        // v4_pool_price = v4_pool_token1_amount / v4_pool_token0_amount
        // token1_real_amount = v4_pool_token1_amount / 10 ** token1Decimal
        // token0_real_amount = v4_pool_token0_amount / 10 ** token0Decimal
        // currentPrice = token1_real_amount * 10 ** oracleDecimal / token0_real_amount
        // currentPrice = v4_pool_token1_amount / 10 ** token1Decimal  * 10 ** oracleDecimal / (v4_pool_token0_amount / 10 ** token0Decimal)
        // v4_pool_price = v4_pool_token1_amount / v4_pool_token0_amount = currentPrice * 10 ** token1Decimal / 10 ** token0Decimal / 10 ** oracleDecimal
        // v4_pool_price_x96 = v4_pool_price * 2^96 = currentPrice * 2^96 / 10 ** oracleDecimal * 10 ** token1Decimal / 10 ** token0Decimal
        priceX96 = uint160(FullMath.mulDiv(currentPrice, FixedPoint96.Q96, 10 ** PRECISION_DECIMALS));
        priceX96 =
            uint160(FullMath.mulDiv(priceX96, 10 ** priceFeedInfo.token1Decimal, 10 ** priceFeedInfo.token0Decimal));
    }
}

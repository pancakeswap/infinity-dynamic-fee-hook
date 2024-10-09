// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {CLBaseHook} from "pancake-v4-hooks/src/pool-cl//CLBaseHook.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {
    SD59x18, uUNIT, UNIT, convert, inv, exp, lt, gt, uEXP_MIN_THRESHOLD, EXP_MAX_INPUT
} from "prb-math/SD59x18.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SimulationFlag} from "./libraries/SimulationFlag.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract CLDynamicFeeHook is CLBaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    struct PoolConfig {
        IPriceFeed priceFeed;
        uint24 DFF_max; // in hundredth of bips
        uint24 baseLpFee;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        ICLPoolManager.SwapParams params;
        bytes hookData;
    }

    // ============================== Variables ================================

    // will be set to true when emergency status
    // hooks will do nothing when this flag is true
    bool public emergencyFlag;

    mapping(PoolId id => PoolConfig) public poolConfigs;

    // TODO: Make it transient
    bool private _isSim;

    // ============================== Events ===================================
    event EmergencyFlagSet(bool flag);

    // ============================== Errors ===================================

    error NotDynamicFeePool();
    error PriceFeedTokensNotMatch();
    error DFFMaxTooLarge();
    error BaseLpFeeTooLarge();
    error DFFTooLarge();
    error SwapAndRevert(uint160 sqrtPriceX96);
    error NotDynamicFeeHook();
    error PriceFeedNotAvailable();

    // ============================== Modifiers ================================

    // ========================= External Functions ============================

    constructor(ICLPoolManager poolManager) Ownable(msg.sender) CLBaseHook(poolManager) {}

    /// @dev Set the emergency flag
    /// @param flag The emergency flag
    function setEmergencyFlag(bool flag) external onlyOwner {
        emergencyFlag = flag;
        emit EmergencyFlagSet(flag);
    }

    /// @dev Develpers can call this function to generate the hook data when initializing the pool
    /// @param priceFeed The price feed contract
    /// @param DFF_max The maximum dynamic fee
    /// @param baseLpFee The base LP fee
    function generateInitializeHookData(IPriceFeed priceFeed, uint24 DFF_max, uint24 baseLpFee)
        external
        pure
        returns (bytes memory)
    {
        if (DFF_max > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert DFFMaxTooLarge();
        }

        if (baseLpFee > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert BaseLpFeeTooLarge();
        }
        return abi.encode(PoolConfig({priceFeed: priceFeed, DFF_max: DFF_max, baseLpFee: baseLpFee}));
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidiyReturnsDelta: false,
                afterRemoveLiquidiyReturnsDelta: false
            })
        );
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (!key.fee.isDynamicLPFee()) {
            revert NotDynamicFeePool();
        }

        PoolConfig memory initializeHookData = abi.decode(hookData, (PoolConfig));

        IPriceFeed priceFeed = IPriceFeed(initializeHookData.priceFeed);
        if (
            address(priceFeed.token0()) != Currency.unwrap(key.currency0)
                || address(priceFeed.token1()) != Currency.unwrap(key.currency1)
        ) {
            revert PriceFeedTokensNotMatch();
        }

        uint160 priceX96Oracle = priceFeed.getPriceX96();
        if (priceX96Oracle == 0) {
            revert PriceFeedNotAvailable();
        }

        uint24 DFF_max = initializeHookData.DFF_max;
        if (DFF_max > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert DFFMaxTooLarge();
        }

        uint24 baseLpFee = initializeHookData.baseLpFee;
        if (baseLpFee > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE) {
            revert BaseLpFeeTooLarge();
        }

        poolConfigs[key.toId()] = PoolConfig({priceFeed: priceFeed, DFF_max: DFF_max, baseLpFee: baseLpFee});

        poolManager.updateDynamicLPFee(key, baseLpFee);

        return this.afterInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (emergencyFlag) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Will skip the dynamic fee calculation if the simulation flag is true
        if (SimulationFlag.getSimulationFlag()) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId id = key.toId();
        PoolConfig memory poolConfig = poolConfigs[id];

        uint160 priceX96Oracle = poolConfig.priceFeed.getPriceX96();
        // If the oracle price is not available, we will skip dynamic fee calculation
        if (priceX96Oracle == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        // Fix TODO : Can not use priceX96
        // when tick is -887272, sqrtPrice is 4295128739 , priceX96 is 4295128739 * 4295128739 / 2^96 = 0
        uint160 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));

        // when zeroForOne is true, priceX96After is smaller than priceX96Before, so we can skip the calculation when priceX96Oracle is bigger than priceX96Before
        // when zeroForOne is false, priceX96After is larger than priceX96Before, so we can skip the calculation when priceX96Oracle is smaller than priceX96Before
        // SF = max{priceX96After - priceX96Before / priceX96Oracle - priceX96Before , 0}
        // priceX96After - priceX96Before / priceX96Oracle - priceX96Before is negative in this case
        // so SF is 0, we can skip simualtion, will save some gas
        if (
            params.zeroForOne && priceX96Oracle > priceX96Before
                || !params.zeroForOne && priceX96Oracle < priceX96Before
        ) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // get the sqrt price after the swap by simulating the swap
        // NOTICE: The swap simulation uses the base LP fee, so the simulated price may differ from the actual swap price, which uses a dynamic fee.
        uint160 sqrtPriceX96After = _simulateSwap(key, params, hookData);
        uint160 priceX96After = uint160(FullMath.mulDiv(sqrtPriceX96After, sqrtPriceX96After, FixedPoint96.Q96));
        uint24 lpFee = _calculateDynamicFee(
            priceX96Oracle, priceX96Before, priceX96After, poolConfig.baseLpFee, poolConfig.DFF_max
        );
        if (lpFee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Get the dynamic fee for a swap
    /// @param key The pool key
    /// @param sqrtPriceX96AfterSwap The sqrt price after the swap
    function getDynamicFee(PoolKey calldata key, uint160 sqrtPriceX96AfterSwap) external view returns (uint24) {
        PoolId id = key.toId();
        PoolConfig memory poolConfig = poolConfigs[id];

        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(id);
        uint160 priceX96Before = uint160(FullMath.mulDiv(sqrtPriceX96Before, sqrtPriceX96Before, FixedPoint96.Q96));
        uint160 priceX96After = uint160(FullMath.mulDiv(sqrtPriceX96AfterSwap, sqrtPriceX96AfterSwap, FixedPoint96.Q96));
        uint160 priceX96Oracle = poolConfig.priceFeed.getPriceX96();
        // If the oracle price is not available, we will skip dynamic fee calculation
        if (priceX96Oracle == 0) {
            return 0;
        }

        return _calculateDynamicFee(
            priceX96Oracle, priceX96Before, priceX96After, poolConfig.baseLpFee, poolConfig.DFF_max
        );
    }

    // ========================= Internal Functions ============================

    function _calculateDynamicFee(
        uint160 priceX96Oracle,
        uint160 priceX96Before,
        uint160 priceX96After,
        uint24 baseLpFee,
        uint24 DFF_max
    ) internal pure returns (uint24) {
        // ScaledFactor(SF) = max{priceX96After - priceX96Before / priceX96Oracle - priceX96Before , 0}
        // sfX96 = SF * 2 ** 96
        uint256 sfX96;
        {
            if (priceX96After > priceX96Before && priceX96Oracle > priceX96Before) {
                sfX96 =
                    FullMath.mulDiv(priceX96After - priceX96Before, FixedPoint96.Q96, priceX96Oracle - priceX96Before);
            }
            if (priceX96After < priceX96Before && priceX96Oracle < priceX96Before) {
                sfX96 =
                    FullMath.mulDiv(priceX96Before - priceX96After, FixedPoint96.Q96, priceX96Before - priceX96Oracle);
            }
        }

        if (sfX96 == 0) {
            return 0;
        }

        // IndexPremium(IP) = ABS (priceX96Oracle/priceX96Before - -1)
        // ipX96 = IP * 2 ** 96
        uint256 ipX96;
        {
            uint256 r = FullMath.mulDiv(priceX96Oracle, FixedPoint96.Q96, priceX96Before);
            ipX96 = r > FixedPoint96.Q96 ? r - FixedPoint96.Q96 : FixedPoint96.Q96 - r;
        }

        // PriceImpactFactor(PIF) = SF * IP
        // pifX96 = PIF * 2 ** 96
        uint256 pifX96 = FullMath.mulDiv(sfX96, ipX96, FixedPoint96.Q96);

        // DFF = max{DFF_max * (1 - e ^ -(pifX96 - fX96) / fx96), 0} = max{DFF_max * (1 - 1/ e ^ (pifX96 - fX96) / fx96), 0}
        SD59x18 DFF;
        // convert(int256 x) : Converts a simple integer to SD59x18 by multiplying it by `UNIT(1e18)`.
        // SD59x18 x =  SD59x18.wrap(x_int256 * uUNIT)
        SD59x18 DFF_MAX = convert(int256(int24(DFF_max)));
        // fx: fixed fee tier
        // fX96 = fx * 2 ** 96
        uint256 fX96 = FullMath.mulDiv(baseLpFee, FixedPoint96.Q96, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE);
        if (pifX96 > fX96) {
            // inv(SD59x18 x) : 1/x, Calculates the inverse of x.
            // exp(SD59x18 x) : e^x, Calculates the natural exponent of x.
            // exponent_uint256 = (pifX96 - fX96) / fx96
            // exponent_SD59x18_int256 =  int256( (pifX96 - fX96) * uUNIT / fx96 )
            // exponent = SD59x18.wrap(exponent_SD59x18_int256)
            SD59x18 exponent = SD59x18.wrap(int256(FullMath.mulDiv(pifX96 - fX96, uint256(uUNIT), fX96)));
            // when exponent > EXP_MAX_INPUT, inter(1/e^exponent) will be almost equal to 0, so DFF will be be almost equal to DFF_MAX
            if (gt(exponent, EXP_MAX_INPUT)) {
                DFF = DFF_MAX;
            } else {
                SD59x18 inter = inv(exp(exponent));
                if (inter < UNIT) {
                    DFF = DFF_MAX * (UNIT - inter);
                }
            }
        }

        if (DFF.isZero()) {
            return 0;
        }

        // Will return DFF_MAX if DFF > DFF_MAX
        if (DFF > DFF_MAX) {
            DFF = DFF_MAX;
        }

        // convert(SD59x18 x) : Converts an SD59x18 number to a simple integer by dividing it by `UNIT(1e18)`.
        uint24 DFF_uint24 = uint24(int24(convert(DFF)));
        // LPFee = DFF_uint24 * PIF = DFF_uint24 * pifX96 / 2 ** 96
        uint24 lpFee = uint24(FullMath.mulDiv(DFF_uint24, pifX96, FixedPoint96.Q96));
        // TODO : Need to add one more parameter about max dynamic fee
        // DF_max : dynamic fee max
        // if (lpFee > DF_max) {lpFee = DF_max;}
        if (lpFee < baseLpFee) {
            return 0;
        }
        return lpFee;
    }

    /// @dev The swap simulation uses the base LP fee, so the simulated price may differ from the actual swap price, which uses a dynamic fee.
    function _simulateSwap(PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata hookData)
        internal
        returns (uint160 sqrtPriceX96)
    {
        SimulationFlag.setSimulationFlag(true);
        try this.simulateSwap(key, params, hookData) {
            revert();
        } catch (bytes memory reason) {
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 0x20))
            }
            if (selector != SwapAndRevert.selector) {
                revert();
            }
            // Extract data by trimming the custom error selector (first 4 bytes)
            bytes memory data = new bytes(reason.length - 4);
            for (uint256 i = 4; i < reason.length; ++i) {
                data[i - 4] = reason[i];
            }
            sqrtPriceX96 = abi.decode(data, (uint160));
        }
        SimulationFlag.setSimulationFlag(false);
    }

    /// @dev Revert a custom error on purpose to achieve simulation of `swap`
    function simulateSwap(PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
    {
        // Only this contract can call this function
        if (msg.sender != address(this)) {
            revert NotDynamicFeeHook();
        }
        poolManager.swap(key, params, hookData);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        revert SwapAndRevert(sqrtPriceX96);
    }
}

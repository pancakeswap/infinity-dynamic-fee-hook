// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {TokenFixture} from "pancake-v4-periphery/test/helpers/TokenFixture.sol";
import {MockV4Router} from "pancake-v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "pancake-v4-periphery/src/interfaces/IV4Router.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {PathKey} from "pancake-v4-periphery/src/libraries/PathKey.sol";
import {Plan, Planner} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "pancake-v4-periphery/src/libraries/ActionConstants.sol";
import {LPFeeLibrary} from "pancake-v4-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PosmTestSetup} from "pancake-v4-periphery/test/pool-cl/shared/PosmTestSetup.sol";
import {CLLiquidityOperations} from "pancake-v4-periphery/test/pool-cl/shared/CLLiquidityOperations.sol";
import {CLDynamicFeeHook} from "../../../src/pool-cl/dynamic-fee/CLDynamicFeeHook.sol";
import {IPriceFeed} from "../../../src/pool-cl/dynamic-fee/interfaces/IPriceFeed.sol";
import {PriceFeed} from "../../../src/pool-cl/dynamic-fee/PriceFeed.sol";
import {MockAggregatorV3} from "../../helpers/MockAggregatorV3.sol";
// import "forge-std/console2.sol";

contract CLDynamicFeeHookTest is Test, PosmTestSetup {
    using Planner for Plan;
    using CurrencyLibrary for Currency;

    MockAggregatorV3 defaultOracle;
    PriceFeed priceFeed;
    CLDynamicFeeHook dynamicFeeHook;

    IVault public vault;
    ICLPoolManager public poolManager;

    MockV4Router public v4Router;

    PoolId poolId;
    PoolId poolId1;
    PoolKey key;
    PoolKey key1;
    Plan planner;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    // 0.25% fee
    uint24 DEFAULT_FEE = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 400;
    // MAX DFF 25%
    uint24 MAX_DFF = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE / 4;

    // v4 swap event
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee,
        uint16 protocolFee
    );

    function setUp() public {
        planner = Planner.init();
        (currency0, currency1) = deployCurrencies(10 ** 30);
        (vault, poolManager) = createFreshManager();

        defaultOracle = new MockAggregatorV3(18, 10 ** 18);
        priceFeed =
            new PriceFeed(Currency.unwrap(currency0), Currency.unwrap(currency1), address(defaultOracle), 0, 3600 * 24);
        dynamicFeeHook = new CLDynamicFeeHook(ICLPoolManager(address(poolManager)));

        deployAndApprovePosm(vault, poolManager);

        seedBalance(address(this));
        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: dynamicFeeHook,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(dynamicFeeHook.getHooksRegistrationBitmap())), 10
            )
        });
        poolId = key.toId();
        bytes memory initializeHookData = dynamicFeeHook.generateInitializeHookData(priceFeed, MAX_DFF, DEFAULT_FEE);
        poolManager.initialize(key, SQRT_RATIO_1_1, initializeHookData);

        // mint position
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                -300,
                300,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory pool0_callData_0 = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(pool0_callData_0, block.timestamp + 1);

        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                -9000,
                -6000,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory pool0_callData_1 = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(pool0_callData_1, block.timestamp + 1);

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: DEFAULT_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(0), 10)
        });
        poolId1 = key1.toId();
        poolManager.initialize(key1, SQRT_RATIO_1_1, ZERO_BYTES);

        // mint position
        planner = Planner.init().add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key1,
                -300,
                300,
                10_000 ether,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory pool1_callData_0 = planner.finalizeModifyLiquidityWithClose(key1);
        lpm.modifyLiquidities(pool1_callData_0, block.timestamp + 1);

        v4Router = new MockV4Router(vault, poolManager, IBinPoolManager(address(0)));
        IERC20(Currency.unwrap(currency0)).approve(address(v4Router), 10000000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(v4Router), 10000000 ether);
    }

    function test_dynamic_fee_hook_initialization() public view {
        (IPriceFeed priceFeedContract, uint24 hook_DFF_max, uint24 baseLpFee) = dynamicFeeHook.poolConfigs(poolId);
        assertEq(address(priceFeedContract), address(priceFeed));
        assertEq(hook_DFF_max, MAX_DFF);
        assertEq(baseLpFee, DEFAULT_FEE);
    }

    function test_simulate_swap_not_from_hooks_revert() public {
        ICLPoolManager.SwapParams memory params =
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});
        vm.expectRevert(CLDynamicFeeHook.NotDynamicFeeHook.selector);
        dynamicFeeHook.simulateSwap(key, params, ZERO_BYTES);
    }

    function test_swap_no_dynamic_fee() external {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, 1 ether, 0, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96AfterSwap = 79220260293300080910473130642;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96AfterSwap);
        assertEq(dynamic_fee, 0);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            poolId,
            address(v4Router),
            -1 ether,
            997400509299197405,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -2,
            DEFAULT_FEE,
            0
        );
        v4Router.executeActions(data);
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);
    }

    function test_swap_with_dynamic_fee() external {
        // set oracle price to 0.8
        defaultOracle.updateAnswer(80 * 10 ** 16);
        uint160 priceX96Oracle = priceFeed.getPriceX96();
        assertEq(uint256(priceX96Oracle), 8 * FixedPoint96.Q96 / 10);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        assertGt(liquidity, 0);

        uint128 swap_amount = 170 ether;
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, true, swap_amount, 0, 0, bytes(""));

        planner = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = planner.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        uint160 sqrtPriceX96BySimulation = 58614422236967949585661808030;
        uint160 sqrtPriceX96AfterSwap = 78051446342915679598492659642;
        uint24 dynamic_fee = dynamicFeeHook.getDynamicFee(key, sqrtPriceX96BySimulation);
        assertGt(dynamic_fee, 0);
        /*
        Manual verification of dynamic fee calculation process

        price_oracle = 0.8
        price_before = 1 // tick = 0
        price_after = 1.0001 ^ -6028 = 0.5472936069292484 // tick = - 6028
        SF = price_after - price_before / price_oracle - price_before = 2.2635319653537582
        IP = 1 - price_oracle / price_before = 0.2
        PIF = SF * IP = 0.45270639307065164
        DFF_MAX = 0.25
        F = 0.0025
        DFF = DFF_MAX * (1 - e^ -(PIF - F) / F) = 0.25
        dynamic_fee = DFF * PIF = 0.113167
        */
        assertEq(dynamic_fee, 113167); // 11.3167%

        vm.expectEmit(true, true, true, true);
        emit Swap(
            poolId,
            address(v4Router),
            -170 ether,
            148522461458928893119,
            sqrtPriceX96AfterSwap,
            10000000000000000000000,
            -300,
            dynamic_fee,
            0
        );
        v4Router.executeActions(data);
        (uint256 feeGrowthGlobal0x128, uint256 feeGrowthGlobal1x128) = poolManager.getFeeGrowthGlobals(poolId);
        // charge tokenIn fee
        assertGt(feeGrowthGlobal0x128, 0);
        assertEq(feeGrowthGlobal1x128, 0);

        // dynamic_fee_amount = tokenInAmount * dynamic_fee / 1_000_000 - 1;
        // -1 is for calculation precision loss
        uint256 dynamic_fee_curreny0_amount = swap_amount * dynamic_fee / LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE - 1;
        assertEq(dynamic_fee_curreny0_amount, 19238389999999999999);
        uint256 currency0_balance_before = currency0.balanceOfSelf();
        // collect fees
        bytes memory collect_calldata = CLLiquidityOperations.getCollectEncoded(1, ZERO_BYTES);
        lpm.modifyLiquidities(collect_calldata, block.timestamp + 1);

        uint256 currency0_balance_after = currency0.balanceOfSelf();
        assertEq(currency0_balance_after - currency0_balance_before, dynamic_fee_curreny0_amount);
    }

    receive() external payable {}
}

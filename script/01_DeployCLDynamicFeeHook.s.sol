// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {CLDynamicFeeHook} from "../src/pool-cl/dynamic-fee/CLDynamicFeeHook.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * Step 1: Deploy
 * forge script script/01_DeployCLDynamicFeeHook.s.sol:DeployCLDynamicFeeHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Do not verify this contract as we do not want to open-source this yet.
 */
contract DeployCLDynamicFeeHookScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-DYNAMIC-FEE-HOOK/CLDynamicFeeHook/xx");
    }

    struct PoolConfig {
        uint24 alpha;
        uint24 DFF_max;
        uint24 baseLpFee;
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        console.log("clPoolManager ", clPoolManager);

        // alpha: 500_000 means latest data point is worth 50%
        // dff_max 250_000 means max dynamic fee is 2.5% - set as 200_000 to be max at 2%
        // baseLpFee: 3_000 means at least 0.3% for swap fee in this pool
        PoolConfig memory poolConfig = PoolConfig({
            alpha: getUint24FromConfig("clDynamicFeeHook_alpha"),
            DFF_max: getUint24FromConfig("clDynamicFeeHook_dff_max"),
            baseLpFee: getUint24FromConfig("clDynamicFeeHook_baseLpFee")
        });
        console.log("poolConfig.alpha", poolConfig.alpha);
        console.log("poolConfig.DFF_max", poolConfig.DFF_max);
        console.log("poolConfig.baseLpFee", poolConfig.baseLpFee);

        /// @dev prepare the payload to transfer ownership from deployer to real owner
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, getAddressFromConfig("owner"));

        bytes memory creationCode =
            abi.encodePacked(type(CLDynamicFeeHook).creationCode, abi.encode(clPoolManager, poolConfig));

        address CLDynamicFeeHook = factory.deploy(
            getDeploymentSalt(), creationCode, keccak256(creationCode), 0, afterDeploymentExecutionPayload, 0
        );

        console.log("CLDynamicFeeHook contract deployed at ", CLDynamicFeeHook);

        vm.stopBroadcast();
    }
}

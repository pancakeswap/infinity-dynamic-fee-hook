// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CLDynamicFeeHook} from "../../src/pool-cl/dynamic-fee/CLDynamicFeeHook.sol";

contract CLDynamicFeeHookTest is Test {
    CLDynamicFeeHook hook;
    CLPoolManager poolManager;
    Vault vault;

    function setUp() public {
        vault = new Vault();
        poolManager = new CLPoolManager(IVault(address(vault)));
        hook = new CLDynamicFeeHook(ICLPoolManager(address(poolManager)));
    }

    function test_hook() public {}
}

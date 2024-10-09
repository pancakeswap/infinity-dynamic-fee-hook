// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library SimulationFlag {
    /// @dev uint256 internal constant DYNAMIC_FEE_SIMULATION_FLAG_SLOT = uint256(keccak256("DYNAMIC_FEE_SIMULATION_FLAG_SLOT")) - 1;
    uint256 internal constant DYNAMIC_FEE_SIMULATION_FLAG_SLOT =
        0x3475d03ff636ef3544b383162d3fd05f4a2fe01c9be83d7a102babb4fb442357;

    function setSimulationFlag(bool flag) internal {
        assembly ("memory-safe") {
            sstore(DYNAMIC_FEE_SIMULATION_FLAG_SLOT, flag)
        }
    }

    function getSimulationFlag() internal view returns (bool flag) {
        assembly ("memory-safe") {
            flag := sload(DYNAMIC_FEE_SIMULATION_FLAG_SLOT)
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ZkProtocolUpgradeDeploymentChecks} from "script/ZkProtocolUpgradeDeploymentChecks.sol";

/// @title CheckZkProtocolUpgradeDeployment
/// @author [ScopeLift](https://scopelift.co)
/// @notice Runs `ZkProtocolUpgradeDeploymentChecks` against an existing deployment, e.g. to verify a mainnet deployment
/// independently of the deploy script. It reverts with a message naming the first failed check.
/// @dev Reads the deployed addresses and the deployer from the environment:
/// `COUNCIL_TOKEN`, `COUNCIL_GOVERNOR`, `VETO_GOVERNOR`, `SUPERMAJORITY_GOVERNOR`, `OVERRIDE_TIMELOCK` and `DEPLOYER`.
///
/// Usage: `forge script script/CheckZkProtocolUpgradeDeployment.s.sol --zksync --rpc-url <era-rpc>`
contract CheckZkProtocolUpgradeDeployment is Script, ZkProtocolUpgradeDeploymentChecks {
  /// @notice Checks the deployment named by the environment.
  function run() public view {
    _checkDeployment(_deploymentFromEnv(), vm.envAddress("DEPLOYER"));
    console2.log("All deployment checks passed");
  }
}

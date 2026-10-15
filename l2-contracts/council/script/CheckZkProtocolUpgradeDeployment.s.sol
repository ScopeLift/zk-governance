// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {ZkSupermajorityGovernor} from "src/ZkSupermajorityGovernor.sol";
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
    Deployment memory _deployment = Deployment({
      councilToken: CouncilERC20(vm.envAddress("COUNCIL_TOKEN")),
      councilGovernor: ZkProtocolUpgradeCouncilGovernor(payable(vm.envAddress("COUNCIL_GOVERNOR"))),
      vetoGovernor: ZkProtocolUpgradeVetoGovernor(payable(vm.envAddress("VETO_GOVERNOR"))),
      supermajorityGovernor: ZkSupermajorityGovernor(payable(vm.envAddress("SUPERMAJORITY_GOVERNOR"))),
      overrideTimelock: TimelockController(payable(vm.envAddress("OVERRIDE_TIMELOCK")))
    });
    _checkDeployment(_deployment, vm.envAddress("DEPLOYER"));
    console2.log("All deployment checks passed");
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployZkProtocolUpgradeGovernance} from "script/DeployZkProtocolUpgradeGovernance.s.sol";
import {DeployZkProtocolUpgradeGovernanceEraMainnet} from "script/DeployZkProtocolUpgradeGovernanceEraMainnet.s.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/configs/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/configs/ZkProtocolUpgradeEraMainnetConfig.sol";

// The Era mainnet deploy script with everything a test varies passed to its constructor: the params, the Supermajority
// Governor and override timelock, which the script otherwise reads from the environment, and the Supermajority
// Governor's deployer. Environment variables are shared by tests running in parallel, so only
// `DeployZkProtocolUpgradeGovernanceEraMainnetEnvDeployerHarness` reads the deployer from them.
contract DeployZkProtocolUpgradeGovernanceEraMainnetHarness is DeployZkProtocolUpgradeGovernanceEraMainnet {
  DeploymentParams internal params;
  address public supermajorityGovernor;
  TimelockController public overrideTimelock;
  // When zero, the Supermajority Governor shares the council deployer.
  address internal supermajorityGovernorDeployer;

  constructor(
    DeploymentParams memory _params,
    address _supermajorityGovernor,
    TimelockController _overrideTimelock,
    address _supermajorityGovernorDeployer
  ) {
    params = _params;
    supermajorityGovernor = _supermajorityGovernor;
    overrideTimelock = _overrideTimelock;
    supermajorityGovernorDeployer = _supermajorityGovernorDeployer;
  }

  function _supermajorityGovernorContracts() internal view override returns (address, TimelockController) {
    return (supermajorityGovernor, overrideTimelock);
  }

  function _supermajorityGovernorDeployer(address _default) internal view virtual override returns (address) {
    return supermajorityGovernorDeployer != address(0) ? supermajorityGovernorDeployer : _default;
  }

  function _deploymentParams()
    internal
    view
    override(ZkProtocolUpgradeDeploymentConfig, ZkProtocolUpgradeEraMainnetConfig)
    returns (DeploymentParams memory)
  {
    return params;
  }
}

// Reads the Supermajority Governor's deployer from `SUPERMAJORITY_GOVERNOR_DEPLOYER`, as the script does in production.
contract DeployZkProtocolUpgradeGovernanceEraMainnetEnvDeployerHarness is
  DeployZkProtocolUpgradeGovernanceEraMainnetHarness
{
  constructor(DeploymentParams memory _params, address _supermajorityGovernor, TimelockController _overrideTimelock)
    DeployZkProtocolUpgradeGovernanceEraMainnetHarness(_params, _supermajorityGovernor, _overrideTimelock, address(0))
  {}

  function _supermajorityGovernorDeployer(address _default) internal view override returns (address) {
    return DeployZkProtocolUpgradeGovernance._supermajorityGovernorDeployer(_default);
  }
}

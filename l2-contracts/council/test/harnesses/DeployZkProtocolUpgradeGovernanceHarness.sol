// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployZkProtocolUpgradeGovernanceEraMainnet} from "script/DeployZkProtocolUpgradeGovernanceEraMainnet.s.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/configs/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/configs/ZkProtocolUpgradeEraMainnetConfig.sol";

// The Era mainnet deploy script with the inputs a test varies set directly: the Supermajority Governor, its override
// timelock and its deployer, which the script otherwise reads from the environment, and changes to the mainnet params.
// Environment variables are shared by tests running in parallel, so only a test that reads an existing deployment the
// way the script does should switch back to them.
contract DeployZkProtocolUpgradeGovernanceEraMainnetHarness is DeployZkProtocolUpgradeGovernanceEraMainnet {
  address internal supermajorityGovernor;
  TimelockController internal overrideTimelock;
  // When set, the account that deployed the Supermajority Governor; otherwise it shares the council deployer.
  address internal supermajorityGovernorDeployer;
  // When set, the Supermajority Governor's deployer is read from `SUPERMAJORITY_GOVERNOR_DEPLOYER`, as in production.
  bool internal readSupermajorityGovernorDeployerFromEnv;
  // When set, the params' veto override window is cut to exactly a supermajority override's length, which leaves no
  // time to queue and execute it.
  bool internal shortenVetoOverrideWindow;
  // When set, the params leave the Veto Governor without a veto guardian.
  bool internal omitVetoGuardian;
  // When set, the params' Protocol Timelock is an account with no code.
  bool internal useCodelessProtocolTimelock;

  function setSupermajorityGovernorContracts(address _supermajorityGovernor, TimelockController _overrideTimelock)
    external
  {
    supermajorityGovernor = _supermajorityGovernor;
    overrideTimelock = _overrideTimelock;
  }

  function setSupermajorityGovernorDeployer(address _deployer) external {
    supermajorityGovernorDeployer = _deployer;
  }

  function setReadSupermajorityGovernorDeployerFromEnv(bool _readFromEnv) external {
    readSupermajorityGovernorDeployerFromEnv = _readFromEnv;
  }

  function setShortenVetoOverrideWindow(bool _shorten) external {
    shortenVetoOverrideWindow = _shorten;
  }

  function setOmitVetoGuardian(bool _omit) external {
    omitVetoGuardian = _omit;
  }

  function setUseCodelessProtocolTimelock(bool _useCodeless) external {
    useCodelessProtocolTimelock = _useCodeless;
  }

  function deploymentParams() external view returns (DeploymentParams memory) {
    return _deploymentParams();
  }

  function _supermajorityGovernorContracts() internal view override returns (address, TimelockController) {
    return (supermajorityGovernor, overrideTimelock);
  }

  function _supermajorityGovernorDeployer(address _default) internal view override returns (address) {
    if (readSupermajorityGovernorDeployerFromEnv) {
      return super._supermajorityGovernorDeployer(_default);
    }
    return supermajorityGovernorDeployer != address(0) ? supermajorityGovernorDeployer : _default;
  }

  function _deploymentParams()
    internal
    view
    override(ZkProtocolUpgradeDeploymentConfig, ZkProtocolUpgradeEraMainnetConfig)
    returns (DeploymentParams memory _params)
  {
    _params = ZkProtocolUpgradeEraMainnetConfig._deploymentParams();
    if (useCodelessProtocolTimelock) {
      _params.protocolTimelock = vm.addr(uint256(keccak256("Account Without Code")));
    }
    if (shortenVetoOverrideWindow) {
      _params.vetoGovernorVetoOverrideDuration = 12 days;
    }
    if (omitVetoGuardian) {
      _params.vetoGovernorVetoGuardian = address(0);
    }
  }
}

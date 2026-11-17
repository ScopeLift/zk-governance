// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
  ProposeProtocolTimelockRoleMigrationEraMainnet
} from "script/ProposeProtocolTimelockRoleMigrationEraMainnet.s.sol";

/// @notice The Era mainnet role migration script, with its proposal and its before and after checks exposed, so a test
/// can pass the migration through the live `ZkProtocolGovernor` itself instead of simulating it as `run` does.
/// @dev The deployment the checks validate and its deployer are passed to the constructor rather than read from the
/// environment, which tests running in parallel share.
contract ProtocolTimelockRoleMigrationEraMainnetHarness is ProposeProtocolTimelockRoleMigrationEraMainnet {
  Deployment internal deployment;
  address internal deployer;

  constructor(Deployment memory _deployment, address _deployer) {
    deployment = _deployment;
    deployer = _deployer;
  }

  // forge-lint: disable-start(mixed-case-function)
  function exposed__protocolGovernor() external view returns (address) {
    return _protocolGovernor();
  }

  function exposed__migrationProposal() external view returns (Proposal memory) {
    return _migrationProposal(address(deployment.vetoGovernor));
  }

  function exposed__checkBeforeMigration() external view {
    _checkBeforeMigration(address(deployment.vetoGovernor));
  }

  function exposed__checkAfterMigration() external view {
    _checkAfterMigration(address(deployment.vetoGovernor));
  }

  // forge-lint: disable-end(mixed-case-function)

  // The checks read these: the Veto Governor that receives the roles, and the deployment that `_checkBeforeMigration`
  // validates in full. Both Supermajority Governor and council contracts share one deployer, as on mainnet.
  function _deployedVetoGovernor() internal view override returns (address) {
    return address(deployment.vetoGovernor);
  }

  function _validateExistingDeployment() internal view override {
    _validateDeployment(_deploymentParams(), deployment, deployer, deployer);
  }
}

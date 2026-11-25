// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
  ProposeProtocolTimelockRoleMigrationEraMainnet
} from "script/ProposeProtocolTimelockRoleMigrationEraMainnet.s.sol";

/// @notice The Era mainnet role migration script, given the Veto Governor directly rather than through `VETO_GOVERNOR`,
/// so tests running in parallel don't share it. A test can also call the script's proposal and its before and after
/// checks itself, to pass the migration through the live `ZkProtocolGovernor` instead of simulating it as `run` does.
/// @dev The deployment checks the script runs first are covered by `DeployZkProtocolUpgradeGovernance.t.sol`, so they
/// are skipped here, where no council governance is deployed. The smoke tests run them when they deploy the council
/// governance.
contract ProposeProtocolTimelockRoleMigrationEraMainnetHarness is ProposeProtocolTimelockRoleMigrationEraMainnet {
  address internal immutable VETO_GOVERNOR;

  constructor(address _vetoGovernor) {
    VETO_GOVERNOR = _vetoGovernor;
  }

  // forge-lint: disable-start(mixed-case-function)
  function exposed__protocolGovernor() external view returns (address) {
    return _protocolGovernor();
  }

  function exposed__migrationProposal() external view returns (Proposal memory) {
    return _migrationProposal(VETO_GOVERNOR);
  }

  function exposed__checkBeforeMigration() external view {
    _checkBeforeMigration(VETO_GOVERNOR);
  }

  function exposed__checkAfterMigration() external view {
    _checkAfterMigration(VETO_GOVERNOR);
  }

  // forge-lint: disable-end(mixed-case-function)

  // The script reads these: the Veto Governor that receives the roles, from the constructor, and the deployment checks,
  // which do nothing here.
  function _deployedVetoGovernor() internal view override returns (address) {
    return VETO_GOVERNOR;
  }

  function _validateExistingDeployment() internal view override {}
}

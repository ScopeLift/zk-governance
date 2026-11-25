// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {
  ProposeProtocolTimelockRoleMigrationEraMainnet
} from "script/ProposeProtocolTimelockRoleMigrationEraMainnet.s.sol";

/// @notice The Era mainnet role migration script, given the Veto Governor directly rather than through `VETO_GOVERNOR`,
/// so tests running in parallel don't share it.
/// @dev The deployment checks the script runs first are covered by `DeployZkProtocolUpgradeGovernance.t.sol`, so they
/// are skipped here, where no council governance is deployed.
contract ProposeProtocolTimelockRoleMigrationEraMainnetHarness is ProposeProtocolTimelockRoleMigrationEraMainnet {
  address internal immutable VETO_GOVERNOR;

  constructor(address _vetoGovernor) {
    VETO_GOVERNOR = _vetoGovernor;
  }

  // The script reads these: the Veto Governor that receives the roles, from the constructor, and the deployment checks,
  // which do nothing here.
  function _deployedVetoGovernor() internal view override returns (address) {
    return VETO_GOVERNOR;
  }

  function _validateExistingDeployment() internal view virtual override {}
}

/// @notice The Era mainnet role migration script run against a deployed council governance, with the vote on
/// `ZkProtocolGovernor` in place of the simulated execution. `run` checks the deployment and the starting state as on
/// mainnet and proposes the migration from the broadcaster. The voter then votes FOR once voting starts, the proposal
/// is queued and executed once voting ends, and `run` checks the roles the execution left.
/// @dev The deployment comes from the constructor rather than the environment, for the same reason as the Veto
/// Governor. The voter must already hold `ZkProtocolGovernor`'s quorum when the proposal is made.
contract ProposeProtocolTimelockRoleMigrationEraMainnetVoteHarness is
  ProposeProtocolTimelockRoleMigrationEraMainnetHarness
{
  Deployment internal deployment;
  address internal immutable DEPLOYER;
  address internal immutable VOTER;

  constructor(Deployment memory _deployment, address _deployer, address _voter)
    ProposeProtocolTimelockRoleMigrationEraMainnetHarness(address(_deployment.vetoGovernor))
  {
    deployment = _deployment;
    DEPLOYER = _deployer;
    VOTER = _voter;
  }

  // forge-lint: disable-start(mixed-case-function)
  function exposed__protocolGovernor() external view returns (address) {
    return _protocolGovernor();
  }

  // forge-lint: disable-end(mixed-case-function)

  // The script reads these: the deployment checks, run against the deployment from the constructor, and the step after
  // the proposal, which passes it through `ZkProtocolGovernor` with the voter's votes. Both deploy scripts ran from the
  // deployer, so it is also the Supermajority Governor's deployer.
  function _validateExistingDeployment() internal view override {
    _validateDeployment(_deploymentParams(), deployment, DEPLOYER, DEPLOYER);
  }

  function _simulateMigration(Proposal memory _proposal) internal override {
    IGovernor _governor = IGovernor(_protocolGovernor());
    uint256 _proposalId = _hashProposal(_proposal);
    vm.warp(_governor.proposalSnapshot(_proposalId) + 1);
    vm.prank(VOTER);
    _governor.castVote(_proposalId, 1);
    vm.warp(_governor.proposalDeadline(_proposalId) + 1);
    bytes32 _descriptionHash = keccak256(bytes(_proposal.description));
    _governor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash);
    // `run` checked that the Protocol Timelock's minimum delay is 0, so the queued proposal can execute at once.
    _governor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash);
  }
}

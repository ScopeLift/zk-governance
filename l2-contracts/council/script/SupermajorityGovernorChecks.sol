// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "./DeployBase.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "./ZkProtocolUpgradeDeploymentConfig.sol";

// The parts of `ZkProtocolGovernor` the checks read. Step 1 deploys it as the Supermajority Governor; the council
// project cannot import it, since it is built on OpenZeppelin v4.
interface IZkProtocolGovernor {
  function name() external view returns (string memory);
  function token() external view returns (address);
  function timelock() external view returns (address);
  function clock() external view returns (uint48);
  function votingDelay() external view returns (uint256);
  function votingPeriod() external view returns (uint256);
  function proposalThreshold() external view returns (uint256);
  function quorum(uint256 _timepoint) external view returns (uint256);
  function lateQuorumVoteExtension() external view returns (uint64);
}

// The parts of an OpenZeppelin `TimelockController` the checks read, the same in v4 and v5.
interface ITimelockRoles {
  function PROPOSER_ROLE() external view returns (bytes32);
  function EXECUTOR_ROLE() external view returns (bytes32);
  function CANCELLER_ROLE() external view returns (bytes32);
  function getMinDelay() external view returns (uint256);
  function hasRole(bytes32 _role, address _account) external view returns (bool);
}

// Checks the contracts step 1 deploys, the Supermajority Governor and its override timelock, against the params. Step 1
// runs these checks after deploying, and step 2 runs them before deploying anything. They use only interfaces, so both
// l2-contracts projects compile the same checks.
abstract contract SupermajorityGovernorChecks is DeployBase, ZkProtocolUpgradeDeploymentConfig {
  // Runs every check of the Supermajority Governor and override timelock deployed by `_deployer`.
  function _validateStepOneContracts(
    DeploymentParams memory _params,
    address _supermajorityGovernor,
    address _overrideTimelock,
    address _deployer
  ) internal view {
    if (_supermajorityGovernor.code.length == 0 || _overrideTimelock.code.length == 0) {
      revert("SupermajorityGovernorChecks: the Supermajority Governor or override timelock is not deployed");
    }
    _validateSupermajorityGovernor(_params, IZkProtocolGovernor(_supermajorityGovernor), _overrideTimelock);
    _validateOverrideTimelock(_params, ITimelockRoles(_overrideTimelock), _supermajorityGovernor, _deployer);
  }

  function _validateSupermajorityGovernor(
    DeploymentParams memory _params,
    IZkProtocolGovernor _governor,
    address _overrideTimelock
  ) internal view {
    if (!_eq(_governor.name(), _params.supermajorityGovernorName)) {
      revert("SupermajorityGovernorChecks: Supermajority Governor name does not match the params");
    }
    if (_governor.token() != _params.zkToken) {
      revert("SupermajorityGovernorChecks: Supermajority Governor token is not the ZK token");
    }
    if (_governor.timelock() != _overrideTimelock) {
      revert("SupermajorityGovernorChecks: the Supermajority Governor's timelock is not the override timelock");
    }
    if (_governor.votingDelay() != _params.supermajorityGovernorVotingDelay) {
      revert("SupermajorityGovernorChecks: Supermajority Governor voting delay does not match the params");
    }
    if (_governor.votingPeriod() != _params.supermajorityGovernorVotingPeriod) {
      revert("SupermajorityGovernorChecks: Supermajority Governor voting period does not match the params");
    }
    if (_governor.proposalThreshold() != _params.supermajorityGovernorProposalThreshold) {
      revert("SupermajorityGovernorChecks: Supermajority Governor proposal threshold does not match the params");
    }
    if (_governor.quorum(_governor.clock()) != _params.supermajorityGovernorQuorum) {
      revert("SupermajorityGovernorChecks: Supermajority Governor quorum does not match the params");
    }
    if (_governor.lateQuorumVoteExtension() != _params.supermajorityGovernorLateQuorumVoteExtension) {
      revert("SupermajorityGovernorChecks: Supermajority Governor late-quorum extension does not match the params");
    }
  }

  // Checks that the override timelock has the configured delay, that the Supermajority Governor is its proposer and
  // canceller, that anyone can execute, that it administers itself, and that `_deployer` holds no role on it.
  function _validateOverrideTimelock(
    DeploymentParams memory _params,
    ITimelockRoles _timelock,
    address _supermajorityGovernor,
    address _deployer
  ) internal view {
    if (_timelock.getMinDelay() != _params.overrideTimelockMinDelay) {
      revert("SupermajorityGovernorChecks: override timelock delay does not match the params");
    }
    if (!_timelock.hasRole(_timelock.PROPOSER_ROLE(), _supermajorityGovernor)) {
      revert("SupermajorityGovernorChecks: the Supermajority Governor is not the override timelock's proposer");
    }
    if (!_timelock.hasRole(_timelock.CANCELLER_ROLE(), _supermajorityGovernor)) {
      revert("SupermajorityGovernorChecks: the Supermajority Governor is not the override timelock's canceller");
    }
    if (!_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0))) {
      revert("SupermajorityGovernorChecks: override timelock execution is not open to everyone");
    }
    if (!_timelock.hasRole(TIMELOCK_ADMIN_ROLE, address(_timelock))) {
      revert("SupermajorityGovernorChecks: the override timelock does not administer itself");
    }
    if (
      _timelock.hasRole(TIMELOCK_ADMIN_ROLE, _deployer) || _timelock.hasRole(_timelock.PROPOSER_ROLE(), _deployer)
        || _timelock.hasRole(_timelock.CANCELLER_ROLE(), _deployer)
        || _timelock.hasRole(_timelock.EXECUTOR_ROLE(), _deployer)
    ) {
      revert("SupermajorityGovernorChecks: the deployer holds a role on the override timelock");
    }
  }
}

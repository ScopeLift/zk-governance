// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {ZkSupermajorityGovernor} from "src/ZkSupermajorityGovernor.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/ZkProtocolUpgradeDeploymentConfig.sol";

/// @title ZkProtocolUpgradeDeploymentChecks
/// @author [ScopeLift](https://scopelift.co)
/// @notice Checks that a deployment of the ZKsync protocol upgrade council governance contracts matches the ZIP
/// parameters in `ZkProtocolUpgradeDeploymentConfig`: every parameter, every role and every cross-contract reference.
/// It also checks that the deployer kept no privileges. Each failed check reverts with a message naming it.
abstract contract ZkProtocolUpgradeDeploymentChecks is ZkProtocolUpgradeDeploymentConfig {
  /// @notice The contracts deployed by `DeployZkProtocolUpgradeGovernance`.
  struct Deployment {
    CouncilERC20 councilToken;
    ZkProtocolUpgradeCouncilGovernor councilGovernor;
    ZkProtocolUpgradeVetoGovernor vetoGovernor;
    ZkSupermajorityGovernor supermajorityGovernor;
    TimelockController overrideTimelock;
  }

  /// @notice Runs every check against a deployment.
  /// @param _deployment The deployed contracts.
  /// @param _deployer The account that deployed them.
  function _checkDeployment(Deployment memory _deployment, address _deployer) internal view {
    require(
      GOVERNANCE_ADMIN == _applyL1ToL2Alias(L1_PROTOCOL_UPGRADE_HANDLER), "admin is not the aliased L1 PUH address"
    );
    _checkCouncilToken(_deployment, _deployer);
    _checkCouncilGovernor(_deployment);
    _checkVetoGovernor(_deployment);
    _checkSupermajorityGovernor(_deployment);
    _checkOverrideTimelock(_deployment, _deployer);
  }

  /// @notice Checks `CouncilERC20`: metadata, owner, and exactly one seat for each council member.
  function _checkCouncilToken(Deployment memory _deployment, address _deployer) internal view {
    CouncilERC20 _token = _deployment.councilToken;
    address[] memory _members = _councilMembers();

    require(_eq(_token.name(), COUNCIL_TOKEN_NAME), "council token: name");
    require(_eq(_token.symbol(), COUNCIL_TOKEN_SYMBOL), "council token: symbol");
    require(_token.owner() == GOVERNANCE_ADMIN, "council token: owner");
    require(_token.MAX_TOKENS_PER_MEMBER() == COUNCIL_SEAT, "council token: max tokens per member");
    require(_token.totalSupply() == COUNCIL_SEAT * _members.length, "council token: total supply");
    for (uint256 _i = 0; _i < _members.length; _i++) {
      require(_token.balanceOf(_members[_i]) == COUNCIL_SEAT, "council token: member seat");
      require(_token.getVotes(_members[_i]) == COUNCIL_SEAT, "council token: member votes");
    }
    require(_token.balanceOf(_deployer) == 0, "council token: deployer holds a seat");
  }

  /// @notice Checks `ZkProtocolUpgradeCouncilGovernor`: parameters, admin, and its link to the Veto Governor.
  function _checkCouncilGovernor(Deployment memory _deployment) internal view {
    ZkProtocolUpgradeCouncilGovernor _governor = _deployment.councilGovernor;

    require(_eq(_governor.name(), COUNCIL_GOVERNOR_NAME), "council governor: name");
    require(address(_governor.token()) == address(_deployment.councilToken), "council governor: token");
    require(
      address(_governor.councilVetoGovernor()) == address(_deployment.vetoGovernor), "council governor: veto governor"
    );
    require(_governor.owner() == GOVERNANCE_ADMIN, "council governor: admin");
    require(_governor.votingDelay() == COUNCIL_GOVERNOR_VOTING_DELAY, "council governor: voting delay");
    require(_governor.votingPeriod() == COUNCIL_GOVERNOR_VOTING_PERIOD, "council governor: voting period");
    require(
      _governor.proposalThreshold() == COUNCIL_GOVERNOR_PROPOSAL_THRESHOLD, "council governor: proposal threshold"
    );
    require(_governor.quorumNumerator() == COUNCIL_GOVERNOR_QUORUM_FRACTION, "council governor: quorum");
    require(
      _governor.superQuorumNumerator() == COUNCIL_GOVERNOR_SUPER_QUORUM_FRACTION, "council governor: super-quorum"
    );
    // One seat must meet both quorum and super-quorum, so a single FOR vote is enough. The governor's `quorum` only
    // accepts past timepoints, so the values are computed from the current seat supply instead.
    uint256 _supply = _deployment.councilToken.totalSupply();
    uint256 _denominator = _governor.quorumDenominator();
    require(
      _supply * _governor.quorumNumerator() / _denominator <= COUNCIL_SEAT, "council governor: one seat below quorum"
    );
    require(
      _supply * _governor.superQuorumNumerator() / _denominator <= COUNCIL_SEAT,
      "council governor: one seat below super-quorum"
    );
  }

  /// @notice Checks `ZkProtocolUpgradeVetoGovernor`: parameters, roles, admin, and its links to the Council Governor,
  /// the Protocol Timelock and the override timelock.
  function _checkVetoGovernor(Deployment memory _deployment) internal view {
    ZkProtocolUpgradeVetoGovernor _governor = _deployment.vetoGovernor;

    require(_eq(_governor.name(), VETO_GOVERNOR_NAME), "veto governor: name");
    require(address(_governor.token()) == ZK_TOKEN, "veto governor: token");
    require(_governor.COUNCIL() == address(_deployment.councilGovernor), "veto governor: council");
    require(_governor.timelock() == PROTOCOL_TIMELOCK, "veto governor: timelock");
    require(_governor.owner() == GOVERNANCE_ADMIN, "veto governor: admin");
    require(_governor.votingDelay() == VETO_GOVERNOR_VOTING_DELAY, "veto governor: voting delay");
    require(_governor.votingPeriod() == VETO_GOVERNOR_VOTING_PERIOD, "veto governor: voting period");
    require(_governor.proposalThreshold() == VETO_GOVERNOR_PROPOSAL_THRESHOLD, "veto governor: proposal threshold");
    require(_governor.vetoThreshold(_governor.clock()) == VETO_GOVERNOR_VETO_THRESHOLD, "veto governor: threshold");
    require(_governor.vetoThresholdNumerator() == 0, "veto governor: threshold numerator");
    require(
      _governor.votingPeriodExtension() == VETO_GOVERNOR_VOTING_PERIOD_EXTENSION, "veto governor: period extension"
    );
    require(
      _governor.minorVetoExtensionThresholdPct() == VETO_GOVERNOR_EXTENSION_THRESHOLD_PCT,
      "veto governor: extension threshold"
    );
    require(_governor.vetoGuardian() == VETO_GOVERNOR_VETO_GUARDIAN, "veto governor: veto guardian");
    require(_governor.vetoOverrideRole() == address(_deployment.overrideTimelock), "veto governor: veto override role");
    require(
      _governor.vetoOverrideDuration() == VETO_GOVERNOR_VETO_OVERRIDE_DURATION, "veto governor: override duration"
    );
  }

  /// @notice Checks `ZkSupermajorityGovernor`: parameters and its link to the override timelock.
  function _checkSupermajorityGovernor(Deployment memory _deployment) internal view {
    ZkSupermajorityGovernor _governor = _deployment.supermajorityGovernor;

    require(_eq(_governor.name(), SUPERMAJORITY_GOVERNOR_NAME), "supermajority governor: name");
    require(address(_governor.token()) == ZK_TOKEN, "supermajority governor: token");
    require(_governor.timelock() == address(_deployment.overrideTimelock), "supermajority governor: timelock");
    require(_governor.votingDelay() == SUPERMAJORITY_GOVERNOR_VOTING_DELAY, "supermajority governor: voting delay");
    require(_governor.votingPeriod() == SUPERMAJORITY_GOVERNOR_VOTING_PERIOD, "supermajority governor: voting period");
    require(
      _governor.proposalThreshold() == SUPERMAJORITY_GOVERNOR_PROPOSAL_THRESHOLD,
      "supermajority governor: proposal threshold"
    );
    require(_governor.quorum(_governor.clock()) == SUPERMAJORITY_GOVERNOR_QUORUM, "supermajority governor: quorum");
    require(
      _governor.lateQuorumVoteExtension() == SUPERMAJORITY_GOVERNOR_LATE_QUORUM_EXTENSION,
      "supermajority governor: late-quorum extension"
    );
  }

  /// @notice Checks the override timelock: delay, roles, and that it administers itself with no other admin.
  function _checkOverrideTimelock(Deployment memory _deployment, address _deployer) internal view {
    TimelockController _timelock = _deployment.overrideTimelock;
    address _governor = address(_deployment.supermajorityGovernor);

    require(_timelock.getMinDelay() == OVERRIDE_TIMELOCK_MIN_DELAY, "override timelock: min delay");
    require(_timelock.hasRole(_timelock.PROPOSER_ROLE(), _governor), "override timelock: governor not proposer");
    require(_timelock.hasRole(_timelock.CANCELLER_ROLE(), _governor), "override timelock: governor not canceller");
    require(_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0)), "override timelock: execution not open");
    require(
      _timelock.hasRole(_timelock.DEFAULT_ADMIN_ROLE(), address(_timelock)), "override timelock: not self-administered"
    );
    require(!_timelock.hasRole(_timelock.DEFAULT_ADMIN_ROLE(), _deployer), "override timelock: deployer is admin");
    require(!_timelock.hasRole(_timelock.PROPOSER_ROLE(), _deployer), "override timelock: deployer is proposer");
    require(!_timelock.hasRole(_timelock.CANCELLER_ROLE(), _deployer), "override timelock: deployer is canceller");
    require(!_timelock.hasRole(_timelock.EXECUTOR_ROLE(), _deployer), "override timelock: deployer is executor");
  }

  /// @notice Returns whether two strings are equal.
  function _eq(string memory _a, string memory _b) internal pure returns (bool) {
    return keccak256(bytes(_a)) == keccak256(bytes(_b));
  }
}

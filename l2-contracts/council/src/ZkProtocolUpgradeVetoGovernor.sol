// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BasicCouncilVetoGovernor} from "council-governance/BasicCouncilVetoGovernor.sol";
import {GovernorVotesVetoThresholdFraction} from "council-governance/extensions/GovernorVotesVetoThresholdFraction.sol";

/// @title ZkProtocolUpgradeVetoGovernor
/// @author [ScopeLift](https://scopelift.co)
/// @custom:security-contact security@zksync.io
/// @notice A governor through which token holders can veto proposals submitted by a council governor. A proposal here
/// passes by default: it succeeds at the end of its voting period unless AGAINST votes reach the veto threshold, in
/// which case it is defeated. Passed proposals are queued and executed through a timelock. The veto threshold is a
/// fixed number of votes, set when the governor is deployed, rather than a share of the token supply.
///
/// Three further safeguards apply. If AGAINST votes reach a set percentage of the veto threshold, the voting period is
/// extended once, giving holders more time to respond to an emerging veto. A guardian can veto a proposal outright
/// while it is pending or active. And an override role can revive a defeated proposal, whether defeated by token
/// holders or by the guardian, within a set window after its voting period ends.
/// @dev The veto threshold cannot be changed. Using a different threshold means deploying a new governor, moving the
/// timelock's proposer, executor and canceller roles to it, and pointing the council governor at it. The governor's
/// other parameters can still be changed by its admin.
///
/// The fraction-of-supply threshold settings inherited from `GovernorVotesVetoThresholdFraction` are unused: the
/// constructor requires the numerator to be zero, `vetoThresholdNumerator` always returns zero, and
/// `updateVetoThresholdNumerator` reverts.
contract ZkProtocolUpgradeVetoGovernor is BasicCouncilVetoGovernor {
  /// @notice The number of AGAINST votes that vetoes a proposal.
  uint256 public immutable VETO_THRESHOLD;

  /// @notice Thrown when deploying with a veto threshold of zero, which would veto every proposal.
  error ZkProtocolUpgradeVetoGovernor_InvalidVetoThreshold();

  /// @notice Thrown when a fraction-of-supply veto threshold is configured, at construction or through
  /// `updateVetoThresholdNumerator`.
  error ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled();

  /// @param _params The base governor's constructor parameters. `vetoThresholdNumerator` must be zero, since this
  /// governor uses a fixed veto threshold instead.
  /// @param _vetoThreshold The number of AGAINST votes that vetoes a proposal. Must be non-zero.
  constructor(ConstructorParams memory _params, uint256 _vetoThreshold) BasicCouncilVetoGovernor(_params) {
    if (_params.vetoThresholdNumerator != 0) {
      revert ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled();
    }
    if (_vetoThreshold == 0) {
      revert ZkProtocolUpgradeVetoGovernor_InvalidVetoThreshold();
    }
    VETO_THRESHOLD = _vetoThreshold;
  }

  /// @notice Returns the number of AGAINST votes that vetoes a proposal, which is `VETO_THRESHOLD` at every timepoint.
  /// @return The veto threshold in votes.
  function vetoThreshold(uint256) public view virtual override returns (uint256) {
    return VETO_THRESHOLD;
  }

  /// @notice Always reverts. The veto threshold is a fixed number of votes, set at deployment.
  function updateVetoThresholdNumerator(uint256) external virtual override(GovernorVotesVetoThresholdFraction) {
    revert ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled();
  }
}

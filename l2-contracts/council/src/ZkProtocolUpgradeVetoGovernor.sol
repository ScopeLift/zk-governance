// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {BasicCouncilVetoGovernor} from "council-governance/BasicCouncilVetoGovernor.sol";
import {GovernorVotesVetoThresholdFraction} from "council-governance/extensions/GovernorVotesVetoThresholdFraction.sol";

/// @title ZkProtocolUpgradeVetoGovernor
/// @author [ScopeLift](https://scopelift.co)
/// @notice The ZKsync Protocol Upgrade Veto Governor. Proposals sponsored by the `ZkProtocolUpgradeCouncilGovernor` are
/// forwarded here, where ZK token holders may veto them before they are queued and executed on the Protocol Timelock.
/// @dev Identical to the upstream `BasicCouncilVetoGovernor` except for the veto threshold. Upstream computes the
/// threshold as a fraction of the token's total supply (`GovernorVotesVetoThresholdFraction`). This governor instead
/// uses a fixed number of votes (630M ZK at deployment), checkpointed by the governor clock and settable by governance,
/// so each proposal uses the value in effect at its snapshot. The inherited fraction numerator is unused: it is set to
/// zero at construction, `vetoThresholdNumerator` always returns zero, and `updateVetoThresholdNumerator` reverts.
///
/// The voting period extension inherited from `GovernorExtendVetoPeriod` is computed as a percentage of
/// `vetoThreshold`, so with a 50% extension threshold it triggers at half of the fixed veto threshold (315M ZK).
/// @custom:security-contact security@zksync.io
contract ZkProtocolUpgradeVetoGovernor is BasicCouncilVetoGovernor {
  using Checkpoints for Checkpoints.Trace208;

  /// @notice A history of fixed veto threshold values, keyed by the governor clock.
  Checkpoints.Trace208 private vetoThresholdHistory;

  /// @notice Emitted when the fixed veto threshold is changed.
  /// @param oldVetoThreshold The previous veto threshold, in votes.
  /// @param newVetoThreshold The new veto threshold, in votes.
  event VetoThresholdUpdated(uint256 oldVetoThreshold, uint256 newVetoThreshold);

  /// @notice Thrown when setting a veto threshold of zero, which would veto every proposal.
  error ZkProtocolUpgradeVetoGovernor_InvalidVetoThreshold();

  /// @notice Thrown when calling the unused `updateVetoThresholdNumerator`.
  error ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled();

  /// @param _params The upstream constructor parameters. `vetoThresholdNumerator` must be zero, since the fraction
  /// based threshold is unused.
  /// @param _initialVetoThreshold The fixed number of votes required to veto a proposal.
  constructor(ConstructorParams memory _params, uint256 _initialVetoThreshold) BasicCouncilVetoGovernor(_params) {
    if (_params.vetoThresholdNumerator != 0) {
      revert ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled();
    }
    _setVetoThreshold(_initialVetoThreshold);
  }

  /// @notice Returns the fixed number of votes required to veto a proposal at a given timepoint.
  /// @param _timepoint The timepoint, in the governor clock, to read the threshold at. Use `proposalSnapshot` for a
  /// proposal's threshold.
  /// @return The veto threshold in votes.
  function vetoThreshold(uint256 _timepoint) public view virtual override returns (uint256) {
    return _optimisticUpperLookupRecent(vetoThresholdHistory, _timepoint);
  }

  /// @notice Sets the fixed veto threshold. Proposals created after this call use the new value. Callable only
  /// through governance.
  /// @param _newVetoThreshold The new number of votes required to veto a proposal. Must be non-zero.
  function setVetoThreshold(uint256 _newVetoThreshold) external virtual onlyGovernance {
    _setVetoThreshold(_newVetoThreshold);
  }

  /// @notice Disabled. The veto threshold is a fixed number of votes, set via `setVetoThreshold`.
  function updateVetoThresholdNumerator(uint256) external virtual override(GovernorVotesVetoThresholdFraction) {
    revert ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled();
  }

  /// @notice Checkpoints a new fixed veto threshold at the current clock value.
  /// @param _newVetoThreshold The new number of votes required to veto a proposal. Must be non-zero.
  function _setVetoThreshold(uint256 _newVetoThreshold) internal virtual {
    if (_newVetoThreshold == 0) {
      revert ZkProtocolUpgradeVetoGovernor_InvalidVetoThreshold();
    }
    (uint208 _oldVetoThreshold,) = vetoThresholdHistory.push(clock(), SafeCast.toUint208(_newVetoThreshold));
    emit VetoThresholdUpdated(_oldVetoThreshold, _newVetoThreshold);
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorCountingFractional} from "@openzeppelin/contracts/governance/extensions/GovernorCountingFractional.sol";
import {GovernorPreventLateQuorum} from "@openzeppelin/contracts/governance/extensions/GovernorPreventLateQuorum.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title ZkSupermajorityGovernor
/// @author [ScopeLift](https://scopelift.co)
/// @notice The ZKsync Supermajority Governor. ZK token holders use it to override a Foundation veto on a protocol
/// upgrade: its proposals are executed through an override `TimelockController`, which holds the
/// `ZkProtocolUpgradeVetoGovernor`'s veto override role and calls `overrideVeto(proposalId)`.
/// @dev A port of `ZkProtocolGovernor` to OpenZeppelin v5.4, using OpenZeppelin's native `GovernorCountingFractional`
/// in place of the v4 fork, and an inlined settable fixed quorum in place of `GovernorSettableFixedQuorum`. It differs
/// from `ZkProtocolGovernor` in how quorum is counted: only FOR votes count toward the fixed quorum, where
/// `GovernorCountingFractional` counts FOR plus ABSTAIN. A proposal therefore succeeds only when FOR votes meet the
/// fixed quorum and FOR votes strictly exceed AGAINST votes.
/// @custom:security-contact security@zksync.io
contract ZkSupermajorityGovernor is
  GovernorCountingFractional,
  GovernorSettings,
  GovernorVotes,
  GovernorTimelockControl,
  GovernorPreventLateQuorum
{
  using Checkpoints for Checkpoints.Trace208;

  /// @notice A history of fixed quorum values, keyed by the governor clock.
  Checkpoints.Trace208 private quorumHistory;

  /// @notice Emitted when the fixed quorum is changed.
  /// @param oldQuorum The previous quorum, in votes.
  /// @param newQuorum The new quorum, in votes.
  event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

  /// @notice Thrown when setting a quorum of zero, which would let a proposal succeed with a single FOR vote.
  error ZkSupermajorityGovernor_InvalidQuorum();

  /// @param _name The name used as the EIP712 signing domain.
  /// @param _token The token used for voting on proposals.
  /// @param _timelock The override timelock that queues and executes proposals.
  /// @param _initialVotingDelay The delay before voting on a proposal begins.
  /// @param _initialVotingPeriod The period of time voting will take place.
  /// @param _initialProposalThreshold The number of votes needed to create a proposal.
  /// @param _initialQuorum The number of FOR votes needed for a proposal to succeed.
  /// @param _initialVoteExtension The time to extend the voting period if quorum is met near the end of voting.
  constructor(
    string memory _name,
    IVotes _token,
    TimelockController _timelock,
    uint48 _initialVotingDelay,
    uint32 _initialVotingPeriod,
    uint256 _initialProposalThreshold,
    uint256 _initialQuorum,
    uint48 _initialVoteExtension
  )
    Governor(_name)
    GovernorSettings(_initialVotingDelay, _initialVotingPeriod, _initialProposalThreshold)
    GovernorVotes(_token)
    GovernorTimelockControl(_timelock)
    GovernorPreventLateQuorum(_initialVoteExtension)
  {
    _setQuorum(_initialQuorum);
  }

  /// @notice Returns the fixed number of FOR votes required for a proposal to succeed at a given timepoint.
  /// @param _timepoint The timepoint, in the governor clock, to read the quorum at. Use `proposalSnapshot` for a
  /// proposal's quorum.
  /// @return The quorum in votes.
  function quorum(uint256 _timepoint) public view virtual override returns (uint256) {
    // Most lookups are for recent timepoints, so check the latest checkpoint before searching the history.
    (, uint48 _key, uint208 _value) = quorumHistory.latestCheckpoint();
    return _key <= _timepoint ? _value : quorumHistory.upperLookupRecent(SafeCast.toUint48(_timepoint));
  }

  /// @notice Sets the fixed quorum. Proposals created after this call use the new value. Callable only through
  /// governance.
  /// @param _newQuorum The new number of FOR votes required for a proposal to succeed. Must be non-zero.
  function setQuorum(uint256 _newQuorum) external virtual onlyGovernance {
    _setQuorum(_newQuorum);
  }

  /// @inheritdoc GovernorPreventLateQuorum
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function proposalDeadline(uint256 _proposalId)
    public
    view
    virtual
    override(Governor, GovernorPreventLateQuorum)
    returns (uint256)
  {
    return GovernorPreventLateQuorum.proposalDeadline(_proposalId);
  }

  /// @inheritdoc GovernorTimelockControl
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function proposalNeedsQueuing(uint256 _proposalId)
    public
    view
    virtual
    override(Governor, GovernorTimelockControl)
    returns (bool)
  {
    return GovernorTimelockControl.proposalNeedsQueuing(_proposalId);
  }

  /// @inheritdoc GovernorSettings
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function proposalThreshold() public view virtual override(Governor, GovernorSettings) returns (uint256) {
    return GovernorSettings.proposalThreshold();
  }

  /// @inheritdoc GovernorTimelockControl
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function state(uint256 _proposalId)
    public
    view
    virtual
    override(Governor, GovernorTimelockControl)
    returns (ProposalState)
  {
    return GovernorTimelockControl.state(_proposalId);
  }

  /// @inheritdoc GovernorTimelockControl
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function _cancel(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    bytes32 _descriptionHash
  ) internal virtual override(Governor, GovernorTimelockControl) returns (uint256) {
    return GovernorTimelockControl._cancel(_targets, _values, _calldatas, _descriptionHash);
  }

  /// @inheritdoc GovernorTimelockControl
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function _executeOperations(
    uint256 _proposalId,
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    bytes32 _descriptionHash
  ) internal virtual override(Governor, GovernorTimelockControl) {
    GovernorTimelockControl._executeOperations(_proposalId, _targets, _values, _calldatas, _descriptionHash);
  }

  /// @inheritdoc GovernorTimelockControl
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function _executor() internal view virtual override(Governor, GovernorTimelockControl) returns (address) {
    return GovernorTimelockControl._executor();
  }

  /// @inheritdoc GovernorTimelockControl
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function _queueOperations(
    uint256 _proposalId,
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    bytes32 _descriptionHash
  ) internal virtual override(Governor, GovernorTimelockControl) returns (uint48) {
    return GovernorTimelockControl._queueOperations(_proposalId, _targets, _values, _calldatas, _descriptionHash);
  }

  /// @inheritdoc GovernorCountingFractional
  /// @dev Counts only FOR votes toward quorum. Upstream counts FOR plus ABSTAIN, which would let ABSTAIN votes help
  /// reach the 1.26B threshold. `GovernorPreventLateQuorum` also uses this function, so the late-quorum extension is
  /// triggered by FOR votes only.
  function _quorumReached(uint256 _proposalId)
    internal
    view
    virtual
    override(Governor, GovernorCountingFractional)
    returns (bool)
  {
    (, uint256 _forVotes,) = proposalVotes(_proposalId);
    return _forVotes >= quorum(proposalSnapshot(_proposalId));
  }

  /// @notice Sets the fixed quorum, checkpointed at the current governor clock.
  /// @param _newQuorum The new number of FOR votes required for a proposal to succeed. Must be non-zero.
  function _setQuorum(uint256 _newQuorum) internal virtual {
    if (_newQuorum == 0) {
      revert ZkSupermajorityGovernor_InvalidQuorum();
    }
    uint256 _oldQuorum = quorumHistory.latest();
    quorumHistory.push(clock(), SafeCast.toUint208(_newQuorum));
    emit QuorumUpdated(_oldQuorum, _newQuorum);
  }

  /// @inheritdoc GovernorPreventLateQuorum
  /// @dev We override this function to resolve ambiguity between inherited contracts.
  function _tallyUpdated(uint256 _proposalId) internal virtual override(Governor, GovernorPreventLateQuorum) {
    GovernorPreventLateQuorum._tallyUpdated(_proposalId);
  }
}

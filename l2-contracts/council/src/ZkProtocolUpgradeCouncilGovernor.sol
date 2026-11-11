// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {
  GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {BasicCouncilGovernor} from "council-governance/BasicCouncilGovernor.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";

/// @title ZkProtocolUpgradeCouncilGovernor
/// @author [ScopeLift](https://scopelift.co)
/// @custom:security-contact security@zksync.io
/// @notice A governor through which the members of a council propose protocol upgrades. Each member holds a seat in a
/// non-transferable council token, and any account whose votes meet the proposal threshold can submit a proposal. A
/// proposal succeeds as soon as it has one seat's worth of FOR votes, however many members vote AGAINST or ABSTAIN and
/// however many seats the council has, so a single member holding a full seat is enough to sponsor it. A successful
/// proposal is not executed by this governor: queueing it submits the same actions to a veto governor, where token
/// holders have the chance to stop them before they are executed.
/// @dev Quorum and super-quorum are both fixed at one seat, the council token's `MAX_TOKENS_PER_MEMBER`, rather than a
/// fraction of the seat supply. The fraction settings inherited from `GovernorVotesQuorumFraction` and
/// `GovernorVotesSuperQuorumFraction` are unused: both fractions can only be set to zero, at construction or through
/// `updateQuorumNumerator` and `updateSuperQuorumNumerator`, so `quorumNumerator` and `superQuorumNumerator` always
/// return zero. Read `quorum` and `superQuorum` for the votes a proposal needs.
contract ZkProtocolUpgradeCouncilGovernor is BasicCouncilGovernor {
  /// @notice Thrown when a quorum or super-quorum fraction other than zero is set, at construction or by the admin.
  error ZkProtocolUpgradeCouncilGovernor__QuorumFractionDisabled();

  /// @notice The votes a proposal needs for both quorum and super-quorum: one council seat, the most council tokens a
  /// member can hold.
  uint256 public immutable QUORUM;

  /// @param _name The name used as the EIP712 signing domain.
  /// @param _councilToken The council token, whose seats carry the voting power.
  /// @param _councilVetoGovernor The veto governor that successful proposals are submitted to.
  /// @param _governorAdmin The address allowed to change the governor's parameters.
  /// @param _params The initial voting delay, voting period and proposal threshold. The quorum and super-quorum
  /// fractions must be zero, since quorum is fixed at one seat.
  constructor(
    string memory _name,
    CouncilERC20 _councilToken,
    IGovernor _councilVetoGovernor,
    address _governorAdmin,
    InitialCouncilParams memory _params
  ) BasicCouncilGovernor(_name, IERC5805(address(_councilToken)), _councilVetoGovernor, _governorAdmin, _params) {
    QUORUM = _councilToken.MAX_TOKENS_PER_MEMBER();
  }

  /// @notice Describes how votes are counted: FOR, AGAINST and ABSTAIN votes are cast as in Governor Bravo, and only
  /// FOR votes count toward quorum.
  function COUNTING_MODE() public pure virtual override(IGovernor, GovernorCountingSimple) returns (string memory) {
    return "support=bravo&quorum=bravo";
  }

  /// @notice Returns the votes a proposal needs to succeed, which is one seat at every timepoint.
  /// @return The votes of one seat.
  function quorum(uint256) public view virtual override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
    return QUORUM;
  }

  /// @notice Returns the votes at which a proposal succeeds before its voting period ends, which is one seat at every
  /// timepoint.
  /// @return The votes of one seat.
  function superQuorum(uint256) public view virtual override returns (uint256) {
    return QUORUM;
  }

  /// @notice Returns a proposal's state. Until a proposal is queued, this is the usual governor state. After that, the
  /// state follows the veto governor: a queued proposal stays Queued while token holders vote on it and while it waits
  /// in the veto governor's timelock, and becomes Executed when the veto governor executes it. A proposal that token
  /// holders or the guardian veto is Defeated rather than Canceled, because the override role can still revive it
  /// during the override window, and a revived proposal returns to Queued. A proposal that the veto governor cancels,
  /// or that expires in the veto governor, is Canceled.
  /// @param _proposalId The identifier of the proposal to check.
  /// @return The proposal's current state.
  function state(uint256 _proposalId) public view virtual override returns (ProposalState) {
    ProposalState _state = super.state(_proposalId);
    // Only a queued proposal has a stored ETA, and the council cannot cancel a proposal once it is queued, so a
    // canceled proposal with an ETA got that state from the veto governor.
    if (
      _state == ProposalState.Canceled && Governor.proposalEta(_proposalId) != 0
        && councilVetoGovernor.state(_proposalId) == ProposalState.Defeated
    ) {
      return ProposalState.Defeated;
    }
    return _state;
  }

  /// @notice Returns when a queued proposal can next advance, or zero if it has not been queued. While token holders
  /// are still voting on the proposal in the veto governor, this is the end of that vote, including any extension. Once
  /// the veto governor queues the proposal, this is the earliest time the veto governor's timelock lets it be executed.
  /// @param _proposalId The identifier of the proposal to check.
  /// @return The proposal's ETA, or zero if it has not been queued.
  function proposalEta(uint256 _proposalId) public view virtual override returns (uint256) {
    uint256 _eta = super.proposalEta(_proposalId);
    // The ETA stored at queue time is the veto governor's deadline as it was then, and an extension may have pushed
    // that deadline back since.
    if (_eta != 0 && councilVetoGovernor.proposalEta(_proposalId) == 0) {
      return councilVetoGovernor.proposalDeadline(_proposalId);
    }
    return _eta;
  }

  /// @notice Returns whether a proposal's FOR votes meet quorum. ABSTAIN votes do not count toward it.
  /// @param _proposalId The identifier of the proposal to check.
  /// @return Whether the proposal has at least one seat's worth of FOR votes.
  function _quorumReached(uint256 _proposalId)
    internal
    view
    virtual
    override(Governor, GovernorCountingSimple)
    returns (bool)
  {
    (, uint256 _forVotes,) = proposalVotes(_proposalId);
    return _forVotes >= quorum(proposalSnapshot(_proposalId));
  }

  /// @notice Returns true for every proposal: AGAINST votes cannot defeat a proposal, so whether it succeeds depends
  /// only on its FOR votes reaching quorum.
  /// @return Always true.
  function _voteSucceeded(uint256) internal view virtual override(Governor, GovernorCountingSimple) returns (bool) {
    return true;
  }

  /// @notice Accepts only a zero quorum fraction, and records nothing, since quorum is fixed at one seat. Runs at
  /// construction and for every `updateQuorumNumerator` call.
  /// @param _newQuorumNumerator The new quorum fraction's numerator.
  function _updateQuorumNumerator(uint256 _newQuorumNumerator) internal virtual override {
    _revertIfQuorumFractionIsNonZero(_newQuorumNumerator);
  }

  /// @notice Accepts only a zero super-quorum fraction, and records nothing, since super-quorum is fixed at one seat.
  /// Runs at construction and for every `updateSuperQuorumNumerator` call.
  /// @param _newSuperQuorumNumerator The new super-quorum fraction's numerator.
  function _updateSuperQuorumNumerator(uint256 _newSuperQuorumNumerator) internal virtual override {
    _revertIfQuorumFractionIsNonZero(_newSuperQuorumNumerator);
  }

  /// @notice Reverts unless a quorum or super-quorum fraction's numerator is zero.
  /// @param _numerator The numerator to check.
  function _revertIfQuorumFractionIsNonZero(uint256 _numerator) internal pure {
    if (_numerator != 0) {
      revert ZkProtocolUpgradeCouncilGovernor__QuorumFractionDisabled();
    }
  }
}

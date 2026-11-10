// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

// Stands in for the veto governor a council governor submits successful proposals to. Like a real governor, it
// identifies a proposal by the hash of its actions and description, rejects a proposal submitted twice, executes only
// a succeeded proposal, and reverts for any proposal it was never given. A submitted proposal is pending until a test
// ends its veto period with `succeed`, vetoes it with `defeat`, or ends it some other way with `cancel` or `expire`.
// Each starts with the same deadline and no ETA, and a test can extend the deadline with `extendDeadline` or set an ETA
// with `queueInTimelock`.
contract FakeCouncilVetoGovernor {
  error FakeCouncilVetoGovernor__DuplicateProposal(uint256 proposalId);
  error FakeCouncilVetoGovernor__ProposalNotSucceeded(uint256 proposalId);
  error FakeCouncilVetoGovernor__UnknownProposal(uint256 proposalId);

  uint256 public constant PROPOSAL_DEADLINE = 2_000_000_000;

  mapping(uint256 proposalId => bool) public isSubmitted;
  mapping(uint256 proposalId => IGovernor.ProposalState) internal proposalStates;
  mapping(uint256 proposalId => uint256) internal proposalDeadlines;
  mapping(uint256 proposalId => uint256) internal proposalEtas;

  function state(uint256 _proposalId) external view returns (IGovernor.ProposalState) {
    _revertIfProposalIsUnknown(_proposalId);
    return proposalStates[_proposalId];
  }

  function proposalDeadline(uint256 _proposalId) external view returns (uint256) {
    _revertIfProposalIsUnknown(_proposalId);
    return proposalDeadlines[_proposalId];
  }

  function proposalEta(uint256 _proposalId) external view returns (uint256) {
    _revertIfProposalIsUnknown(_proposalId);
    return proposalEtas[_proposalId];
  }

  function propose(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    string memory _description
  ) external returns (uint256 _proposalId) {
    _proposalId = _hashProposal(_targets, _values, _calldatas, keccak256(bytes(_description)));
    if (isSubmitted[_proposalId]) {
      revert FakeCouncilVetoGovernor__DuplicateProposal(_proposalId);
    }
    isSubmitted[_proposalId] = true;
    proposalStates[_proposalId] = IGovernor.ProposalState.Pending;
    proposalDeadlines[_proposalId] = PROPOSAL_DEADLINE;
  }

  function execute(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    bytes32 _descriptionHash
  ) external payable returns (uint256 _proposalId) {
    _proposalId = _hashProposal(_targets, _values, _calldatas, _descriptionHash);
    _revertIfProposalIsUnknown(_proposalId);
    if (proposalStates[_proposalId] != IGovernor.ProposalState.Succeeded) {
      revert FakeCouncilVetoGovernor__ProposalNotSucceeded(_proposalId);
    }
    proposalStates[_proposalId] = IGovernor.ProposalState.Executed;
  }

  // Simulates a submitted proposal's veto period ending without a veto.
  function succeed(uint256 _proposalId) external {
    _revertIfProposalIsUnknown(_proposalId);
    proposalStates[_proposalId] = IGovernor.ProposalState.Succeeded;
  }

  // Simulates token holders vetoing a submitted proposal.
  function defeat(uint256 _proposalId) external {
    _revertIfProposalIsUnknown(_proposalId);
    proposalStates[_proposalId] = IGovernor.ProposalState.Defeated;
  }

  // Simulates a submitted proposal being canceled, such as by its timelock operation being canceled.
  function cancel(uint256 _proposalId) external {
    _revertIfProposalIsUnknown(_proposalId);
    proposalStates[_proposalId] = IGovernor.ProposalState.Canceled;
  }

  // Simulates a submitted proposal expiring before it is executed.
  function expire(uint256 _proposalId) external {
    _revertIfProposalIsUnknown(_proposalId);
    proposalStates[_proposalId] = IGovernor.ProposalState.Expired;
  }

  // Simulates AGAINST votes extending a submitted proposal's voting period.
  function extendDeadline(uint256 _proposalId, uint256 _newDeadline) external {
    _revertIfProposalIsUnknown(_proposalId);
    proposalDeadlines[_proposalId] = _newDeadline;
  }

  // Simulates a succeeded proposal being queued in the timelock, which gives it an ETA.
  function queueInTimelock(uint256 _proposalId, uint256 _eta) external {
    _revertIfProposalIsUnknown(_proposalId);
    proposalStates[_proposalId] = IGovernor.ProposalState.Queued;
    proposalEtas[_proposalId] = _eta;
  }

  function _hashProposal(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    bytes32 _descriptionHash
  ) internal pure returns (uint256) {
    return uint256(keccak256(abi.encode(_targets, _values, _calldatas, _descriptionHash)));
  }

  function _revertIfProposalIsUnknown(uint256 _proposalId) internal view {
    if (!isSubmitted[_proposalId]) {
      revert FakeCouncilVetoGovernor__UnknownProposal(_proposalId);
    }
  }
}

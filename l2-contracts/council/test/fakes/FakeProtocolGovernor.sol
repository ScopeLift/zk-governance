// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

// Stands in for `ZkProtocolGovernor`, the OpenZeppelin v4 governor that holds the Protocol Timelock roles before the
// migration. It identifies proposals as a real governor does, records the proposals made to it as pending, and tests set
// each proposal's state and the proposal threshold. No account has votes.
contract FakeProtocolGovernor {
  error FakeProtocolGovernor__UnknownProposal(uint256 proposalId);

  address internal immutable TIMELOCK;

  uint256 public proposalThreshold;
  mapping(uint256 proposalId => bool) internal isKnown;
  mapping(uint256 proposalId => IGovernor.ProposalState) internal proposalStates;

  constructor(address _timelock) {
    TIMELOCK = _timelock;
  }

  function timelock() external view returns (address) {
    return TIMELOCK;
  }

  function hashProposal(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    bytes32 _descriptionHash
  ) public pure returns (uint256) {
    return uint256(keccak256(abi.encode(_targets, _values, _calldatas, _descriptionHash)));
  }

  function propose(
    address[] memory _targets,
    uint256[] memory _values,
    bytes[] memory _calldatas,
    string memory _description
  ) external returns (uint256 _proposalId) {
    _proposalId = hashProposal(_targets, _values, _calldatas, keccak256(bytes(_description)));
    isKnown[_proposalId] = true;
    proposalStates[_proposalId] = IGovernor.ProposalState.Pending;
  }

  function getVotes(address, uint256) external pure returns (uint256) {
    return 0;
  }

  function setProposalThreshold(uint256 _proposalThreshold) external {
    proposalThreshold = _proposalThreshold;
  }

  function state(uint256 _proposalId) external view returns (IGovernor.ProposalState) {
    if (!isKnown[_proposalId]) {
      revert FakeProtocolGovernor__UnknownProposal(_proposalId);
    }
    return proposalStates[_proposalId];
  }

  function setState(uint256 _proposalId, IGovernor.ProposalState _state) external {
    isKnown[_proposalId] = true;
    proposalStates[_proposalId] = _state;
  }
}

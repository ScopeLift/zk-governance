// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

/// @notice Council proposals that end without executing: defeated on the council for lack of a FOR vote, or canceled.
/// Once a proposal is forwarded to the Veto Governor, neither council members nor token holders can cancel it. The
/// governance admin can, through `relay`, while it is Pending on the Veto Governor or once it is queued on the Protocol
/// Timelock, and `relay` also lets the admin act past the council and the veto vote.
abstract contract ZkProtocolUpgradeGovernanceDefeatedAndCanceledProposalsTest is ZkProtocolUpgradeGovernanceTest {
  /// @notice The calldata of `vetoGovernor.cancel` for `_proposal`.
  function _vetoGovernorCancelCalldata(Proposal memory _proposal) internal view returns (bytes memory) {
    return abi.encodeCall(
      vetoGovernor.cancel, (_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal))
    );
  }

  /// @notice Expects the next call to revert because `_account` cannot cancel `_proposalId` on an OpenZeppelin v5
  /// governor, which lets only the proposer cancel, and only while the proposal is Pending.
  function _expectRevertUnableToCancel(uint256 _proposalId, address _account) internal {
    vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, _proposalId, _account));
  }

  /// @notice Asserts that the Veto Governor never received `_proposalId`, so asking it for the proposal's state
  /// reverts.
  function _assertNeverReachedTheVetoGovernor(uint256 _proposalId) internal {
    vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorNonexistentProposal.selector, _proposalId));
    vetoGovernor.state(_proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                        No FOR vote in 3 days
  //////////////////////////////////////////////////////////////*/

  function test_CouncilProposalWithoutAForVoteIsDefeatedAfterThreeDaysAndNeverReachesTheVetoGovernor() public {
    address[] memory _members = _deploymentParams().councilMembers;
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    assertEq(councilGovernor.proposalDeadline(_proposalId), councilGovernor.proposalSnapshot(_proposalId) + 3 days);

    // Members vote, but none votes FOR, and the 3 day voting period ends.
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(_members[1], _proposalId, uint8(GovernorCountingSimple.VoteType.Against));
    _castCouncilVote(_members[2], _proposalId, uint8(GovernorCountingSimple.VoteType.Abstain));
    uint256 _seat = _deploymentParams().votesPerCouncilSeat;
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = councilGovernor.proposalVotes(_proposalId);
    assertEq(_againstVotes, _seat);
    assertEq(_forVotes, 0);
    assertEq(_abstainVotes, _seat);
    vm.warp(councilGovernor.proposalDeadline(_proposalId));
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Active));
    _warpPastCouncilDeadline(_proposalId);
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Defeated));

    // The defeated proposal cannot be queued, so it is never forwarded.
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Succeeded);
    _queueOnCouncil(_proposal);

    _assertNeverReachedTheVetoGovernor(_proposalId);
    _assertUpgradeNotExecuted();
  }

  /*///////////////////////////////////////////////////////////////
                           Proposer cancels
  //////////////////////////////////////////////////////////////*/

  function testFuzz_ProposerCancelsACouncilProposalDuringTheOneDayVotingDelay(uint256 _elapsed) public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    // Up to and including the snapshot, the last second the proposal is Pending.
    vm.warp(block.timestamp + _bound(_elapsed, 0, _deploymentParams().councilGovernorVotingDelay));

    _cancelOnCouncil(councilMember, _proposal);

    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Canceled));
    _assertNeverReachedTheVetoGovernor(_proposalId);
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Canceled, IGovernor.ProposalState.Succeeded);
    _queueOnCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }

  function testFuzz_RevertIf_SomeoneOtherThanTheProposerCancelsACouncilProposal(address _caller) public {
    _assumeSafeFuzzedCaller(_caller);
    vm.assume(_caller != councilMember);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);

    _expectRevertUnableToCancel(_proposalId, _caller);
    _cancelOnCouncil(_caller, _proposal);

    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Pending));
  }

  function test_RevertIf_TheProposerCancelsACouncilProposalOnceVotingOpens() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);

    _expectRevertUnableToCancel(_proposalId, councilMember);
    _cancelOnCouncil(councilMember, _proposal);

    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Active));
  }

  function test_RevertIf_TheProposerCancelsACouncilProposalOnceItIsForwarded() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    _expectRevertUnableToCancel(_proposalId, councilMember);
    _cancelOnCouncil(councilMember, _proposal);

    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Pending);
  }

  /*///////////////////////////////////////////////////////////////
                       No cancel after forwarding
  //////////////////////////////////////////////////////////////*/

  function test_RevertIf_ACouncilMemberOrTokenHolderCancelsAForwardedProposalOnTheVetoGovernor() public {
    // The token holder holds enough ZK votes to veto, so the test tries a real token holder, not an empty account.
    _dealAndDelegateZk(tokenHolder, _vetoThreshold());
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    bytes32 _hash = _descriptionHash(_proposal);

    // Only the proposer, the Council Governor, could cancel it on the Veto Governor.
    _expectRevertUnableToCancel(_proposalId, councilMember);
    vm.prank(councilMember);
    vetoGovernor.cancel(_proposal.targets, _proposal.values, _proposal.calldatas, _hash);
    _expectRevertUnableToCancel(_proposalId, tokenHolder);
    vm.prank(tokenHolder);
    vetoGovernor.cancel(_proposal.targets, _proposal.values, _proposal.calldatas, _hash);

    // The proposal goes on to execute.
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);
    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function test_RevertIf_ACouncilMemberOrTokenHolderCancelsAForwardedProposalOnTheProtocolTimelock() public {
    // The token holder holds enough ZK votes to veto, so the test tries a real token holder, not an empty account.
    _dealAndDelegateZk(tokenHolder, _vetoThreshold());
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    bytes32 _operationId = _protocolTimelockOperationId(_proposal);

    // Neither holds the canceller role, which the role migration gave only to the Veto Governor.
    _expectRevertMissingTimelockRole(councilMember, CANCELLER_ROLE);
    vm.prank(councilMember);
    protocolTimelock.cancel(_operationId);
    _expectRevertMissingTimelockRole(tokenHolder, CANCELLER_ROLE);
    vm.prank(tokenHolder);
    protocolTimelock.cancel(_operationId);

    // The proposal goes on to execute.
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Queued);
    _executeThroughCouncil(_proposal);
    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  /*///////////////////////////////////////////////////////////////
                         Governance admin relay
  //////////////////////////////////////////////////////////////*/

  /// @dev Pins the current behavior: `relay` makes the Council Governor the caller, and it is the proposer on the Veto
  /// Governor, so the governance admin can cancel a forwarded proposal there while it is Pending.
  function test_GovernanceAdminCancelsAForwardedProposalThroughTheCouncilGovernorsRelayWhileItIsPending() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    vm.prank(_deploymentParams().governanceAdmin);
    councilGovernor.relay(address(vetoGovernor), 0, _vetoGovernorCancelCalldata(_proposal));

    _assertStates(_proposalId, IGovernor.ProposalState.Canceled, IGovernor.ProposalState.Canceled);
    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Canceled, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Queued
    );
    _executeThroughCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }

  function test_RevertIf_GovernanceAdminCancelsThroughTheCouncilGovernorsRelayOnceTheVetoVoteOpens() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpToVetoVoting(_proposalId);

    _expectRevertUnableToCancel(_proposalId, address(councilGovernor));
    vm.prank(_deploymentParams().governanceAdmin);
    councilGovernor.relay(address(vetoGovernor), 0, _vetoGovernorCancelCalldata(_proposal));

    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Active);
  }

  function test_RevertIf_GovernanceAdminCancelsAForwardedProposalThroughTheVetoGovernorsOwnRelay() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    // The Veto Governor is not the proposal's proposer, so it cannot cancel it on itself.
    _expectRevertUnableToCancel(_proposalId, address(vetoGovernor));
    vm.prank(_deploymentParams().governanceAdmin);
    vetoGovernor.relay(address(vetoGovernor), 0, _vetoGovernorCancelCalldata(_proposal));

    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Pending);
  }

  /// @dev Pins the current behavior: `relay` makes the Veto Governor the caller, and it holds the canceller role on the
  /// Protocol Timelock, so the governance admin can cancel a proposal queued there. The timelock has no delay and the
  /// council's `execute` is open to anyone, so the proposal can also be executed in the same second it is queued.
  function test_GovernanceAdminCancelsAQueuedProposalOnTheProtocolTimelockThroughTheVetoGovernorsRelay() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    bytes32 _operationId = _protocolTimelockOperationId(_proposal);

    vm.prank(_deploymentParams().governanceAdmin);
    vetoGovernor.relay(address(protocolTimelock), 0, abi.encodeCall(protocolTimelock.cancel, (_operationId)));

    assertFalse(protocolTimelock.isOperation(_operationId));
    _assertStates(_proposalId, IGovernor.ProposalState.Canceled, IGovernor.ProposalState.Canceled);
    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Canceled, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Queued
    );
    _executeThroughCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }

  /// @dev Pins the current behavior: `relay` reaches past cancellation. The Council Governor is the only account the
  /// Veto Governor takes proposals from, so the governance admin can put a proposal to the Veto Governor that no
  /// council member voted on.
  function test_GovernanceAdminProposesToTheVetoGovernorThroughTheCouncilGovernorsRelayWithoutACouncilVote() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId =
      vetoGovernor.getProposalId(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));

    vm.prank(_deploymentParams().governanceAdmin);
    councilGovernor.relay(
      address(vetoGovernor),
      0,
      abi.encodeCall(
        vetoGovernor.propose, (_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description)
      )
    );

    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Pending));
    assertEq(vetoGovernor.proposalProposer(_proposalId), address(councilGovernor));
    assertEq(councilGovernor.proposalSnapshot(_proposalId), 0);
  }

  /// @dev Pins the current behavior: `relay` makes the Veto Governor the caller, and it holds the proposer and executor
  /// roles on the Protocol Timelock, whose delay is 0, so the governance admin can run any call through the Protocol
  /// Timelock without a council proposal or a veto vote.
  function test_GovernanceAdminExecutesOnTheProtocolTimelockThroughTheVetoGovernorsRelayWithoutAVote() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    bytes32 _salt = _protocolTimelockSalt(_proposal);
    uint256 _delay = protocolTimelock.getMinDelay();

    vm.startPrank(_deploymentParams().governanceAdmin);
    vetoGovernor.relay(
      address(protocolTimelock),
      0,
      abi.encodeCall(
        protocolTimelock.scheduleBatch,
        (_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt, _delay)
      )
    );
    vm.warp(block.timestamp + _delay);
    vetoGovernor.relay(
      address(protocolTimelock),
      0,
      abi.encodeCall(
        protocolTimelock.executeBatch, (_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt)
      )
    );
    vm.stopPrank();

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
  }
}

// Each fuzz run takes a whole proposal through emulated EraVM on an Era mainnet fork, and each fuzzed address is a new
// account to fetch from the fork, so these tests fuzz fewer runs than the default.
// Inline config applies to the concrete contract that runs the tests, not to the abstract suite that defines them.
/// forge-config: default.fuzz.runs = 8
/// forge-config: ci.fuzz.runs = 8
/// forge-config: lite.fuzz.runs = 2
contract ZkProtocolUpgradeGovernanceDefeatedAndCanceledProposalsEraMainnetScript is
  ZkProtocolUpgradeGovernanceDefeatedAndCanceledProposalsTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

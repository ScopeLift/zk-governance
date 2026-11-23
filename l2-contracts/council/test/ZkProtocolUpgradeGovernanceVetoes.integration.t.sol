// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVetoGuardian} from "council-governance/extensions/GovernorVetoGuardian.sol";
import {GovernorVetoOverride} from "council-governance/extensions/GovernorVetoOverride.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

/// @notice Council proposals vetoed on the Veto Governor, by ZK token holders reaching the veto threshold or by the
/// veto guardian, and the limits on what the guardian can do.
abstract contract ZkProtocolUpgradeGovernanceVetoesTest is ZkProtocolUpgradeGovernanceTest {
  /// @notice Bounds `_votes` to a veto: from the veto threshold to the ZK token's total supply less the quorum that
  /// `setUp` gives `supermajorityVoter`. The cap is only a loose bound that keeps the amount realistic: `deal` does not
  /// change the total supply, and holders on the fork and the role migration's delegate keep their own votes.
  function _boundToVetoingVotes(uint256 _votes) internal view returns (uint256) {
    return _bound(_votes, _vetoThreshold(), _zkTotalSupply() - _supermajorityQuorum());
  }

  /// @notice Asserts that a vetoed `_proposal` is Defeated on both governors and can be neither queued on the Protocol
  /// Timelock nor executed through the council.
  function _assertVetoedProposalIsStuck(Proposal memory _proposal, uint256 _proposalId) internal {
    _assertStates(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Queued
    );
    _executeThroughCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }

  /*///////////////////////////////////////////////////////////////
                           Token holder veto
  //////////////////////////////////////////////////////////////*/

  function testFuzz_TokenHoldersReachingTheVetoThresholdDefeatTheProposalOnBothGovernors(uint256 _vetoVotes) public {
    _vetoVotes = _boundToVetoingVotes(_vetoVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    _dealAndCastVeto(tokenHolder, _vetoVotes, _proposalId);
    _warpPastVetoDeadline(_proposalId);

    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  function test_TokenHolderVetoStillStandsAfterTheVetoOverrideWindowCloses() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _dealAndCastVeto(tokenHolder, _vetoThreshold(), _proposalId);

    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + vetoGovernor.vetoOverrideDuration() + 1);

    // The Supermajority Governor's override timelock can no longer revive it.
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernorVetoOverride.VetoOverrideOutsideWindow.selector, _proposalId, uint48(block.timestamp)
      )
    );
    vm.prank(address(overrideTimelock));
    vetoGovernor.overrideVeto(_proposalId);
    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  function test_VetoVotesOneWeiBelowTheVetoThresholdDoNotVetoTheProposal() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    _dealAndCastVeto(tokenHolder, _vetoThreshold() - 1, _proposalId);
    assertEq(vetoGovernor.proposalVotes(_proposalId), _vetoThreshold() - 1);
    _warpPastVetoDeadline(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function test_VetoVotesAtTheVetoThresholdVetoTheProposal() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    _dealAndCastVeto(tokenHolder, _vetoThreshold(), _proposalId);
    assertEq(vetoGovernor.proposalVotes(_proposalId), _vetoThreshold());
    _warpPastVetoDeadline(_proposalId);

    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                             Guardian veto
  //////////////////////////////////////////////////////////////*/

  function test_GuardianVetoWhileTheProposalIsPendingDefeatsItOnBothGovernors() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Pending));

    _vetoByGuardian(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);

    // The veto holds after the voting period ends.
    _warpPastVetoDeadline(_proposalId);
    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  function test_GuardianVetoWhileTheProposalIsActiveDefeatsItOnBothGovernors() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpToVetoVoting(_proposalId);
    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Active));

    _vetoByGuardian(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);

    _warpPastVetoDeadline(_proposalId);
    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                            Guardian limits
  //////////////////////////////////////////////////////////////*/

  function test_RevertIf_TheGuardianVetoesAfterTheVetoDeadline() public {
    address _guardian = vetoGovernor.vetoGuardian();
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);

    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Pending, IGovernor.ProposalState.Active
    );
    _vetoByGuardian(_guardian, _proposalId);

    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
  }

  function test_RevertIf_TheGuardianVetoesAProposalQueuedOnTheProtocolTimelock() public {
    address _guardian = vetoGovernor.vetoGuardian();
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);

    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Pending, IGovernor.ProposalState.Active
    );
    _vetoByGuardian(_guardian, _proposalId);

    // The proposal goes on to execute.
    _executeThroughCouncil(_proposal);
    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function testFuzz_RevertIf_AnyoneButTheGuardianVetoesByGuardian(address _caller) public {
    _assumeSafeFuzzedCaller(_caller);
    vm.assume(_caller != vetoGovernor.vetoGuardian());
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    vm.expectRevert(GovernorVetoGuardian.GovernorVetoGuardian_Unauthorized.selector);
    vm.prank(_caller);
    vetoGovernor.vetoByGuardian(_proposalId);

    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Pending);
  }

  function test_RevertIf_TheGuardianProposesToEitherGovernor() public {
    address _guardian = vetoGovernor.vetoGuardian();
    Proposal memory _proposal = _protocolUpgradeProposal();

    // The guardian holds no council seat, and only the council proposes to the Veto Governor.
    vm.expectRevert(
      abi.encodeWithSelector(
        IGovernor.GovernorInsufficientProposerVotes.selector, _guardian, 0, councilGovernor.proposalThreshold()
      )
    );
    _proposeToCouncil(_guardian, _proposal);
    vm.expectRevert("Only council");
    vm.prank(_guardian);
    vetoGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
  }

  function test_RevertIf_TheGuardianExecutesOnTheVetoGovernorOrSchedulesExecutesOrCancelsOnTheProtocolTimelock()
    public
  {
    address _guardian = vetoGovernor.vetoGuardian();
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    bytes32 _salt = _protocolTimelockSalt(_proposal);

    // The guardian holds no role on the Protocol Timelock, so it cannot schedule there itself.
    _expectRevertMissingTimelockRole(_guardian, PROPOSER_ROLE);
    vm.prank(_guardian);
    protocolTimelock.scheduleBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt, 0);

    // Once the proposal is queued, it cannot execute it there or on the Veto Governor.
    _queueOnProtocolTimelock(_proposal);
    _expectRevertMissingTimelockRole(_guardian, EXECUTOR_ROLE);
    vm.prank(_guardian);
    protocolTimelock.executeBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt);
    vm.expectRevert("Only council");
    vm.prank(_guardian);
    vetoGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));

    // Nor can it cancel it there, which would get around the limit on vetoing only a Pending or Active proposal.
    bytes32 _operationId = _protocolTimelockOperationId(_proposal);
    _expectRevertMissingTimelockRole(_guardian, CANCELLER_ROLE);
    vm.prank(_guardian);
    protocolTimelock.cancel(_operationId);

    _assertUpgradeNotExecuted();
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Queued);
  }

  /// @dev Pins the current behavior: `queue` on both governors and `execute` on the Council Governor are open to every
  /// account, so the guardian can call them like anyone else. They only advance a proposal that has already passed.
  function test_GuardianCanQueueAndExecuteAPassedProposalLikeAnyAccount() public {
    address _guardian = vetoGovernor.vetoGuardian();
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(councilMember, _proposalId, uint8(GovernorCountingSimple.VoteType.For));

    vm.prank(_guardian);
    _queueOnCouncil(_proposal);
    _warpPastVetoDeadline(_proposalId);
    vm.prank(_guardian);
    _queueOnProtocolTimelock(_proposal);
    vm.prank(_guardian);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  /*///////////////////////////////////////////////////////////////
                    Threshold change mid-proposal
  //////////////////////////////////////////////////////////////*/

  function testFuzz_LoweringTheVetoThresholdAfterTheSnapshotKeepsTheSnapshotThreshold(
    uint256 _newVetoThreshold,
    uint256 _vetoVotes
  ) public {
    _newVetoThreshold = _bound(_newVetoThreshold, 1, _vetoThreshold() - 1);
    // Enough to veto under the new threshold, but not under the one in force at the snapshot.
    _vetoVotes = _bound(_vetoVotes, _newVetoThreshold, _vetoThreshold() - 1);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _dealAndCastVeto(tokenHolder, _vetoVotes, _proposalId);
    assertEq(vetoGovernor.proposalVotes(_proposalId), _vetoVotes);

    vm.prank(_deploymentParams().governanceAdmin);
    vetoGovernor.setVetoThreshold(_newVetoThreshold);
    assertEq(vetoGovernor.vetoThreshold(block.timestamp), _newVetoThreshold);
    assertEq(vetoGovernor.vetoThreshold(vetoGovernor.proposalSnapshot(_proposalId)), _vetoThreshold());

    _warpPastVetoDeadline(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);
    _assertUpgradeExecutedByProtocolTimelock(_proposal);
  }

  function testFuzz_RaisingTheVetoThresholdAfterTheSnapshotKeepsTheSnapshotThreshold(uint256 _newVetoThreshold) public {
    _newVetoThreshold = _bound(_newVetoThreshold, _vetoThreshold() + 1, type(uint208).max);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _dealAndCastVeto(tokenHolder, _vetoThreshold(), _proposalId);

    vm.prank(_deploymentParams().governanceAdmin);
    vetoGovernor.setVetoThreshold(_newVetoThreshold);
    assertEq(vetoGovernor.vetoThreshold(block.timestamp), _newVetoThreshold);
    assertEq(vetoGovernor.vetoThreshold(vetoGovernor.proposalSnapshot(_proposalId)), _vetoThreshold());

    _warpPastVetoDeadline(_proposalId);
    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }
}

// Each fuzz run takes a whole proposal through emulated EraVM on an Era mainnet fork, and each fuzzed address is a new
// account to fetch from the fork, so these tests fuzz fewer runs than the default.
// Inline config applies to the concrete contract that runs the tests, not to the abstract suite that defines them.
/// forge-config: default.fuzz.runs = 8
/// forge-config: ci.fuzz.runs = 8
/// forge-config: lite.fuzz.runs = 2
contract ZkProtocolUpgradeGovernanceVetoesEraMainnetScript is
  ZkProtocolUpgradeGovernanceVetoesTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

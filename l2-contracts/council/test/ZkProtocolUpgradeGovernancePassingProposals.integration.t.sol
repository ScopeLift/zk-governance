// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

/// @notice Council proposals that token holders do not veto: they pass the council with one FOR vote, wait out the Veto
/// Governor's delay and veto vote, and execute through the Protocol Timelock.
abstract contract ZkProtocolUpgradeGovernancePassingProposalsTest is ZkProtocolUpgradeGovernanceTest {
  address secondTokenHolder = makeAddr("Second Token Holder");

  function test_CouncilProposalWithNoVetoVotesExecutesThroughTheProtocolTimelockAfterTheDelayAndVetoVote() public {
    DeploymentParams memory _params = _deploymentParams();
    Proposal memory _proposal = _protocolUpgradeProposal();

    // A member proposes, and the proposal waits out the council's voting delay.
    uint256 _proposalId = _proposeToCouncil(_proposal);
    assertEq(councilGovernor.proposalSnapshot(_proposalId), block.timestamp + _params.councilGovernorVotingDelay);
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Pending));

    // One FOR vote passes it on the council, and queueing it on the council forwards it to the Veto Governor.
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(councilMember, _proposalId, uint8(GovernorCountingSimple.VoteType.For));
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    _queueOnCouncil(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Pending);

    // It waits 1 day before the veto vote opens and 7 days for the vote, during which nobody votes.
    uint256 _vetoSnapshot = vetoGovernor.proposalSnapshot(_proposalId);
    assertEq(_vetoSnapshot, block.timestamp + _params.vetoGovernorVotingDelay);
    assertEq(vetoGovernor.proposalDeadline(_proposalId), _vetoSnapshot + _params.vetoGovernorVotingPeriod);
    assertEq(councilGovernor.proposalEta(_proposalId), vetoGovernor.proposalDeadline(_proposalId));
    _warpToVetoVoting(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Active);
    _warpToVetoDeadline(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Active);
    _warpPastVetoDeadline(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
    _assertUpgradeNotExecuted();

    // It is queued on the Protocol Timelock and executed through the council.
    _queueOnProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Queued);
    // Once queued on the Protocol Timelock, the council reports the timelock's ETA, which has no delay.
    assertEq(vetoGovernor.proposalEta(_proposalId), block.timestamp);
    assertEq(councilGovernor.proposalEta(_proposalId), block.timestamp);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function testFuzz_VetoVotesBelowTheExtensionThresholdLeaveTheDeadlineSoTheProposalPasses(uint256 _vetoVotes) public {
    _vetoVotes = _bound(_vetoVotes, 1, _extensionThreshold() - 1);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    uint256 _deadline = vetoGovernor.proposalDeadline(_proposalId);

    _dealAndCastVeto(tokenHolder, _vetoVotes, _proposalId);
    assertEq(vetoGovernor.proposalVotes(_proposalId), _vetoVotes);
    assertEq(vetoGovernor.proposalDeadline(_proposalId), _deadline);

    // The proposal passes as soon as the original deadline does.
    vm.warp(_deadline + 1);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function testFuzz_VetoVotesFromTheExtensionThresholdExtendTheDeadlineByTwoDaysOnceAndTheProposalPassesAfterIt(
    uint256 _firstVetoVotes,
    uint256 _secondVetoVotes
  ) public {
    // The first veto reaches the extension threshold; the second adds more without reaching the veto threshold.
    _firstVetoVotes = _bound(_firstVetoVotes, _extensionThreshold(), _vetoThreshold() - 2);
    _secondVetoVotes = _bound(_secondVetoVotes, 1, _vetoThreshold() - 1 - _firstVetoVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    uint256 _originalDeadline = vetoGovernor.proposalDeadline(_proposalId);
    uint256 _extendedDeadline = _originalDeadline + _deploymentParams().vetoGovernorVotingPeriodExtension;

    // Both holders' votes count at the snapshot, so both delegate before voting opens.
    _dealAndDelegateZk(secondTokenHolder, _secondVetoVotes);
    _dealAndCastVeto(tokenHolder, _firstVetoVotes, _proposalId);
    assertEq(vetoGovernor.proposalDeadline(_proposalId), _extendedDeadline);
    assertEq(councilGovernor.proposalEta(_proposalId), _extendedDeadline);

    // More AGAINST votes do not extend it again.
    _castVeto(secondTokenHolder, _proposalId);
    assertEq(vetoGovernor.proposalVotes(_proposalId), _firstVetoVotes + _secondVetoVotes);
    assertEq(vetoGovernor.proposalDeadline(_proposalId), _extendedDeadline);

    // The proposal is still being voted on after the original deadline, so it cannot be queued yet.
    vm.warp(_originalDeadline + 1);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Active);
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Active, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);

    // It passes after the extended deadline, which the council reports as its ETA.
    vm.warp(_extendedDeadline + 1);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
    assertEq(councilGovernor.proposalEta(_proposalId), _extendedDeadline);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function test_VetoVotesOneWeiBelowTheExtensionThresholdDoNotExtendTheDeadline() public {
    uint256 _proposalId = _passCouncilProposal(_protocolUpgradeProposal());
    uint256 _deadline = vetoGovernor.proposalDeadline(_proposalId);

    _dealAndCastVeto(tokenHolder, _extensionThreshold() - 1, _proposalId);

    assertEq(vetoGovernor.proposalDeadline(_proposalId), _deadline);
  }

  function test_VetoVotesAtTheExtensionThresholdExtendTheDeadline() public {
    uint256 _proposalId = _passCouncilProposal(_protocolUpgradeProposal());
    uint256 _deadline = vetoGovernor.proposalDeadline(_proposalId);

    _dealAndCastVeto(tokenHolder, _extensionThreshold(), _proposalId);

    assertEq(
      vetoGovernor.proposalDeadline(_proposalId), _deadline + _deploymentParams().vetoGovernorVotingPeriodExtension
    );
  }

  function test_ExtendedProposalWithVetoVotesOneWeiBelowTheVetoThresholdPassesAfterTheExtendedDeadline() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    uint256 _extendedDeadline =
      vetoGovernor.proposalDeadline(_proposalId) + _deploymentParams().vetoGovernorVotingPeriodExtension;

    // The two holders' votes together reach one wei below the veto threshold.
    _dealAndDelegateZk(secondTokenHolder, _vetoThreshold() - 1 - _extensionThreshold());
    _dealAndCastVeto(tokenHolder, _extensionThreshold(), _proposalId);
    _castVeto(secondTokenHolder, _proposalId);
    assertEq(vetoGovernor.proposalVotes(_proposalId), _vetoThreshold() - 1);
    assertEq(vetoGovernor.proposalDeadline(_proposalId), _extendedDeadline);

    vm.warp(_extendedDeadline + 1);
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function test_OtherMembersVotingAgainstOrAbstainingDoNotStopACouncilProposalThatOneMemberVotesFor() public {
    address[] memory _members = _deploymentParams().councilMembers;
    Proposal memory _proposal = _protocolUpgradeProposal();

    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(_members[1], _proposalId, uint8(GovernorCountingSimple.VoteType.Against));
    _castCouncilVote(_members[2], _proposalId, uint8(GovernorCountingSimple.VoteType.Against));
    _castCouncilVote(_members[3], _proposalId, uint8(GovernorCountingSimple.VoteType.Abstain));
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Active));
    uint256 _seat = _deploymentParams().votesPerCouncilSeat;

    // One FOR vote passes the proposal despite more votes against it.
    _castCouncilVote(_members[0], _proposalId, uint8(GovernorCountingSimple.VoteType.For));
    (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = councilGovernor.proposalVotes(_proposalId);
    assertEq(_againstVotes, 2 * _seat);
    assertEq(_forVotes, _seat);
    assertEq(_abstainVotes, _seat);
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));

    _queueOnCouncil(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function test_RevertIf_ACouncilMemberVotesAfterTheFirstForVote() public {
    address[] memory _members = _deploymentParams().councilMembers;
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(_members[0], _proposalId, uint8(GovernorCountingSimple.VoteType.For));

    // The first FOR vote reaches the council's super-quorum of one seat, which ends voting.
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Active);
    _castCouncilVote(_members[1], _proposalId, uint8(GovernorCountingSimple.VoteType.Against));

    _assertUpgradeNotExecuted();
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));
  }

  function testFuzz_RevertIf_AnyoneButTheCouncilExecutesOnTheVetoGovernor(address _caller) public {
    _assumeSafeFuzzedCaller(_caller);
    vm.assume(_caller != address(councilGovernor));
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);

    vm.expectRevert("Only council");
    vm.prank(_caller);
    vetoGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));

    _assertUpgradeNotExecuted();
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Queued);
  }

  function testFuzz_RevertIf_AnyoneButTheVetoGovernorExecutesTheQueuedOperationOnTheProtocolTimelock(address _caller)
    public
  {
    _assumeSafeFuzzedCaller(_caller);
    vm.assume(_caller != address(vetoGovernor));
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);

    // The role migration left the Veto Governor as the Protocol Timelock's only executor, so no one can run the
    // operation there without going through the council.
    _expectRevertMissingTimelockRole(_caller, EXECUTOR_ROLE);
    vm.prank(_caller);
    protocolTimelock.executeBatch(
      _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _protocolTimelockSalt(_proposal)
    );

    _assertUpgradeNotExecuted();
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Queued);
  }

  function test_RevertIf_TheCouncilExecutesBeforeTheProposalIsQueuedOnTheProtocolTimelock() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);

    // OpenZeppelin v4's `TimelockController` reverts with a string.
    vm.expectRevert("TimelockController: operation is not ready");
    _executeThroughCouncil(_proposal);

    _assertUpgradeNotExecuted();
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
  }

  /// @dev Pins the current behavior: the Protocol Timelock's minimum delay is zero, so there is no timelock delay to
  /// wait out once the veto vote ends.
  function test_CouncilExecutesInTheSameSecondTheProposalIsQueuedOnTheProtocolTimelock() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    assertEq(protocolTimelock.getMinDelay(), 0);

    _queueOnProtocolTimelock(_proposal);
    assertEq(protocolTimelock.getTimestamp(_protocolTimelockOperationId(_proposal)), block.timestamp);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  /// @dev The Protocol Timelock's minimum delay is zero, so this test first raises it, as a proposal executed through
  /// the Protocol Timelock could, and then shows the delay holds back execution through the council until it passes.
  function testFuzz_CouncilExecutesOnlyOnceARaisedProtocolTimelockDelayHasPassed(uint256 _delay) public {
    // Up to a year, a generous range for a timelock delay. The Veto Governor stores the ETA as a `uint48`, so far
    // longer delays would test that cast rather than the delay.
    _delay = _bound(_delay, 1, 365 days);
    // The Protocol Timelock administers itself, so only a call from the timelock can change its delay.
    vm.prank(address(protocolTimelock));
    protocolTimelock.updateDelay(_delay);

    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    uint256 _eta = block.timestamp + _delay;
    assertEq(councilGovernor.proposalEta(_proposalId), _eta);

    // One second before the delay ends, the operation is not ready, so the council can't execute it.
    vm.warp(_eta - 1);
    vm.expectRevert("TimelockController: operation is not ready");
    _executeThroughCouncil(_proposal);
    _assertUpgradeNotExecuted();
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Queued);

    // Once the delay ends, the council executes it.
    vm.warp(_eta);
    _executeThroughCouncil(_proposal);
    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }
}

// Each fuzz run takes a whole proposal through emulated EraVM on an Era mainnet fork, and each fuzzed address is a new
// account to fetch from the fork, so these tests fuzz fewer runs than the default.
// Inline config applies to the concrete contract that runs the tests, not to the abstract suite that defines them.
/// forge-config: default.fuzz.runs = 8
/// forge-config: ci.fuzz.runs = 8
/// forge-config: lite.fuzz.runs = 2
contract ZkProtocolUpgradeGovernancePassingProposalsEraMainnetScript is
  ZkProtocolUpgradeGovernancePassingProposalsTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

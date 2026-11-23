// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVetoOverride} from "council-governance/extensions/GovernorVetoOverride.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

/// @notice The window in which a veto can be overridden: to 14 days after the veto deadline, including any extension,
/// from the deadline itself for a guardian veto and from one second after it for a token holder veto, whose proposal
/// stays Active through its deadline. Each boundary is checked by calling `overrideVeto` from the override timelock,
/// the account the Supermajority Governor executes through, and the worst-case Supermajority Governor timeline is run
/// end to end.
/// @dev A token holder veto reaches the veto threshold, which is above the extension threshold, so its deadline is
/// always extended by 2 days. The guardian vetoes a proposal with no AGAINST votes, whose deadline is not extended,
/// unless a test casts AGAINST votes first.
abstract contract ZkProtocolUpgradeGovernanceVetoOverrideWindowTest is ZkProtocolUpgradeGovernanceTest {
  /// @notice How long after the veto deadline a veto can still be overridden: 14 days with the Era mainnet params.
  function _vetoOverrideDuration() internal view returns (uint256) {
    return _deploymentParams().vetoGovernorVetoOverrideDuration;
  }

  /// @notice `councilMember` passes `_proposal` on the council, and token holders veto it with the veto threshold as
  /// soon as voting opens, which extends its deadline. Leaves the time at the start of the veto vote.
  function _passAndVetoByTokenHoldersAtVotingStart(Proposal memory _proposal) internal returns (uint256 _proposalId) {
    _proposalId = _passCouncilProposal(_proposal);
    uint256 _originalDeadline = vetoGovernor.proposalDeadline(_proposalId);
    _dealAndCastVeto(tokenHolder, _vetoThreshold(), _proposalId);
    // The deadline is extended from half the veto threshold, so an extended deadline alone does not show a veto.
    require(
      vetoGovernor.proposalVotes(_proposalId) >= vetoGovernor.vetoThreshold(vetoGovernor.proposalSnapshot(_proposalId)),
      "_passAndVetoByTokenHoldersAtVotingStart: the AGAINST votes did not reach the veto threshold"
    );
    require(
      vetoGovernor.proposalDeadline(_proposalId)
        == _originalDeadline + _deploymentParams().vetoGovernorVotingPeriodExtension,
      "_passAndVetoByTokenHoldersAtVotingStart: the veto did not extend the deadline"
    );
  }

  /// @notice `councilMember` passes `_proposal` on the council, and the guardian vetoes it while it is Pending, before
  /// any AGAINST votes, so its deadline is not extended.
  function _passAndVetoByGuardian(Proposal memory _proposal) internal returns (uint256 _proposalId) {
    _proposalId = _passCouncilProposal(_proposal);
    uint256 _deadline = vetoGovernor.proposalDeadline(_proposalId);
    _vetoByGuardian(_proposalId);
    require(
      vetoGovernor.proposalDeadline(_proposalId) == _deadline, "_passAndVetoByGuardian: the deadline was extended"
    );
  }

  /// @notice `councilMember` passes `_proposal`, token holders cast AGAINST votes at the extension threshold, which
  /// extends the deadline without vetoing it, and then the guardian vetoes it. Returns the proposal's original
  /// deadline.
  function _passExtendAndVetoByGuardian(Proposal memory _proposal)
    internal
    returns (uint256 _proposalId, uint256 _originalDeadline)
  {
    DeploymentParams memory _params = _deploymentParams();
    _proposalId = _passCouncilProposal(_proposal);
    _originalDeadline = vetoGovernor.proposalDeadline(_proposalId);
    _dealAndCastVeto(tokenHolder, _extensionThreshold(), _proposalId);
    require(
      vetoGovernor.proposalVotes(_proposalId) < _vetoThreshold(),
      "_passExtendAndVetoByGuardian: the AGAINST votes reached the veto threshold, so the guardian would not be the one vetoing"
    );
    _vetoByGuardian(_proposalId);
    require(
      vetoGovernor.proposalDeadline(_proposalId) == _originalDeadline + _params.vetoGovernorVotingPeriodExtension,
      "_passExtendAndVetoByGuardian: the AGAINST votes did not extend the deadline"
    );
  }

  /// @notice Calls `overrideVeto` on `_proposalId` from the override timelock, as an executed Supermajority Governor
  /// proposal does.
  function _overrideVetoFromTheOverrideTimelock(uint256 _proposalId) internal {
    vm.prank(address(overrideTimelock));
    vetoGovernor.overrideVeto(_proposalId);
  }

  /// @notice Expects the next `overrideVeto` on `_proposalId` to revert because the current time is outside its
  /// override window.
  function _expectRevertOutsideWindow(uint256 _proposalId) internal {
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernorVetoOverride.VetoOverrideOutsideWindow.selector, _proposalId, uint48(block.timestamp)
      )
    );
  }

  /// @notice Asserts that the veto on `_proposalId` was overridden: the Veto Governor reports it Succeeded and the
  /// council Queued.
  function _assertOverridden(uint256 _proposalId) internal view {
    assertTrue(vetoGovernor.isVetoOverridden(_proposalId));
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
  }

  /// @notice Asserts that the veto on `_proposal` was not overridden and the proposal is in `_councilState` and
  /// `_vetoGovernorState`, either Active or Defeated on the Veto Governor, so it can be neither queued on the Protocol
  /// Timelock nor executed through the council, and the target was never called.
  function _assertNotOverridden(
    Proposal memory _proposal,
    uint256 _proposalId,
    IGovernor.ProposalState _councilState,
    IGovernor.ProposalState _vetoGovernorState
  ) internal {
    assertFalse(vetoGovernor.isVetoOverridden(_proposalId));
    _assertStates(_proposalId, _councilState, _vetoGovernorState);
    _expectRevertUnexpectedState(_proposalId, _vetoGovernorState, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _expectRevertUnexpectedState(
      _proposalId, _vetoGovernorState, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Queued
    );
    _executeThroughCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }

  /*///////////////////////////////////////////////////////////////
                         Before the veto deadline
  //////////////////////////////////////////////////////////////*/

  function testFuzz_RevertIf_ATokenHolderVetoIsOverriddenBeforeItsDeadline(uint256 _time) public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHoldersAtVotingStart(_proposal);
    vm.warp(_bound(_time, block.timestamp, vetoGovernor.proposalDeadline(_proposalId) - 1));

    // Voting is still open, so the proposal is Active rather than Defeated.
    vm.expectRevert(
      abi.encodeWithSelector(
        GovernorVetoOverride.VetoOverrideUnexpectedState.selector, _proposalId, IGovernor.ProposalState.Active
      )
    );
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Active);
  }

  function testFuzz_RevertIf_AnEarlyGuardianVetoIsOverriddenBeforeTheDeadline(uint256 _time) public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByGuardian(_proposal);
    vm.warp(_bound(_time, block.timestamp, vetoGovernor.proposalDeadline(_proposalId) - 1));
    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Defeated));

    _expectRevertOutsideWindow(_proposalId);
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
  }

  /*///////////////////////////////////////////////////////////////
                           At the veto deadline
  //////////////////////////////////////////////////////////////*/

  function test_RevertIf_AGuardianVetoIsOverriddenOneSecondBeforeTheDeadline() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByGuardian(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) - 1);

    _expectRevertOutsideWindow(_proposalId);
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
  }

  function test_GuardianVetoIsOverriddenAtTheDeadline() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByGuardian(_proposal);
    _warpToVetoDeadline(_proposalId);

    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertOverridden(_proposalId);
  }

  /// @dev Pins the current behavior: OpenZeppelin v5's `Governor` keeps a proposal Active through its deadline, so a
  /// token holder veto is not Defeated, and cannot be overridden, until one second after it.
  function test_RevertIf_ATokenHolderVetoIsOverriddenAtTheDeadline() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHoldersAtVotingStart(_proposal);
    _warpToVetoDeadline(_proposalId);

    vm.expectRevert(
      abi.encodeWithSelector(
        GovernorVetoOverride.VetoOverrideUnexpectedState.selector, _proposalId, IGovernor.ProposalState.Active
      )
    );
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Active);
  }

  function test_TokenHolderVetoIsOverriddenOneSecondAfterTheDeadline() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHoldersAtVotingStart(_proposal);
    _warpPastVetoDeadline(_proposalId);

    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertOverridden(_proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                   At the end of the override window
  //////////////////////////////////////////////////////////////*/

  function test_TokenHolderVetoIsOverriddenAtTheDeadlinePlusTheOverrideDuration() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHoldersAtVotingStart(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + _vetoOverrideDuration());

    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertOverridden(_proposalId);
  }

  function test_GuardianVetoIsOverriddenAtTheDeadlinePlusTheOverrideDuration() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByGuardian(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + _vetoOverrideDuration());

    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertOverridden(_proposalId);
  }

  function test_RevertIf_ATokenHolderVetoIsOverriddenOneSecondAfterTheWindowCloses() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHoldersAtVotingStart(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + _vetoOverrideDuration() + 1);

    _expectRevertOutsideWindow(_proposalId);
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
  }

  function test_RevertIf_AGuardianVetoIsOverriddenOneSecondAfterTheWindowCloses() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByGuardian(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + _vetoOverrideDuration() + 1);

    _expectRevertOutsideWindow(_proposalId);
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
  }

  /*///////////////////////////////////////////////////////////////
                          Extended veto deadline
  //////////////////////////////////////////////////////////////*/

  function testFuzz_RevertIf_AGuardianVetoIsOverriddenFromTheOriginalDeadlineToBeforeTheExtendedDeadline(uint256 _time)
    public
  {
    Proposal memory _proposal = _protocolUpgradeProposal();
    (uint256 _proposalId, uint256 _originalDeadline) = _passExtendAndVetoByGuardian(_proposal);
    vm.warp(_bound(_time, _originalDeadline, vetoGovernor.proposalDeadline(_proposalId) - 1));

    _expectRevertOutsideWindow(_proposalId);
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
  }

  function test_GuardianVetoIsOverriddenAtTheExtendedDeadline() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    (uint256 _proposalId,) = _passExtendAndVetoByGuardian(_proposal);
    _warpToVetoDeadline(_proposalId);

    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertOverridden(_proposalId);
  }

  function test_GuardianVetoIsOverriddenAtTheExtendedDeadlinePlusTheOverrideDuration() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    (uint256 _proposalId,) = _passExtendAndVetoByGuardian(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + _vetoOverrideDuration());

    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertOverridden(_proposalId);
  }

  function test_RevertIf_AGuardianVetoIsOverriddenOneSecondAfterTheExtendedWindowCloses() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    (uint256 _proposalId,) = _passExtendAndVetoByGuardian(_proposal);
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + _vetoOverrideDuration() + 1);

    _expectRevertOutsideWindow(_proposalId);
    _overrideVetoFromTheOverrideTimelock(_proposalId);

    _assertNotOverridden(_proposal, _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
  }

  /*///////////////////////////////////////////////////////////////
                              Worst case
  //////////////////////////////////////////////////////////////*/

  function test_SupermajorityOverrideProposedAtTheVetoDeadlineThatUsesEveryDelayStillLandsInTheWindow() public {
    DeploymentParams memory _params = _deploymentParams();
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHoldersAtVotingStart(_proposal);
    uint256 _vetoDeadline = vetoGovernor.proposalDeadline(_proposalId);
    _warpToVetoDeadline(_proposalId);

    // The Supermajority Governor proposal waits out its full 1 day voting delay.
    uint256 _overrideProposalId = _proposeVetoOverride(_proposalId);
    assertEq(
      supermajorityGovernor.proposalSnapshot(_overrideProposalId),
      _vetoDeadline + _params.supermajorityGovernorVotingDelay
    );

    // Quorum is reached in the last second of its 7 day vote, which extends the vote by the 3 day late quorum
    // extension.
    vm.warp(supermajorityGovernor.proposalDeadline(_overrideProposalId));
    _castSupermajorityVote(supermajorityVoter, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.For));
    assertEq(
      supermajorityGovernor.proposalDeadline(_overrideProposalId),
      block.timestamp + _params.supermajorityGovernorLateQuorumVoteExtension
    );

    // It is queued as soon as the extended vote ends and executes once the 1 day override timelock delay passes.
    _warpPastSupermajorityDeadline(_overrideProposalId);
    _queueAndExecuteVetoOverride(_proposalId);

    // Exactly 12 days and 1 second after the veto deadline, inside the 14 day window.
    assertEq(
      block.timestamp,
      _vetoDeadline + _params.supermajorityGovernorVotingDelay + _params.supermajorityGovernorVotingPeriod
        + _params.supermajorityGovernorLateQuorumVoteExtension + 1 + _params.overrideTimelockMinDelay
    );
    assertLe(block.timestamp, _vetoDeadline + _vetoOverrideDuration());
    _assertOverriddenProposalExecutes(_proposal, _proposalId);
  }
}

// Each fuzz run takes a whole proposal through emulated EraVM on an Era mainnet fork, so these tests fuzz fewer runs
// than the default.
// Inline config applies to the concrete contract that runs the tests, not to the abstract suite that defines them.
/// forge-config: default.fuzz.runs = 8
/// forge-config: ci.fuzz.runs = 8
/// forge-config: lite.fuzz.runs = 2
contract ZkProtocolUpgradeGovernanceVetoOverrideWindowEraMainnetScript is
  ZkProtocolUpgradeGovernanceVetoOverrideWindowTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

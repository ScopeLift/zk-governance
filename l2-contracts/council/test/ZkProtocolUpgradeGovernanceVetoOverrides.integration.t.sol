// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVetoOverride} from "council-governance/extensions/GovernorVetoOverride.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

/// @notice The Supermajority Governor overriding a veto: a proposal that calls `overrideVeto` passes with at least the
/// quorum of FOR votes and more FOR than AGAINST, executes through the override timelock, and revives the vetoed
/// council proposal, which then executes through the Protocol Timelock.
abstract contract ZkProtocolUpgradeGovernanceVetoOverridesTest is ZkProtocolUpgradeGovernanceTest {
  address supermajorityOpponent = makeAddr("Supermajority Opponent");
  /// @notice Votes FOR an override with fewer votes than the quorum.
  address supermajoritySupporter = makeAddr("Supermajority Supporter");

  /// @notice `councilMember` passes `_proposal` on the council and token holders veto it with the veto threshold.
  /// Leaves the time just past the veto deadline, where the proposal is Defeated and its override window is open.
  function _passAndVetoByTokenHolders(Proposal memory _proposal) internal returns (uint256 _proposalId) {
    _proposalId = _passCouncilProposal(_proposal);
    _dealAndCastVeto(tokenHolder, _vetoThreshold(), _proposalId);
    _warpPastVetoDeadline(_proposalId);
    require(
      vetoGovernor.state(_proposalId) == IGovernor.ProposalState.Defeated,
      "_passAndVetoByTokenHolders: token holders did not veto the proposal"
    );
  }

  /// @notice Asserts that the veto on `_proposal` still stands: the override did not happen, the proposal is Defeated
  /// on both governors, and neither queueing it on the Protocol Timelock nor executing it through the council works.
  function _assertVetoStands(Proposal memory _proposal, uint256 _proposalId) internal {
    assertFalse(vetoGovernor.isVetoOverridden(_proposalId));
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
                       Override a token holder veto
  //////////////////////////////////////////////////////////////*/

  function testFuzz_SupermajorityOverridesATokenHolderVetoSoTheCouncilProposalExecutes(uint256 _againstVotes) public {
    // Fewer AGAINST votes than the FOR votes of `supermajorityVoter`, who holds exactly the quorum.
    _againstVotes = _bound(_againstVotes, 1, _supermajorityQuorum() - 1);
    _dealAndDelegateZk(supermajorityOpponent, _againstVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHolders(_proposal);

    // The Supermajority Governor passes the override with the quorum of FOR votes and more FOR than AGAINST.
    uint256 _overrideProposalId = _proposeVetoOverride(_proposalId);
    _warpToSupermajorityVoting(_overrideProposalId);
    _castSupermajorityVote(supermajorityVoter, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.For));
    _castSupermajorityVote(supermajorityOpponent, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.Against));
    _warpPastSupermajorityDeadline(_overrideProposalId);
    assertEq(uint8(supermajorityGovernor.state(_overrideProposalId)), uint8(IGovernor.ProposalState.Succeeded));

    // The override waits 1 day in the override timelock, then the timelock calls `overrideVeto`.
    Proposal memory _override = _vetoOverrideProposal(_proposalId);
    supermajorityGovernor.queue(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));
    uint256 _overrideDelay = _deploymentParams().overrideTimelockMinDelay;
    assertEq(overrideTimelock.getMinDelay(), _overrideDelay);
    vm.warp(block.timestamp + _overrideDelay - 1);
    vm.expectRevert("TimelockController: operation is not ready");
    supermajorityGovernor.execute(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));
    vm.warp(block.timestamp + 1);
    supermajorityGovernor.execute(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));

    _assertOverriddenProposalExecutes(_proposal, _proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                         Override a guardian veto
  //////////////////////////////////////////////////////////////*/

  /// @dev The override role revives any Defeated proposal, including one the guardian vetoed, as
  /// `ZkProtocolUpgradeVetoGovernor` documents.
  function test_SupermajorityOverridesAGuardianVetoSoTheCouncilProposalExecutes() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpToVetoVoting(_proposalId);
    _vetoByGuardian(_proposalId);
    _warpPastVetoDeadline(_proposalId);
    _assertStates(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);

    _overrideVetoThroughSupermajority(_proposalId);

    assertTrue(vetoGovernor.guardianVetoed(_proposalId));
    _assertOverriddenProposalExecutes(_proposal, _proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                             Failed overrides
  //////////////////////////////////////////////////////////////*/

  function testFuzz_VetoStandsWhenTheOverrideGetsFewerForVotesThanTheQuorum(uint256 _forVotes) public {
    _forVotes = _bound(_forVotes, 1, _supermajorityQuorum() - 1);
    // A voter below the quorum votes FOR; `supermajorityVoter` only proposes.
    _dealAndDelegateZk(supermajoritySupporter, _forVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHolders(_proposal);

    uint256 _overrideProposalId = _proposeVetoOverride(_proposalId);
    _warpToSupermajorityVoting(_overrideProposalId);
    _castSupermajorityVote(supermajoritySupporter, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.For));
    _warpPastSupermajorityDeadline(_overrideProposalId);

    assertEq(uint8(supermajorityGovernor.state(_overrideProposalId)), uint8(IGovernor.ProposalState.Defeated));
    Proposal memory _override = _vetoOverrideProposal(_proposalId);
    vm.expectRevert("Governor: proposal not successful");
    supermajorityGovernor.queue(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));
    _assertVetoStands(_proposal, _proposalId);
  }

  function testFuzz_VetoStandsWhenTheOverrideMeetsTheQuorumButDoesNotGetMoreForThanAgainstVotes(uint256 _againstVotes)
    public
  {
    // At least as many AGAINST votes as the quorum of FOR votes `supermajorityVoter` casts. The cap, the supply less
    // what `supermajorityVoter` and the vetoing `tokenHolder` are dealt, is only a loose bound that keeps it realistic.
    _againstVotes =
      _bound(_againstVotes, _supermajorityQuorum(), _zkTotalSupply() - _supermajorityQuorum() - _vetoThreshold());
    _dealAndDelegateZk(supermajorityOpponent, _againstVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHolders(_proposal);

    uint256 _overrideProposalId = _proposeVetoOverride(_proposalId);
    _warpToSupermajorityVoting(_overrideProposalId);
    _castSupermajorityVote(supermajorityVoter, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.For));
    _castSupermajorityVote(supermajorityOpponent, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.Against));
    _warpPastSupermajorityDeadline(_overrideProposalId);

    assertEq(uint8(supermajorityGovernor.state(_overrideProposalId)), uint8(IGovernor.ProposalState.Defeated));
    Proposal memory _override = _vetoOverrideProposal(_proposalId);
    vm.expectRevert("Governor: proposal not successful");
    supermajorityGovernor.queue(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));
    _assertVetoStands(_proposal, _proposalId);
  }

  /*///////////////////////////////////////////////////////////////
                                 Access
  //////////////////////////////////////////////////////////////*/

  function testFuzz_RevertIf_AnyoneButTheOverrideTimelockOverridesAVeto(address _caller) public {
    _assumeSafeFuzzedCaller(_caller);
    vm.assume(_caller != address(overrideTimelock));
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passAndVetoByTokenHolders(_proposal);

    vm.expectRevert(abi.encodeWithSelector(GovernorVetoOverride.VetoOverrideUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    vetoGovernor.overrideVeto(_proposalId);

    _assertVetoStands(_proposal, _proposalId);
  }

  function test_RevertIf_TheOverrideTimelockOverridesAProposalThatIsNotDefeated() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);

    vm.expectRevert(
      abi.encodeWithSelector(
        GovernorVetoOverride.VetoOverrideUnexpectedState.selector, _proposalId, IGovernor.ProposalState.Succeeded
      )
    );
    vm.prank(address(overrideTimelock));
    vetoGovernor.overrideVeto(_proposalId);

    assertFalse(vetoGovernor.isVetoOverridden(_proposalId));
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
  }

  function test_RevertIf_TheSupermajorityExecutesAnOverrideOfAProposalThatIsNotDefeated() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);

    uint256 _overrideProposalId = _proposeVetoOverride(_proposalId);
    _warpToSupermajorityVoting(_overrideProposalId);
    _castSupermajorityVote(supermajorityVoter, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.For));
    _warpPastSupermajorityDeadline(_overrideProposalId);
    Proposal memory _override = _vetoOverrideProposal(_proposalId);
    supermajorityGovernor.queue(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));
    vm.warp(block.timestamp + overrideTimelock.getMinDelay());
    // The override timelock holds the override role and the window is still open, so the only check `overrideVeto`
    // fails is the one on the proposal's state.
    assertEq(vetoGovernor.vetoOverrideRole(), address(overrideTimelock));
    assertLe(block.timestamp, vetoGovernor.proposalDeadline(_proposalId) + vetoGovernor.vetoOverrideDuration());
    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));

    // `overrideVeto` reverts, and OpenZeppelin v4's `TimelockController` replaces the reason with its own, so the test
    // also expects the call to `overrideVeto` it made.
    vm.expectCall(address(vetoGovernor), abi.encodeCall(vetoGovernor.overrideVeto, (_proposalId)));
    vm.expectRevert("TimelockController: underlying transaction reverted");
    supermajorityGovernor.execute(_override.targets, _override.values, _override.calldatas, _descriptionHash(_override));

    assertFalse(vetoGovernor.isVetoOverridden(_proposalId));
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);
  }
}

// Each fuzz run takes a whole proposal through emulated EraVM on an Era mainnet fork, and each fuzzed address is a new
// account to fetch from the fork, so these tests fuzz fewer runs than the default.
// Inline config applies to the concrete contract that runs the tests, not to the abstract suite that defines them.
/// forge-config: default.fuzz.runs = 8
/// forge-config: ci.fuzz.runs = 8
/// forge-config: lite.fuzz.runs = 2
contract ZkProtocolUpgradeGovernanceVetoOverridesEraMainnetScript is
  ZkProtocolUpgradeGovernanceVetoOverridesTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

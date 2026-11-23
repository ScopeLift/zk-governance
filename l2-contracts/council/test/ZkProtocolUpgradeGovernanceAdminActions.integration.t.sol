// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorVetoGuardian} from "council-governance/extensions/GovernorVetoGuardian.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

/// @notice The system after the Protocol Timelock role migration, and the changes the governance admin, the aliased L1
/// Protocol Upgrade Handler, makes to it: governor settings, council seats and the veto guardian.
abstract contract ZkProtocolUpgradeGovernanceAdminActionsTest is ZkProtocolUpgradeGovernanceTest {
  address newCouncilMember = makeAddr("New Council Member");
  address newVetoGuardian = makeAddr("New Veto Guardian");
  address seatlessProposer = makeAddr("Seatless Proposer");
  address protocolGovernorDelegate = makeAddr("Protocol Governor Delegate");

  function _governanceAdmin() internal view returns (address) {
    return _deploymentParams().governanceAdmin;
  }

  /// @notice Excludes the governance admin, which owns both governors and `CouncilERC20`, and the addresses no fuzzed
  /// caller can be.
  function _assumeNotTheGovernanceAdmin(address _caller) internal view {
    _assumeSafeFuzzedCaller(_caller);
    vm.assume(_caller != _governanceAdmin());
  }

  function _expectRevertNotTheGovernanceAdmin(address _caller) internal {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
  }

  /// @notice Expects the next `propose` on the Council Governor to revert because `_proposer` holds no seat.
  function _expectRevertNoCouncilSeat(address _proposer) internal {
    vm.expectRevert(
      abi.encodeWithSelector(
        IGovernor.GovernorInsufficientProposerVotes.selector, _proposer, 0, councilGovernor.proposalThreshold()
      )
    );
  }

  /// @notice `_caller` calls every function on the Veto Governor that only the governance admin may call, each with a
  /// value other than the current one, and each call is expected to revert because `_caller` is not the admin.
  function _expectRevertOnEveryVetoGovernorSettingChange(address _caller) internal {
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVetoThreshold(1);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVetoGuardian(_caller);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVetoOverrideRole(_caller);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVetoOverrideDuration(type(uint48).max);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVotingDelay(0);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVotingPeriod(1);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setProposalThreshold(1);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setVotingPeriodExtension(0);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.setMinorVetoExtensionThresholdPct(0);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.updateVetoThresholdNumerator(0);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.updateTimelock(TimelockController(payable(_caller)));
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    vetoGovernor.relay(_caller, 0, "");
  }

  /// @notice Asserts that the Veto Governor's settings are the ones it was deployed with.
  function _assertVetoGovernorSettingsUnchanged() internal view {
    DeploymentParams memory _params = _deploymentParams();
    assertEq(vetoGovernor.vetoThreshold(block.timestamp), _vetoThreshold());
    assertEq(vetoGovernor.vetoGuardian(), _params.vetoGovernorVetoGuardian);
    assertEq(vetoGovernor.vetoOverrideRole(), address(overrideTimelock));
    assertEq(vetoGovernor.vetoOverrideDuration(), _params.vetoGovernorVetoOverrideDuration);
    assertEq(vetoGovernor.votingDelay(), _params.vetoGovernorVotingDelay);
    assertEq(vetoGovernor.votingPeriod(), _params.vetoGovernorVotingPeriod);
    assertEq(vetoGovernor.proposalThreshold(), _params.vetoGovernorProposalThreshold);
    assertEq(vetoGovernor.votingPeriodExtension(), _params.vetoGovernorVotingPeriodExtension);
    assertEq(vetoGovernor.minorVetoExtensionThresholdPct(), _params.vetoGovernorVotingPeriodExtensionThresholdPct);
    assertEq(vetoGovernor.timelock(), address(protocolTimelock));
  }

  /// @notice `_caller` calls every function on the Council Governor that only the governance admin may call, each with
  /// a value other than the current one, and each call is expected to revert because `_caller` is not the admin.
  function _expectRevertOnEveryCouncilGovernorSettingChange(address _caller) internal {
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.setVotingDelay(0);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.setVotingPeriod(1);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.setProposalThreshold(0);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.updateQuorumNumerator(1);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.updateSuperQuorumNumerator(1);
    // Pointing the council at a veto governor the caller controls would skip the token holder and guardian vetoes.
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.setCouncilVetoGovernor(IGovernor(_caller));
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilGovernor.relay(_caller, 0, "");
  }

  /// @notice Asserts that the Council Governor's settings are the ones it was deployed with. Its quorum fractions are
  /// not deployment parameters, and both are zero.
  function _assertCouncilGovernorSettingsUnchanged() internal view {
    DeploymentParams memory _params = _deploymentParams();
    assertEq(councilGovernor.votingDelay(), _params.councilGovernorVotingDelay);
    assertEq(councilGovernor.votingPeriod(), _params.councilGovernorVotingPeriod);
    assertEq(councilGovernor.proposalThreshold(), _params.councilGovernorProposalThreshold);
    assertEq(address(councilGovernor.councilVetoGovernor()), address(vetoGovernor));
    assertEq(councilGovernor.quorumNumerator(), 0);
    assertEq(councilGovernor.superQuorumNumerator(), 0);
  }

  /*///////////////////////////////////////////////////////////////
                           After the migration
  //////////////////////////////////////////////////////////////*/

  function test_RevertIf_ZkProtocolGovernorQueuesAPassedProposalOnTheProtocolTimelock() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _quorum = protocolGovernor.quorum(block.timestamp - 1);
    _dealAndDelegateZk(protocolGovernorDelegate, _quorum);
    vm.warp(block.timestamp + 1);

    // A ZkProtocolGovernor proposal still passes its vote.
    vm.prank(protocolGovernorDelegate);
    uint256 _proposalId =
      protocolGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
    vm.warp(protocolGovernor.proposalSnapshot(_proposalId) + 1);
    vm.prank(protocolGovernorDelegate);
    protocolGovernor.castVote(_proposalId, uint8(GovernorCountingSimple.VoteType.For));
    vm.warp(protocolGovernor.proposalDeadline(_proposalId) + 1);
    assertEq(uint8(protocolGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));

    // It can no longer schedule on the Protocol Timelock.
    _expectRevertMissingTimelockRole(address(protocolGovernor), PROPOSER_ROLE);
    protocolGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));

    _assertUpgradeNotExecuted();
  }

  function test_RevertIf_ZkProtocolGovernorExecutesOrCancelsAnOperationOnTheProtocolTimelock() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    // The Veto Governor schedules an operation, which ZkProtocolGovernor then tries to execute.
    uint256 _delay = protocolTimelock.getMinDelay();
    vm.prank(address(vetoGovernor));
    protocolTimelock.scheduleBatch(
      _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), bytes32(0), _delay
    );
    vm.warp(block.timestamp + _delay);

    _expectRevertMissingTimelockRole(address(protocolGovernor), EXECUTOR_ROLE);
    vm.prank(address(protocolGovernor));
    protocolTimelock.executeBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), bytes32(0));

    // Nor can it cancel the operation.
    bytes32 _operationId = protocolTimelock.hashOperationBatch(
      _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), bytes32(0)
    );
    _expectRevertMissingTimelockRole(address(protocolGovernor), CANCELLER_ROLE);
    vm.prank(address(protocolGovernor));
    protocolTimelock.cancel(_operationId);

    _assertUpgradeNotExecuted();
  }

  function test_CouncilProposalExecutesThroughTheProtocolTimelockAfterTheMigration() public {
    Proposal memory _proposal = _protocolUpgradeProposal();

    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  /*///////////////////////////////////////////////////////////////
                            Governance admin
  //////////////////////////////////////////////////////////////*/

  /// @dev The Era mainnet configuration itself checks that the governance admin is the aliased L1 Protocol Upgrade
  /// Handler.
  function test_GovernanceAdminOwnsBothGovernorsAndTheCouncilToken() public view {
    assertEq(councilGovernor.owner(), _governanceAdmin());
    assertEq(vetoGovernor.owner(), _governanceAdmin());
    assertEq(councilToken.owner(), _governanceAdmin());
  }

  function test_GovernanceAdminChangesTheVetoGovernorsSettings() public {
    address _newOverrideRole = makeAddr("New Override Role");
    vm.startPrank(_governanceAdmin());
    vetoGovernor.setVetoThreshold(1_000_000_000e18);
    vetoGovernor.setVetoGuardian(newVetoGuardian);
    vetoGovernor.setVetoOverrideRole(_newOverrideRole);
    vetoGovernor.setVetoOverrideDuration(21 days);
    vm.stopPrank();

    assertEq(vetoGovernor.vetoThreshold(block.timestamp), 1_000_000_000e18);
    assertEq(vetoGovernor.vetoGuardian(), newVetoGuardian);
    assertEq(vetoGovernor.vetoOverrideRole(), _newOverrideRole);
    assertEq(vetoGovernor.vetoOverrideDuration(), 21 days);
  }

  function test_GovernanceAdminChangesTheCouncilGovernorsSettings() public {
    vm.startPrank(_governanceAdmin());
    councilGovernor.setVotingDelay(2 days);
    councilGovernor.setVotingPeriod(5 days);
    councilGovernor.setProposalThreshold(0);
    vm.stopPrank();

    assertEq(councilGovernor.votingDelay(), 2 days);
    assertEq(councilGovernor.votingPeriod(), 5 days);
    assertEq(councilGovernor.proposalThreshold(), 0);

    // A new proposal runs on the new settings, and with no threshold an account without a seat can make it.
    uint256 _proposalId = _proposeToCouncil(seatlessProposer, _protocolUpgradeProposal());
    assertEq(councilGovernor.proposalSnapshot(_proposalId), block.timestamp + 2 days);
    assertEq(councilGovernor.proposalDeadline(_proposalId), block.timestamp + 2 days + 5 days);
  }

  function testFuzz_RevertIf_AnyoneButTheGovernanceAdminChangesTheVetoGovernorsSettings(address _caller) public {
    _assumeNotTheGovernanceAdmin(_caller);

    _expectRevertOnEveryVetoGovernorSettingChange(_caller);

    _assertVetoGovernorSettingsUnchanged();
  }

  /// @dev OpenZeppelin's default `onlyGovernance` authorizes a governor's executor, here the Protocol Timelock, which
  /// would let an executed council proposal change the veto rules it passed under. The fuzzed caller above is never
  /// that address.
  function test_RevertIf_TheProtocolTimelockChangesTheVetoGovernorsSettings() public {
    _expectRevertOnEveryVetoGovernorSettingChange(address(protocolTimelock));

    _assertVetoGovernorSettingsUnchanged();
  }

  function testFuzz_RevertIf_AnyoneButTheGovernanceAdminChangesTheCouncilGovernorsSettings(address _caller) public {
    _assumeNotTheGovernanceAdmin(_caller);

    _expectRevertOnEveryCouncilGovernorSettingChange(_caller);

    _assertCouncilGovernorSettingsUnchanged();
  }

  /// @dev OpenZeppelin's default `onlyGovernance` authorizes a governor's executor, here the Veto Governor. The fuzzed
  /// caller above is never that address.
  function test_RevertIf_TheVetoGovernorChangesTheCouncilGovernorsSettings() public {
    _expectRevertOnEveryCouncilGovernorSettingChange(address(vetoGovernor));

    _assertCouncilGovernorSettingsUnchanged();
  }

  /*///////////////////////////////////////////////////////////////
                                  Seats
  //////////////////////////////////////////////////////////////*/

  function test_MemberWhoseSeatTheAdminBurnsCanNoLongerPropose() public {
    vm.prank(_governanceAdmin());
    councilToken.burn(councilMember, _deploymentParams().votesPerCouncilSeat);
    // The proposer's votes are read one second before it proposes.
    vm.warp(block.timestamp + 1);

    _expectRevertNoCouncilSeat(councilMember);
    _proposeToCouncil(councilMember, _protocolUpgradeProposal());
  }

  /// @dev Pins the current behavior: OpenZeppelin v5's `Governor` accepts a vote with no weight, so the vote of a
  /// member removed before the proposal's snapshot does not revert. It counts nothing, and the proposal does not pass.
  function test_VoteOfAMemberWhoseSeatTheAdminBurnsBeforeTheProposalsSnapshotCountsNothing() public {
    address[] memory _members = _deploymentParams().councilMembers;
    address _removedMember = _members[1];
    vm.prank(_governanceAdmin());
    councilToken.burn(_removedMember, _deploymentParams().votesPerCouncilSeat);
    vm.warp(block.timestamp + 1);

    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(_removedMember, _proposalId, uint8(GovernorCountingSimple.VoteType.For));

    (, uint256 _forVotes,) = councilGovernor.proposalVotes(_proposalId);
    assertEq(_forVotes, 0);
    assertTrue(councilGovernor.hasVoted(_proposalId, _removedMember));
    _warpPastCouncilDeadline(_proposalId);
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Defeated));
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Succeeded);
    _queueOnCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }

  /// @dev Pins the current behavior: votes are read at the proposal's snapshot, so a member whose seat the admin burns
  /// once voting has started still votes with a full seat on that proposal, and their FOR vote alone passes it.
  function test_MemberWhoseSeatTheAdminBurnsAfterTheProposalsSnapshotStillPassesItWithTheirVote() public {
    address _removedMember = _deploymentParams().councilMembers[1];
    uint256 _seat = _deploymentParams().votesPerCouncilSeat;
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);

    vm.prank(_governanceAdmin());
    councilToken.burn(_removedMember, _seat);
    assertEq(councilToken.getVotes(_removedMember), 0);
    _castCouncilVote(_removedMember, _proposalId, uint8(GovernorCountingSimple.VoteType.For));

    (, uint256 _forVotes,) = councilGovernor.proposalVotes(_proposalId);
    assertEq(_forVotes, _seat);
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));
  }

  function test_NewMemberTheAdminMintsASeatForProposesAndPassesAProposalThatExecutes() public {
    vm.prank(_governanceAdmin());
    councilToken.mint(newCouncilMember, _deploymentParams().votesPerCouncilSeat);
    vm.warp(block.timestamp + 1);
    Proposal memory _proposal = _protocolUpgradeProposal();

    uint256 _proposalId = _proposeToCouncil(newCouncilMember, _proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(newCouncilMember, _proposalId, uint8(GovernorCountingSimple.VoteType.For));
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    _queueOnCouncil(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function testFuzz_RevertIf_AnyoneButTheGovernanceAdminMintsOrBurnsASeat(address _caller) public {
    _assumeNotTheGovernanceAdmin(_caller);
    uint256 _seat = _deploymentParams().votesPerCouncilSeat;

    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilToken.mint(newCouncilMember, _seat);
    _expectRevertNotTheGovernanceAdmin(_caller);
    vm.prank(_caller);
    councilToken.burn(councilMember, _seat);

    assertEq(councilToken.balanceOf(newCouncilMember), 0);
    assertEq(councilToken.balanceOf(councilMember), _seat);
  }

  /*///////////////////////////////////////////////////////////////
                            Replaced guardian
  //////////////////////////////////////////////////////////////*/

  function test_RevertIf_TheReplacedGuardianVetoes() public {
    address _oldGuardian = vetoGovernor.vetoGuardian();
    vm.prank(_governanceAdmin());
    vetoGovernor.setVetoGuardian(newVetoGuardian);
    uint256 _proposalId = _passCouncilProposal(_protocolUpgradeProposal());

    vm.expectRevert(GovernorVetoGuardian.GovernorVetoGuardian_Unauthorized.selector);
    _vetoByGuardian(_oldGuardian, _proposalId);

    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Pending);
  }

  function test_NewGuardianVetoesAProposalSoItIsDefeatedOnBothGovernors() public {
    vm.prank(_governanceAdmin());
    vetoGovernor.setVetoGuardian(newVetoGuardian);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    _vetoByGuardian(newVetoGuardian, _proposalId);

    _assertStates(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Defeated);
    _warpPastVetoDeadline(_proposalId);
    _expectRevertUnexpectedState(_proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Succeeded);
    _queueOnProtocolTimelock(_proposal);
    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Defeated, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Queued
    );
    _executeThroughCouncil(_proposal);
    _assertUpgradeNotExecuted();
  }
}

// Each fuzzed address is a new account to fetch from the Era mainnet fork, so these tests fuzz fewer runs than the
// default.
// Inline config applies to the concrete contract that runs the tests, not to the abstract suite that defines them.
/// forge-config: default.fuzz.runs = 8
/// forge-config: ci.fuzz.runs = 8
/// forge-config: lite.fuzz.runs = 2
contract ZkProtocolUpgradeGovernanceAdminActionsEraMainnetScript is
  ZkProtocolUpgradeGovernanceAdminActionsTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

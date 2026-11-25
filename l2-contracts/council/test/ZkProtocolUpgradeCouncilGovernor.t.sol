// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BasicCouncilGovernor} from "council-governance/BasicCouncilGovernor.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {FakeCouncilVetoGovernor} from "test/fakes/FakeCouncilVetoGovernor.sol";
import {Constants} from "test/utils/Constants.sol";
import {TestHelpers} from "test/utils/TestHelpers.sol";

contract ZkProtocolUpgradeCouncilGovernorTest is TestHelpers, Constants {
  CouncilERC20 councilToken;
  FakeCouncilVetoGovernor vetoGovernor;
  ZkProtocolUpgradeCouncilGovernor governor;
  address governorAdmin = makeAddr("Governor Admin");
  address proposalTarget = makeAddr("Target");
  address[] members;

  function setUp() public virtual {
    // Starts at an arbitrary but realistic Unix time (Nov 2023); no test depends on the exact value.
    vm.warp(1_700_000_000);
    councilToken = new CouncilERC20("Council Seat", "SEAT", address(this), VOTES_PER_SEAT);
    vetoGovernor = new FakeCouncilVetoGovernor();
    governor = new ZkProtocolUpgradeCouncilGovernor(
      "Council Governor",
      councilToken,
      IGovernor(address(vetoGovernor)),
      governorAdmin,
      _councilParams(0, 0),
      QUORUM_SEATS
    );
  }

  function _councilParams(uint256 _quorumFraction, uint256 _superQuorumFraction)
    internal
    pure
    returns (BasicCouncilGovernor.InitialCouncilParams memory)
  {
    return BasicCouncilGovernor.InitialCouncilParams({
      initialVotingDelay: VOTING_DELAY,
      initialVotingPeriod: VOTING_PERIOD,
      initialProposalThreshold: VOTES_PER_SEAT,
      initialQuorumFraction: _quorumFraction,
      initialSuperQuorumFraction: _superQuorumFraction
    });
  }

  // Mints a full seat to each of `_memberCount` new members.
  function _seatMembers(uint256 _memberCount) internal {
    for (uint256 _i = 0; _i < _memberCount; _i += 1) {
      address _member = makeAddr(string.concat("Member ", vm.toString(_i)));
      members.push(_member);
      councilToken.mint(_member, VOTES_PER_SEAT);
    }
    // Seats count from the timestamp after they are minted, so move past it before any proposal is created.
    vm.warp(block.timestamp + 1);
  }

  // The actions of the proposal every test submits: one empty call to `proposalTarget`.
  function _proposalActions()
    internal
    view
    returns (address[] memory _targets, uint256[] memory _values, bytes[] memory _calldatas)
  {
    _targets = new address[](1);
    _targets[0] = proposalTarget;
    _values = new uint256[](1);
    _calldatas = new bytes[](1);
  }

  // Mints less than a full seat to a new member.
  function _mintPartialSeat(string memory _name, uint256 _votes) internal returns (address _member) {
    _member = makeAddr(_name);
    councilToken.mint(_member, _votes);
    vm.warp(block.timestamp + 1);
  }

  // Proposes from the first member and moves to the start of voting.
  function _proposeAndOpenVoting(string memory _description) internal returns (uint256 _proposalId) {
    (address[] memory _targets, uint256[] memory _values, bytes[] memory _calldatas) = _proposalActions();
    vm.prank(members[0]);
    _proposalId = governor.propose(_targets, _values, _calldatas, _description);
    vm.warp(governor.proposalSnapshot(_proposalId) + 1);
  }

  // Passes the proposal with FOR votes from `QUORUM_SEATS` members and queues it, which submits it to the veto
  // governor. At least `QUORUM_SEATS` members must be seated.
  function _passAndQueue(string memory _description) internal returns (uint256 _proposalId) {
    _proposalId = _proposeAndOpenVoting(_description);
    _castForVotes(_proposalId, QUORUM_SEATS);
    (address[] memory _targets, uint256[] memory _values, bytes[] memory _calldatas) = _proposalActions();
    governor.queue(_targets, _values, _calldatas, keccak256(bytes(_description)));
  }

  function _castVote(uint256 _proposalId, address _voter, GovernorCountingSimple.VoteType _support) internal {
    vm.prank(_voter);
    governor.castVote(_proposalId, uint8(_support));
  }

  // Casts a FOR vote from each of the first `_memberCount` members, which must already be seated.
  function _castForVotes(uint256 _proposalId, uint256 _memberCount) internal {
    for (uint256 _i = 0; _i < _memberCount; _i += 1) {
      _castVote(_proposalId, members[_i], GovernorCountingSimple.VoteType.For);
    }
  }

  // Each bit of `_supportBits` picks whether a member votes AGAINST (0) or ABSTAIN (1).
  function _againstOrAbstain(uint256 _supportBits, uint256 _memberIndex)
    internal
    pure
    returns (GovernorCountingSimple.VoteType)
  {
    if ((_supportBits >> _memberIndex) & 1 == 0) {
      return GovernorCountingSimple.VoteType.Against;
    }
    return GovernorCountingSimple.VoteType.Abstain;
  }

  function _jumpPastTheProposalDeadline(uint256 _proposalId) internal {
    vm.warp(governor.proposalDeadline(_proposalId) + 1);
  }

  function _assertState(uint256 _proposalId, IGovernor.ProposalState _expectedState) internal view {
    assertEq(uint8(governor.state(_proposalId)), uint8(_expectedState));
  }
}

contract Constructor is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_SetsQuorumToTheGivenNumberOfSeats(uint256 _votesPerSeat, uint256 _quorumSeats) public {
    _votesPerSeat = bound(_votesPerSeat, 1, type(uint256).max);
    // The quorum in votes, seats times votes per seat, has to fit in a uint256.
    _quorumSeats = bound(_quorumSeats, 1, type(uint256).max / _votesPerSeat);
    CouncilERC20 _councilToken = new CouncilERC20("Council Seat", "SEAT", address(this), _votesPerSeat);

    ZkProtocolUpgradeCouncilGovernor _governor = new ZkProtocolUpgradeCouncilGovernor(
      "Council Governor", _councilToken, IGovernor(address(0)), governorAdmin, _councilParams(0, 0), _quorumSeats
    );

    assertEq(_governor.QUORUM(), _quorumSeats * _votesPerSeat);
  }

  function testFuzz_RevertIf_TheQuorumIsZeroSeats(uint256 _votesPerSeat) public {
    _votesPerSeat = bound(_votesPerSeat, 1, type(uint256).max);
    CouncilERC20 _councilToken = new CouncilERC20("Council Seat", "SEAT", address(this), _votesPerSeat);
    BasicCouncilGovernor.InitialCouncilParams memory _params = _councilParams(0, 0);

    vm.expectRevert(ZkProtocolUpgradeCouncilGovernor.ZkProtocolUpgradeCouncilGovernor__InvalidQuorumSeats.selector);
    new ZkProtocolUpgradeCouncilGovernor(
      "Council Governor", _councilToken, IGovernor(address(0)), governorAdmin, _params, 0
    );
  }

  function testFuzz_RevertIf_AQuorumFractionIsConfigured(uint256 _quorumFraction) public {
    _quorumFraction = bound(_quorumFraction, 1, 100);
    BasicCouncilGovernor.InitialCouncilParams memory _params = _councilParams(_quorumFraction, 0);

    vm.expectRevert(ZkProtocolUpgradeCouncilGovernor.ZkProtocolUpgradeCouncilGovernor__QuorumFractionDisabled.selector);
    new ZkProtocolUpgradeCouncilGovernor(
      "Council Governor", councilToken, IGovernor(address(0)), governorAdmin, _params, QUORUM_SEATS
    );
  }

  function testFuzz_RevertIf_ASuperQuorumFractionIsConfigured(uint256 _superQuorumFraction) public {
    _superQuorumFraction = bound(_superQuorumFraction, 1, 100);
    BasicCouncilGovernor.InitialCouncilParams memory _params = _councilParams(0, _superQuorumFraction);

    vm.expectRevert(ZkProtocolUpgradeCouncilGovernor.ZkProtocolUpgradeCouncilGovernor__QuorumFractionDisabled.selector);
    new ZkProtocolUpgradeCouncilGovernor(
      "Council Governor", councilToken, IGovernor(address(0)), governorAdmin, _params, QUORUM_SEATS
    );
  }
}

contract CountingMode is ZkProtocolUpgradeCouncilGovernorTest {
  function test_ReportsThatOnlyForVotesCountTowardQuorum() public view {
    assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=bravo");
  }
}

contract Quorum is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_TheVotesOfTheQuorumSeatsForAnyNumberOfMembers(uint256 _memberCount, uint256 _timepoint) public {
    _seatMembers(bound(_memberCount, 1, MAX_MEMBER_COUNT));

    assertEq(governor.quorum(_timepoint), QUORUM_SEATS * VOTES_PER_SEAT);
  }
}

contract SuperQuorum is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_TheVotesOfTheQuorumSeatsForAnyNumberOfMembers(uint256 _memberCount, uint256 _timepoint) public {
    _seatMembers(bound(_memberCount, 1, MAX_MEMBER_COUNT));

    assertEq(governor.superQuorum(_timepoint), QUORUM_SEATS * VOTES_PER_SEAT);
  }
}

contract Propose is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_RevertIf_TheProposerHoldsLessThanOneSeat(uint256 _partialSeatVotes) public {
    _partialSeatVotes = bound(_partialSeatVotes, 0, VOTES_PER_SEAT - 1);
    _seatMembers(1);
    address _proposer = _mintPartialSeat("Partial Member", _partialSeatVotes);
    (address[] memory _targets, uint256[] memory _values, bytes[] memory _calldatas) = _proposalActions();

    vm.expectRevert(
      abi.encodeWithSelector(
        IGovernor.GovernorInsufficientProposerVotes.selector, _proposer, _partialSeatVotes, VOTES_PER_SEAT
      )
    );
    vm.prank(_proposer);
    governor.propose(_targets, _values, _calldatas, PROPOSAL_DESCRIPTION);
  }
}

contract State is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_SucceededAsSoonAsAQuorumOfMembersVotesForWithAnyNumberOfMembers(uint256 _memberCount) public {
    _seatMembers(bound(_memberCount, QUORUM_SEATS, MAX_MEMBER_COUNT));
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    _castForVotes(_proposalId, QUORUM_SEATS);

    _assertState(_proposalId, IGovernor.ProposalState.Succeeded);
  }

  function testFuzz_ActiveThenDefeatedWhenOneMemberFewerThanAQuorumVotesFor(uint256 _memberCount) public {
    _seatMembers(bound(_memberCount, QUORUM_SEATS, MAX_MEMBER_COUNT));
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    _castForVotes(_proposalId, QUORUM_SEATS - 1);
    _assertState(_proposalId, IGovernor.ProposalState.Active);

    _jumpPastTheProposalDeadline(_proposalId);
    _assertState(_proposalId, IGovernor.ProposalState.Defeated);
  }

  function testFuzz_SucceededWhenEveryOtherMemberHasVotedAgainstOrAbstained(uint256 _memberCount, uint256 _supportBits)
    public
  {
    _seatMembers(bound(_memberCount, QUORUM_SEATS + 1, MAX_MEMBER_COUNT));
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    // The other members vote first, since the FOR vote that reaches quorum ends voting.
    for (uint256 _i = QUORUM_SEATS; _i < members.length; _i += 1) {
      _castVote(_proposalId, members[_i], _againstOrAbstain(_supportBits, _i));
    }
    _castForVotes(_proposalId, QUORUM_SEATS);

    _assertState(_proposalId, IGovernor.ProposalState.Succeeded);
  }

  function testFuzz_ActiveUntilTheDeadlineWhenNoMemberVotesFor(uint256 _memberCount, uint256 _supportBits) public {
    _seatMembers(bound(_memberCount, 1, MAX_MEMBER_COUNT));
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    for (uint256 _i = 0; _i < members.length; _i += 1) {
      _castVote(_proposalId, members[_i], _againstOrAbstain(_supportBits, _i));
    }

    vm.warp(governor.proposalDeadline(_proposalId));
    _assertState(_proposalId, IGovernor.ProposalState.Active);
  }

  function testFuzz_DefeatedAfterTheDeadlineWhenNoMemberVotesFor(uint256 _memberCount, uint256 _supportBits) public {
    _seatMembers(bound(_memberCount, 1, MAX_MEMBER_COUNT));
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    for (uint256 _i = 0; _i < members.length; _i += 1) {
      _castVote(_proposalId, members[_i], _againstOrAbstain(_supportBits, _i));
    }
    _jumpPastTheProposalDeadline(_proposalId);

    _assertState(_proposalId, IGovernor.ProposalState.Defeated);
  }

  function testFuzz_ActiveThenDefeatedWhenForVotesAreLessThanOneSeatShortOfQuorum(uint256 _partialSeatVotes) public {
    _partialSeatVotes = bound(_partialSeatVotes, 1, VOTES_PER_SEAT - 1);
    _seatMembers(QUORUM_SEATS - 1);
    address _partialMember = _mintPartialSeat("Partial Member", _partialSeatVotes);
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    _castForVotes(_proposalId, QUORUM_SEATS - 1);
    _castVote(_proposalId, _partialMember, GovernorCountingSimple.VoteType.For);
    _assertState(_proposalId, IGovernor.ProposalState.Active);

    _jumpPastTheProposalDeadline(_proposalId);
    _assertState(_proposalId, IGovernor.ProposalState.Defeated);
  }

  function testFuzz_SucceededAsSoonAsPartialForVotesCompleteTheQuorum(uint256 _firstPartialSeatVotes) public {
    _firstPartialSeatVotes = bound(_firstPartialSeatVotes, 1, VOTES_PER_SEAT - 1);
    _seatMembers(QUORUM_SEATS - 1);
    address _firstPartialMember = _mintPartialSeat("First Partial Member", _firstPartialSeatVotes);
    address _secondPartialMember = _mintPartialSeat("Second Partial Member", VOTES_PER_SEAT - _firstPartialSeatVotes);
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);

    _castForVotes(_proposalId, QUORUM_SEATS - 1);
    _castVote(_proposalId, _firstPartialMember, GovernorCountingSimple.VoteType.For);
    _castVote(_proposalId, _secondPartialMember, GovernorCountingSimple.VoteType.For);

    _assertState(_proposalId, IGovernor.ProposalState.Succeeded);
  }

  function testFuzz_QueuedWhileTheVetoGovernorHoldsTheProposalInItsTimelock(string memory _description) public {
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Queued);

    _assertState(_proposalId, IGovernor.ProposalState.Queued);
  }

  function testFuzz_DefeatedOnceTheVetoGovernorDefeatsAQueuedProposal(string memory _description) public {
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Defeated);

    _assertState(_proposalId, IGovernor.ProposalState.Defeated);
  }

  function testFuzz_QueuedAgainOnceTheVetoGovernorOverridesTheVetoOfAQueuedProposal(string memory _description) public {
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);
    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Defeated);

    // An overridden veto turns the veto governor's state from defeated back to succeeded.
    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Succeeded);

    _assertState(_proposalId, IGovernor.ProposalState.Queued);
  }

  function testFuzz_CanceledOnceTheVetoGovernorCancelsAQueuedProposal(string memory _description) public {
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Canceled);

    _assertState(_proposalId, IGovernor.ProposalState.Canceled);
  }

  function testFuzz_CanceledOnceAQueuedProposalExpiresInTheVetoGovernor(string memory _description) public {
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Expired);

    _assertState(_proposalId, IGovernor.ProposalState.Canceled);
  }

  function testFuzz_CanceledWhenTheProposerCancelsBeforeVotingOpens(string memory _description) public {
    _seatMembers(1);
    (address[] memory _targets, uint256[] memory _values, bytes[] memory _calldatas) = _proposalActions();
    vm.startPrank(members[0]);
    uint256 _proposalId = governor.propose(_targets, _values, _calldatas, _description);

    governor.cancel(_targets, _values, _calldatas, keccak256(bytes(_description)));
    vm.stopPrank();

    _assertState(_proposalId, IGovernor.ProposalState.Canceled);
  }
}

contract ProposalEta is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_ZeroBeforeTheProposalIsQueued(string memory _description) public {
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _proposeAndOpenVoting(_description);
    _castForVotes(_proposalId, QUORUM_SEATS);

    assertEq(governor.proposalEta(_proposalId), 0);
  }

  function testFuzz_FollowsTheVetoGovernorsDeadlineOnceAnExtensionMovesIt(
    string memory _description,
    uint256 _extendedDeadline
  ) public {
    // The lower bound keeps the new deadline different from the ETA stored at queue time, so the test proves the ETA
    // is read live from the veto governor.
    _extendedDeadline = bound(_extendedDeadline, vetoGovernor.PROPOSAL_DEADLINE() + 1, type(uint256).max);
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setDeadline(_proposalId, _extendedDeadline);

    assertEq(governor.proposalEta(_proposalId), _extendedDeadline);
    _assertState(_proposalId, IGovernor.ProposalState.Queued);
  }

  function testFuzz_TheVetoGovernorsEtaOnceItQueuesTheProposalInItsTimelock(
    string memory _description,
    uint256 _vetoEta
  ) public {
    _vetoEta = bound(_vetoEta, 1, type(uint256).max);
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setEta(_proposalId, _vetoEta);

    assertEq(governor.proposalEta(_proposalId), _vetoEta);
  }

  function testFuzz_TheVetoGovernorsEtaRatherThanAnExtendedDeadlineOnceBothAreSet(
    string memory _description,
    uint256 _extendedDeadline,
    uint256 _vetoEta
  ) public {
    // The lower bound keeps the new deadline different from the ETA stored at queue time.
    _extendedDeadline = bound(_extendedDeadline, vetoGovernor.PROPOSAL_DEADLINE() + 1, type(uint256).max);
    _vetoEta = bound(_vetoEta, 1, type(uint256).max);
    // Equal values would pass whichever one the governor returned.
    vm.assume(_vetoEta != _extendedDeadline);
    _seatMembers(QUORUM_SEATS);
    uint256 _proposalId = _passAndQueue(_description);

    vetoGovernor.setDeadline(_proposalId, _extendedDeadline);
    vetoGovernor.setEta(_proposalId, _vetoEta);

    assertEq(governor.proposalEta(_proposalId), _vetoEta);
  }
}

contract Queue is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_SubmitsASucceededProposalToTheVetoGovernor(uint256 _memberCount, string memory _description)
    public
  {
    _seatMembers(bound(_memberCount, QUORUM_SEATS, MAX_MEMBER_COUNT));

    // Queued while its voting period is still running, since its FOR votes already reached quorum.
    uint256 _proposalId = _passAndQueue(_description);

    // The veto governor received the same actions and description, so it identifies the proposal by the same ID.
    assertTrue(vetoGovernor.isSubmitted(_proposalId));
    assertEq(governor.proposalEta(_proposalId), vetoGovernor.PROPOSAL_DEADLINE());
    _assertState(_proposalId, IGovernor.ProposalState.Queued);
  }
}

contract CastVote is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_RevertIf_VotingAfterForVotesReachedQuorum(uint256 _memberCount, uint256 _supportBits) public {
    _seatMembers(bound(_memberCount, QUORUM_SEATS + 1, MAX_MEMBER_COUNT));
    uint256 _proposalId = _proposeAndOpenVoting(PROPOSAL_DESCRIPTION);
    _castForVotes(_proposalId, QUORUM_SEATS);

    vm.expectRevert(
      abi.encodeWithSelector(
        IGovernor.GovernorUnexpectedProposalState.selector,
        _proposalId,
        IGovernor.ProposalState.Succeeded,
        bytes32(1 << uint8(IGovernor.ProposalState.Active))
      )
    );
    _castVote(_proposalId, members[QUORUM_SEATS], _againstOrAbstain(_supportBits, QUORUM_SEATS));
  }
}

contract Execute is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_ExecutesAQueuedProposalThroughTheVetoGovernor(uint256 _memberCount, string memory _description)
    public
  {
    _seatMembers(bound(_memberCount, QUORUM_SEATS, MAX_MEMBER_COUNT));
    uint256 _proposalId = _passAndQueue(_description);
    vetoGovernor.setState(_proposalId, IGovernor.ProposalState.Succeeded);
    (address[] memory _targets, uint256[] memory _values, bytes[] memory _calldatas) = _proposalActions();

    governor.execute(_targets, _values, _calldatas, keccak256(bytes(_description)));

    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Executed));
    _assertState(_proposalId, IGovernor.ProposalState.Executed);
  }
}

contract UpdateQuorumNumerator is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_RevertIf_TheAdminSetsANonZeroQuorumFraction(uint256 _newQuorumNumerator) public {
    _newQuorumNumerator = bound(_newQuorumNumerator, 1, type(uint256).max);

    vm.expectRevert(ZkProtocolUpgradeCouncilGovernor.ZkProtocolUpgradeCouncilGovernor__QuorumFractionDisabled.selector);
    vm.prank(governorAdmin);
    governor.updateQuorumNumerator(_newQuorumNumerator);
  }

  function test_LetsTheAdminSetAZeroQuorumFractionWithoutRecordingIt() public {
    vm.recordLogs();
    vm.prank(governorAdmin);
    governor.updateQuorumNumerator(0);

    assertEq(_countLogsEmittedBy(address(governor)), 0);

    assertEq(governor.quorumNumerator(), 0);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheGovernorAdmin(address _caller) public {
    _assumeNotASystemAddress(_caller);
    vm.assume(_caller != governorAdmin);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    governor.updateQuorumNumerator(0);
  }
}

contract UpdateSuperQuorumNumerator is ZkProtocolUpgradeCouncilGovernorTest {
  function testFuzz_RevertIf_TheAdminSetsANonZeroSuperQuorumFraction(uint256 _newSuperQuorumNumerator) public {
    _newSuperQuorumNumerator = bound(_newSuperQuorumNumerator, 1, type(uint256).max);

    vm.expectRevert(ZkProtocolUpgradeCouncilGovernor.ZkProtocolUpgradeCouncilGovernor__QuorumFractionDisabled.selector);
    vm.prank(governorAdmin);
    governor.updateSuperQuorumNumerator(_newSuperQuorumNumerator);
  }

  function test_LetsTheAdminSetAZeroSuperQuorumFractionWithoutRecordingIt() public {
    vm.recordLogs();
    vm.prank(governorAdmin);
    governor.updateSuperQuorumNumerator(0);

    assertEq(_countLogsEmittedBy(address(governor)), 0);

    assertEq(governor.superQuorumNumerator(), 0);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheGovernorAdmin(address _caller) public {
    _assumeNotASystemAddress(_caller);
    vm.assume(_caller != governorAdmin);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    governor.updateSuperQuorumNumerator(0);
  }
}

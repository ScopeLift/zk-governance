// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ZkProtocolGovernor} from "src/ZkProtocolGovernor.sol";
import {ERC20VotesFake} from "test/fakes/ERC20VotesFake.sol";

/// @notice Tests `ZkProtocolGovernor` configured as a supermajority governor with a 1.26B quorum. A proposal must reach
/// the quorum in FOR votes alone, with ABSTAIN votes not counting toward it, and must have more FOR than AGAINST votes.
contract ZkProtocolGovernorSupermajorityTest is Test {
  uint224 constant QUORUM = 1_260_000_000e18;
  uint256 constant MAX_VOTES = 10 * uint256(QUORUM);

  uint8 constant AGAINST = 0;
  uint8 constant FOR = 1;
  uint8 constant ABSTAIN = 2;

  ERC20VotesFake token;
  TimelockController timelock;
  ZkProtocolGovernor governor;

  address forVoter = makeAddr("For Voter");
  address againstVoter = makeAddr("Against Voter");
  address abstainVoter = makeAddr("Abstain Voter");

  function setUp() public virtual {
    token = new ERC20VotesFake();
    timelock = new TimelockController(1 days, new address[](0), new address[](0), address(this));
    governor = new ZkProtocolGovernor(
      "ZKsync Supermajority Governor", IVotes(address(token)), timelock, 1 days, 7 days, 0, QUORUM, 3 days
    );
  }

  function _giveVotes(address _voter, uint256 _amount) internal {
    token.mint(_voter, _amount);
    vm.prank(_voter);
    token.delegate(_voter);
  }

  function _propose() internal returns (uint256 _proposalId) {
    address[] memory _targets = new address[](1);
    _targets[0] = address(timelock);
    uint256[] memory _values = new uint256[](1);
    bytes[] memory _calldatas = new bytes[](1);
    _proposalId = governor.propose(_targets, _values, _calldatas, "Override a veto");
  }

  function _castVote(uint256 _proposalId, address _voter, uint8 _support) internal {
    if (token.getVotes(_voter) == 0) {
      return;
    }
    vm.prank(_voter);
    governor.castVote(_proposalId, _support);
  }

  /// @notice Proposes, has one delegate split its weight across AGAINST, FOR and ABSTAIN with a fractional vote, and
  /// returns the proposal's state after voting ends.
  function _stateAfterSplitVote(uint128 _forVotes, uint128 _againstVotes, uint128 _abstainVotes)
    internal
    returns (IGovernor.ProposalState)
  {
    _giveVotes(forVoter, uint256(_forVotes) + _againstVotes + _abstainVotes);
    vm.warp(block.timestamp + 1);

    uint256 _proposalId = _propose();
    vm.warp(governor.proposalSnapshot(_proposalId) + 1);
    vm.prank(forVoter);
    governor.castVoteWithReasonAndParams(
      _proposalId, FOR, "", abi.encodePacked(_againstVotes, _forVotes, _abstainVotes)
    );
    vm.warp(governor.proposalDeadline(_proposalId) + 1);
    return governor.state(_proposalId);
  }

  /// @notice Proposes, casts each voter's full weight and returns the proposal's state after voting ends.
  function _stateAfterVoting(uint256 _forVotes, uint256 _againstVotes, uint256 _abstainVotes)
    internal
    returns (IGovernor.ProposalState)
  {
    _giveVotes(forVoter, _forVotes);
    _giveVotes(againstVoter, _againstVotes);
    _giveVotes(abstainVoter, _abstainVotes);
    vm.warp(block.timestamp + 1);

    uint256 _proposalId = _propose();
    vm.warp(governor.proposalSnapshot(_proposalId) + 1);
    _castVote(_proposalId, forVoter, FOR);
    _castVote(_proposalId, againstVoter, AGAINST);
    _castVote(_proposalId, abstainVoter, ABSTAIN);
    vm.warp(governor.proposalDeadline(_proposalId) + 1);
    return governor.state(_proposalId);
  }
}

contract SupermajorityState is ZkProtocolGovernorSupermajorityTest {
  function testFuzz_SucceedsWhenForVotesMeetQuorumAndExceedAgainstVotes(
    uint256 _forVotes,
    uint256 _againstVotes,
    uint256 _abstainVotes
  ) public {
    _forVotes = bound(_forVotes, QUORUM, MAX_VOTES);
    _againstVotes = bound(_againstVotes, 0, _forVotes - 1);
    _abstainVotes = bound(_abstainVotes, 0, MAX_VOTES);

    assertEq(
      uint8(_stateAfterVoting(_forVotes, _againstVotes, _abstainVotes)), uint8(IGovernor.ProposalState.Succeeded)
    );
  }

  function testFuzz_DefeatedWhenForVotesAreBelowQuorumEvenWithAbstainVotes(uint256 _forVotes, uint256 _abstainVotes)
    public
  {
    _forVotes = bound(_forVotes, 1, QUORUM - 1);
    _abstainVotes = bound(_abstainVotes, QUORUM, MAX_VOTES);

    assertEq(uint8(_stateAfterVoting(_forVotes, 0, _abstainVotes)), uint8(IGovernor.ProposalState.Defeated));
  }

  function testFuzz_DefeatedWhenAgainstVotesAreAtLeastForVotes(uint256 _forVotes, uint256 _againstVotes) public {
    _forVotes = bound(_forVotes, QUORUM, MAX_VOTES);
    _againstVotes = bound(_againstVotes, _forVotes, MAX_VOTES);

    assertEq(uint8(_stateAfterVoting(_forVotes, _againstVotes, 0)), uint8(IGovernor.ProposalState.Defeated));
  }

  function testFuzz_SucceedsWhenSplitVoteForPartMeetsQuorumAndExceedsAgainstPart(
    uint128 _forVotes,
    uint128 _againstVotes,
    uint128 _abstainVotes
  ) public {
    _forVotes = uint128(bound(_forVotes, QUORUM, MAX_VOTES));
    _againstVotes = uint128(bound(_againstVotes, 0, _forVotes - 1));
    _abstainVotes = uint128(bound(_abstainVotes, 0, MAX_VOTES));

    assertEq(
      uint8(_stateAfterSplitVote(_forVotes, _againstVotes, _abstainVotes)), uint8(IGovernor.ProposalState.Succeeded)
    );
  }

  function testFuzz_DefeatedWhenSplitVoteForPartIsBelowQuorumEvenWithAbstainPart(
    uint128 _forVotes,
    uint128 _abstainVotes
  ) public {
    _forVotes = uint128(bound(_forVotes, 1, QUORUM - 1));
    _abstainVotes = uint128(bound(_abstainVotes, QUORUM, MAX_VOTES));

    assertEq(uint8(_stateAfterSplitVote(_forVotes, 0, _abstainVotes)), uint8(IGovernor.ProposalState.Defeated));
  }
}

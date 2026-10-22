// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BasicCouncilVetoGovernor} from "council-governance/BasicCouncilVetoGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {FakeVotesToken} from "test/fakes/FakeVotesToken.sol";

contract ZkProtocolUpgradeVetoGovernorTest is Test {
  uint256 constant MAX_VETO_THRESHOLD = 1e30;
  uint256 constant MAX_VOTES = 2 * MAX_VETO_THRESHOLD;
  uint48 constant VOTING_PERIOD_EXTENSION = 2 days;
  uint16 constant VOTING_PERIOD_EXTENSION_THRESHOLD_PCT = 50;
  uint8 constant AGAINST = 0;

  FakeVotesToken token;
  address council = makeAddr("Council");
  address governorAdmin = makeAddr("Governor Admin");
  address voter = makeAddr("Voter");

  function setUp() public virtual {
    vm.warp(1_700_000_000);
    token = new FakeVotesToken();
  }

  function _constructorParams(uint256 _vetoThresholdNumerator)
    internal
    returns (BasicCouncilVetoGovernor.ConstructorParams memory)
  {
    return BasicCouncilVetoGovernor.ConstructorParams({
      name: "Veto Governor",
      token: address(token),
      votingDelay: 1 days,
      votingPeriod: 7 days,
      proposalThreshold: 0,
      vetoGuardian: makeAddr("Veto Guardian"),
      vetoOverrideRole: makeAddr("Veto Override Role"),
      vetoOverrideDuration: 14 days,
      votingPeriodExtension: VOTING_PERIOD_EXTENSION,
      votingPeriodExtensionThresholdPct: VOTING_PERIOD_EXTENSION_THRESHOLD_PCT,
      vetoThresholdNumerator: _vetoThresholdNumerator,
      timelock: TimelockController(payable(makeAddr("Timelock"))),
      governorAdmin: governorAdmin,
      council: council
    });
  }

  function _deployGovernorWithVetoThreshold(uint256 _vetoThreshold) internal returns (ZkProtocolUpgradeVetoGovernor) {
    return new ZkProtocolUpgradeVetoGovernor(_constructorParams(0), _vetoThreshold);
  }

  function _boundToValidVetoThreshold(uint256 _vetoThreshold) internal pure returns (uint256) {
    return _bound(_vetoThreshold, 1, MAX_VETO_THRESHOLD);
  }

  // The AGAINST votes at which the voting period is extended, as `GovernorExtendVetoPeriod` computes it.
  function _votingPeriodExtensionThreshold(uint256 _vetoThreshold) internal pure returns (uint256) {
    return _vetoThreshold * VOTING_PERIOD_EXTENSION_THRESHOLD_PCT / 100;
  }

  function _mintAndSelfDelegateVotes(address _account, uint256 _amount) internal {
    token.mint(_account, _amount);
    vm.prank(_account);
    token.delegate(_account);
    // Votes count from the next timestamp, so move past the delegation before any proposal is created.
    vm.warp(block.timestamp + 1);
  }

  function _proposeFromCouncil(ZkProtocolUpgradeVetoGovernor _governor) internal returns (uint256) {
    address[] memory _targets = new address[](1);
    _targets[0] = makeAddr("Target");
    uint256[] memory _values = new uint256[](1);
    bytes[] memory _calldatas = new bytes[](1);
    vm.prank(council);
    return _governor.propose(_targets, _values, _calldatas, "A council proposal");
  }

  function _castAgainstVoteOnceVotingOpens(ZkProtocolUpgradeVetoGovernor _governor, uint256 _proposalId) internal {
    vm.warp(_governor.proposalSnapshot(_proposalId) + 1);
    vm.prank(voter);
    _governor.castVote(_proposalId, AGAINST);
  }

  function _jumpPastTheProposalDeadline(ZkProtocolUpgradeVetoGovernor _governor, uint256 _proposalId) internal {
    vm.warp(_governor.proposalDeadline(_proposalId) + 1);
  }
}

contract Constructor is ZkProtocolUpgradeVetoGovernorTest {
  function testFuzz_SetsTheVetoThreshold(uint256 _vetoThreshold) public {
    _vetoThreshold = _boundToValidVetoThreshold(_vetoThreshold);

    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);

    assertEq(_governor.VETO_THRESHOLD(), _vetoThreshold);
  }

  function testFuzz_LeavesTheVetoThresholdNumeratorAtZero(uint256 _vetoThreshold) public {
    _vetoThreshold = _boundToValidVetoThreshold(_vetoThreshold);

    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);

    assertEq(_governor.vetoThresholdNumerator(), 0);
  }

  function test_RevertIf_TheVetoThresholdIsZero() public {
    BasicCouncilVetoGovernor.ConstructorParams memory _params = _constructorParams(0);

    vm.expectRevert(ZkProtocolUpgradeVetoGovernor.ZkProtocolUpgradeVetoGovernor_InvalidVetoThreshold.selector);
    new ZkProtocolUpgradeVetoGovernor(_params, 0);
  }

  function testFuzz_RevertIf_TheVetoThresholdNumeratorIsNonZero(uint256 _vetoThresholdNumerator, uint256 _vetoThreshold)
    public
  {
    // Numerators above the denominator (100) are rejected by the base governor before this check runs.
    _vetoThresholdNumerator = _bound(_vetoThresholdNumerator, 1, 100);
    _vetoThreshold = _boundToValidVetoThreshold(_vetoThreshold);
    BasicCouncilVetoGovernor.ConstructorParams memory _params = _constructorParams(_vetoThresholdNumerator);

    vm.expectRevert(ZkProtocolUpgradeVetoGovernor.ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled.selector);
    new ZkProtocolUpgradeVetoGovernor(_params, _vetoThreshold);
  }
}

contract VetoThreshold is ZkProtocolUpgradeVetoGovernorTest {
  function testFuzz_ReturnsTheVetoThresholdAtEveryTimepoint(uint256 _vetoThreshold, uint256 _timepoint) public {
    _vetoThreshold = _boundToValidVetoThreshold(_vetoThreshold);
    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);

    assertEq(_governor.vetoThreshold(_timepoint), _vetoThreshold);
  }
}

contract State is ZkProtocolUpgradeVetoGovernorTest {
  function testFuzz_ReturnsDefeatedWhenAgainstVotesReachTheVetoThreshold(uint256 _vetoThreshold, uint256 _againstVotes)
    public
  {
    _vetoThreshold = _boundToValidVetoThreshold(_vetoThreshold);
    _againstVotes = _bound(_againstVotes, _vetoThreshold, MAX_VOTES);
    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);
    _mintAndSelfDelegateVotes(voter, _againstVotes);
    uint256 _proposalId = _proposeFromCouncil(_governor);

    _castAgainstVoteOnceVotingOpens(_governor, _proposalId);
    _jumpPastTheProposalDeadline(_governor, _proposalId);

    assertEq(uint8(_governor.state(_proposalId)), uint8(IGovernor.ProposalState.Defeated));
  }

  function testFuzz_ReturnsSucceededWhenAgainstVotesAreBelowTheVetoThreshold(
    uint256 _vetoThreshold,
    uint256 _againstVotes
  ) public {
    _vetoThreshold = _bound(_vetoThreshold, 2, MAX_VETO_THRESHOLD);
    _againstVotes = _bound(_againstVotes, 1, _vetoThreshold - 1);
    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);
    _mintAndSelfDelegateVotes(voter, _againstVotes);
    uint256 _proposalId = _proposeFromCouncil(_governor);

    _castAgainstVoteOnceVotingOpens(_governor, _proposalId);
    _jumpPastTheProposalDeadline(_governor, _proposalId);

    assertEq(uint8(_governor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));
  }
}

contract ProposalDeadline is ZkProtocolUpgradeVetoGovernorTest {
  function testFuzz_ExtendsTheDeadlineWhenAgainstVotesReachTheExtensionShareOfTheVetoThreshold(
    uint256 _vetoThreshold,
    uint256 _againstVotes
  ) public {
    _vetoThreshold = _bound(_vetoThreshold, 2, MAX_VETO_THRESHOLD);
    _againstVotes = _bound(_againstVotes, _votingPeriodExtensionThreshold(_vetoThreshold), MAX_VOTES);
    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);
    _mintAndSelfDelegateVotes(voter, _againstVotes);
    uint256 _proposalId = _proposeFromCouncil(_governor);
    uint256 _originalDeadline = _governor.proposalDeadline(_proposalId);

    _castAgainstVoteOnceVotingOpens(_governor, _proposalId);

    assertEq(_governor.proposalDeadline(_proposalId), _originalDeadline + VOTING_PERIOD_EXTENSION);
  }

  function testFuzz_DoesNotExtendTheDeadlineWhenAgainstVotesAreBelowTheExtensionShareOfTheVetoThreshold(
    uint256 _vetoThreshold,
    uint256 _againstVotes
  ) public {
    _vetoThreshold = _bound(_vetoThreshold, 4, MAX_VETO_THRESHOLD);
    _againstVotes = _bound(_againstVotes, 1, _votingPeriodExtensionThreshold(_vetoThreshold) - 1);
    ZkProtocolUpgradeVetoGovernor _governor = _deployGovernorWithVetoThreshold(_vetoThreshold);
    _mintAndSelfDelegateVotes(voter, _againstVotes);
    uint256 _proposalId = _proposeFromCouncil(_governor);
    uint256 _originalDeadline = _governor.proposalDeadline(_proposalId);

    _castAgainstVoteOnceVotingOpens(_governor, _proposalId);

    assertEq(_governor.proposalDeadline(_proposalId), _originalDeadline);
  }
}

contract UpdateVetoThresholdNumerator is ZkProtocolUpgradeVetoGovernorTest {
  function testFuzz_RevertIf_CalledByTheGovernorAdmin(uint256 _vetoThreshold, uint256 _newVetoThresholdNumerator)
    public
  {
    ZkProtocolUpgradeVetoGovernor _governor =
      _deployGovernorWithVetoThreshold(_boundToValidVetoThreshold(_vetoThreshold));

    vm.expectRevert(ZkProtocolUpgradeVetoGovernor.ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled.selector);
    vm.prank(governorAdmin);
    _governor.updateVetoThresholdNumerator(_newVetoThresholdNumerator);
  }

  function testFuzz_RevertIf_CalledByAnyOtherAccount(
    uint256 _vetoThreshold,
    address _caller,
    uint256 _newVetoThresholdNumerator
  ) public {
    vm.assume(_caller != governorAdmin);
    ZkProtocolUpgradeVetoGovernor _governor =
      _deployGovernorWithVetoThreshold(_boundToValidVetoThreshold(_vetoThreshold));

    vm.expectRevert(ZkProtocolUpgradeVetoGovernor.ZkProtocolUpgradeVetoGovernor_VetoThresholdFractionDisabled.selector);
    vm.prank(_caller);
    _governor.updateVetoThresholdNumerator(_newVetoThresholdNumerator);
  }
}

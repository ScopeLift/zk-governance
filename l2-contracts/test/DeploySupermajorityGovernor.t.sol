// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ZkProtocolGovernor} from "src/ZkProtocolGovernor.sol";
import {DeploySupermajorityGovernorEraMainnet} from "script/DeploySupermajorityGovernor.s.sol";
import {ERC20VotesFake} from "test/fakes/ERC20VotesFake.sol";

/// @notice Stands in for the Veto Governor's `overrideVeto`, recording who called it.
contract VetoOverrideTarget {
  address public caller;
  uint256 public overriddenProposalId;

  function overrideVeto(uint256 _proposalId) external {
    caller = msg.sender;
    overriddenProposalId = _proposalId;
  }
}

contract DeploySupermajorityGovernorTest is Test {
  address constant ZK_TOKEN = 0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E;
  uint256 constant QUORUM = 1_260_000_000e18;
  uint256 constant OVERRIDE_TIMELOCK_MIN_DELAY = 1 days;
  bytes32 constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

  ZkProtocolGovernor governor;
  TimelockController timelock;

  function setUp() public {
    // The script only stores the token address; voting in the end-to-end test needs a token with code there.
    vm.etch(ZK_TOKEN, address(new ERC20VotesFake()).code);
    DeploySupermajorityGovernorEraMainnet _deploy = new DeploySupermajorityGovernorEraMainnet();
    _deploy.disableLogging();
    _deploy.run();
    governor = _deploy.governor();
    timelock = _deploy.timelock();
  }
}

contract Run is DeploySupermajorityGovernorTest {
  function test_DeploysTheGovernorWithTheZipParameters() public {
    assertEq(governor.name(), "ZKsync Supermajority Governor");
    assertEq(address(governor.token()), ZK_TOKEN);
    assertEq(address(governor.timelock()), address(timelock));
    assertEq(governor.votingDelay(), 1 days);
    assertEq(governor.votingPeriod(), 7 days);
    assertEq(governor.proposalThreshold(), 21_000_000e18);
    assertEq(governor.quorum(block.timestamp), QUORUM);
    assertEq(governor.lateQuorumVoteExtension(), 3 days);
  }

  function test_ConfiguresTheOverrideTimelock() public {
    assertEq(timelock.getMinDelay(), 1 days);
    assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
    assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    assertTrue(timelock.hasRole(TIMELOCK_ADMIN_ROLE, address(timelock)));
  }

  function test_LeavesTheDeployerNoTimelockRole() public {
    assertFalse(timelock.hasRole(TIMELOCK_ADMIN_ROLE, DEFAULT_SENDER));
    assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), DEFAULT_SENDER));
    assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), DEFAULT_SENDER));
    assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEFAULT_SENDER));
  }

  function test_PassedProposalCallsOverrideVetoThroughTheOverrideTimelock() public {
    VetoOverrideTarget _target = new VetoOverrideTarget();
    address _voter = makeAddr("Voter");
    ERC20VotesFake(ZK_TOKEN).mint(_voter, QUORUM);
    vm.prank(_voter);
    ERC20VotesFake(ZK_TOKEN).delegate(_voter);
    vm.warp(block.timestamp + 1);

    address[] memory _targets = new address[](1);
    _targets[0] = address(_target);
    uint256[] memory _values = new uint256[](1);
    bytes[] memory _calldatas = new bytes[](1);
    _calldatas[0] = abi.encodeCall(VetoOverrideTarget.overrideVeto, (42));
    string memory _description = "Override the veto on proposal 42";

    vm.prank(_voter);
    uint256 _proposalId = governor.propose(_targets, _values, _calldatas, _description);
    vm.warp(governor.proposalSnapshot(_proposalId) + 1);
    vm.prank(_voter);
    governor.castVote(_proposalId, 1);
    vm.warp(governor.proposalDeadline(_proposalId) + 1);
    assertEq(uint8(governor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));

    bytes32 _descriptionHash = keccak256(bytes(_description));
    governor.queue(_targets, _values, _calldatas, _descriptionHash);
    vm.warp(block.timestamp + OVERRIDE_TIMELOCK_MIN_DELAY);
    governor.execute(_targets, _values, _calldatas, _descriptionHash);

    assertEq(_target.caller(), address(timelock));
    assertEq(_target.overriddenProposalId(), 42);
  }
}

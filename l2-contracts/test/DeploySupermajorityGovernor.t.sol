// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {DeploySupermajorityGovernorEraMainnet} from "script/DeploySupermajorityGovernor.s.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "council/script/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "council/script/ZkProtocolUpgradeEraMainnetConfig.sol";
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

/// @notice Runs the Era mainnet deployment with a test token in place of the ZK token.
/// @dev The test inherits the script and calls `run` internally, rather than deploying the script, so the script's
/// cheatcodes run in the EVM and its deployments in EraVM under `--zksync`, as they do under `forge script --zksync`.
contract DeploySupermajorityGovernorTest is Test, DeploySupermajorityGovernorEraMainnet {
  uint256 constant QUORUM = 1_260_000_000e18;
  uint256 constant OVERRIDE_TIMELOCK_MIN_DELAY = 1 days;

  // Voting in the end-to-end test needs a token with code, so the mainnet ZK token is replaced by a fake.
  ERC20VotesFake token;
  // When set, the params use an account without code as the ZK token.
  bool useTokenWithoutCode;
  // When set, the params' veto override window is cut to exactly a supermajority override's length.
  bool shortenVetoOverrideWindow;

  function setUp() public virtual {
    token = new ERC20VotesFake();
    disableLogging();
  }

  function _deploymentParams()
    internal
    view
    override(ZkProtocolUpgradeDeploymentConfig, ZkProtocolUpgradeEraMainnetConfig)
    returns (DeploymentParams memory _params)
  {
    _params = ZkProtocolUpgradeEraMainnetConfig._deploymentParams();
    _params.zkToken = address(token);
    if (useTokenWithoutCode) {
      _params.zkToken = address(uint160(uint256(keccak256("Account Without Code"))));
    }
    if (shortenVetoOverrideWindow) {
      _params.vetoGovernorVetoOverrideDuration = 12 days;
    }
  }
}

contract Run is DeploySupermajorityGovernorTest {
  function setUp() public override {
    super.setUp();
    run();
  }

  function test_DeploysTheGovernorWithTheZipParameters() public {
    assertEq(governor.name(), "ZKsync Supermajority Governor");
    assertEq(address(governor.token()), address(token));
    assertEq(address(governor.timelock()), address(timelock));
    assertEq(governor.votingDelay(), 1 days);
    assertEq(governor.votingPeriod(), 7 days);
    assertEq(governor.proposalThreshold(), 21_000_000e18);
    assertEq(governor.quorum(block.timestamp), QUORUM);
    assertEq(governor.lateQuorumVoteExtension(), 3 days);
  }

  function test_ConfiguresTheOverrideTimelock() public {
    assertEq(timelock.getMinDelay(), OVERRIDE_TIMELOCK_MIN_DELAY);
    assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
    assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    assertTrue(timelock.hasRole(timelock.TIMELOCK_ADMIN_ROLE(), address(timelock)));
  }

  function test_LeavesTheDeployerNoTimelockRole() public {
    assertFalse(timelock.hasRole(timelock.TIMELOCK_ADMIN_ROLE(), DEFAULT_SENDER));
    assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), DEFAULT_SENDER));
    assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), DEFAULT_SENDER));
    assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), DEFAULT_SENDER));
  }

  function test_PassedProposalCallsOverrideVetoThroughTheOverrideTimelock() public {
    VetoOverrideTarget _target = new VetoOverrideTarget();
    address _voter = makeAddr("Voter");
    token.mint(_voter, QUORUM);
    vm.prank(_voter);
    token.delegate(_voter);
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

contract Check is DeploySupermajorityGovernorTest {
  function test_PassesForTheDeploymentRunMade() public {
    run();
    vm.setEnv("SUPERMAJORITY_GOVERNOR", vm.toString(address(governor)));
    vm.setEnv("OVERRIDE_TIMELOCK", vm.toString(address(timelock)));
    vm.setEnv("DEPLOYER", vm.toString(DEFAULT_SENDER));

    check();
  }
}

// `vm.expectRevert` applies to the next external call, so these tests call `run` through `this`.
contract RunReverts is DeploySupermajorityGovernorTest {
  function test_RevertIf_TheZkTokenHasNoCode() public {
    useTokenWithoutCode = true;

    vm.expectRevert("SupermajorityGovernorChecks: zkToken has no code; set it to the ZK token");
    this.run();
  }

  function test_RevertIf_TheVetoOverrideWindowIsNoLongerThanASupermajorityOverride() public {
    shortenVetoOverrideWindow = true;

    vm.expectRevert(
      "SupermajorityGovernorChecks: vetoGovernorVetoOverrideDuration is too short for a supermajority override"
    );
    this.run();
  }
}

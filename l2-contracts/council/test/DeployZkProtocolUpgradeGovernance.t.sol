// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployZkProtocolUpgradeGovernanceEraMainnet} from "script/DeployZkProtocolUpgradeGovernance.s.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/ZkProtocolUpgradeEraMainnetConfig.sol";
import {FakeSupermajorityGovernor} from "test/fakes/FakeSupermajorityGovernor.sol";
import {FakeVotesToken} from "test/fakes/FakeVotesToken.sol";

/// @notice Runs the Era mainnet step 2 deployment against test doubles for the contracts it builds on: the ZK token,
/// the Protocol Timelock, and step 1's Supermajority Governor and override timelock.
/// @dev The test inherits the script and calls `run` internally, rather than deploying the script, so the script's
/// cheatcodes run in the EVM and its deployments in EraVM under `--zksync`, as they do under `forge script --zksync`.
contract DeployZkProtocolUpgradeGovernanceTest is Test, DeployZkProtocolUpgradeGovernanceEraMainnet {
  FakeVotesToken zkToken;
  TimelockController protocolTimelock;
  TimelockController overrideTimelock;
  FakeSupermajorityGovernor supermajorityGovernor;
  // When set, the params' veto override window is cut to one day, shorter than a supermajority override takes.
  bool shortenVetoOverrideWindow;

  function setUp() public virtual {
    zkToken = new FakeVotesToken();
    protocolTimelock = new TimelockController(0, new address[](0), new address[](0), address(this));
    _deployStepOneAs(address(this));
    disableLogging();
  }

  // Deploys the override timelock and Supermajority Governor as step 1 leaves them: the governor proposes and cancels,
  // anyone executes, and the timelock administers itself. `_admin` deploys them and keeps OpenZeppelin v5's admin role.
  function _deployStepOneAs(address _admin) internal {
    address[] memory _openExecutor = new address[](1);
    overrideTimelock = new TimelockController(1 days, new address[](0), _openExecutor, _admin);
    supermajorityGovernor = new FakeSupermajorityGovernor(_supermajorityGovernorSettings(address(overrideTimelock)));
    vm.startPrank(_admin);
    overrideTimelock.grantRole(overrideTimelock.PROPOSER_ROLE(), address(supermajorityGovernor));
    overrideTimelock.grantRole(overrideTimelock.CANCELLER_ROLE(), address(supermajorityGovernor));
    // The real override timelock is OpenZeppelin v4, whose admin role is TIMELOCK_ADMIN_ROLE.
    overrideTimelock.grantRole(TIMELOCK_ADMIN_ROLE, address(overrideTimelock));
    vm.stopPrank();
  }

  // The settings step 1 gives the Supermajority Governor, from the same params step 2 checks it against.
  function _supermajorityGovernorSettings(address _timelock)
    internal
    view
    returns (FakeSupermajorityGovernor.Settings memory)
  {
    DeploymentParams memory _params = _deploymentParams();
    return FakeSupermajorityGovernor.Settings({
      name: _params.supermajorityGovernorName,
      token: _params.zkToken,
      timelock: _timelock,
      votingDelay: _params.supermajorityGovernorVotingDelay,
      votingPeriod: _params.supermajorityGovernorVotingPeriod,
      proposalThreshold: _params.supermajorityGovernorProposalThreshold,
      quorum: _params.supermajorityGovernorQuorum,
      lateQuorumVoteExtension: _params.supermajorityGovernorLateQuorumVoteExtension
    });
  }

  // Supplies step 1's contracts directly. Environment variables are shared by tests running in parallel, so only the
  // `check` test, which reads an existing deployment the way the script does, sets them.
  function _stepOneContracts() internal view override returns (address, TimelockController) {
    return (address(supermajorityGovernor), overrideTimelock);
  }

  function _deploymentParams()
    internal
    view
    override(ZkProtocolUpgradeDeploymentConfig, ZkProtocolUpgradeEraMainnetConfig)
    returns (DeploymentParams memory _params)
  {
    _params = ZkProtocolUpgradeEraMainnetConfig._deploymentParams();
    _params.zkToken = address(zkToken);
    _params.protocolTimelock = address(protocolTimelock);
    if (shortenVetoOverrideWindow) {
      _params.vetoGovernorVetoOverrideDuration = 1 days;
    }
  }
}

contract Run is DeployZkProtocolUpgradeGovernanceTest {
  function setUp() public override {
    super.setUp();
    run();
  }

  function test_MintsOneSeatToEachCouncilMemberAndHandsTheTokenToTheGovernanceAdmin() public view {
    DeploymentParams memory _params = _deploymentParams();

    assertEq(councilToken.name(), "ZKsync Protocol Upgrade Council Seat");
    assertEq(councilToken.symbol(), "ZKPUC");
    assertEq(councilToken.owner(), GOVERNANCE_ADMIN);
    assertEq(councilToken.totalSupply(), 8e18);
    for (uint256 _i = 0; _i < _params.councilMembers.length; _i += 1) {
      assertEq(councilToken.getVotes(_params.councilMembers[_i]), 1e18);
    }
  }

  function test_DeploysTheCouncilGovernorWiredToTheVetoGovernor() public view {
    assertEq(councilGovernor.name(), "ZKsync Protocol Upgrade Council");
    assertEq(address(councilGovernor.token()), address(councilToken));
    assertEq(councilGovernor.QUORUM(), 1e18);
    assertEq(address(councilGovernor.councilVetoGovernor()), address(vetoGovernor));
    assertEq(councilGovernor.owner(), GOVERNANCE_ADMIN);
    assertEq(councilGovernor.votingDelay(), 1 days);
    assertEq(councilGovernor.votingPeriod(), 3 days);
    assertEq(councilGovernor.proposalThreshold(), 1e18);
  }

  function test_DeploysTheVetoGovernorWithTheZipParameters() public view {
    assertEq(vetoGovernor.name(), "ZKsync Protocol Upgrade Veto Governor");
    assertEq(address(vetoGovernor.token()), address(zkToken));
    assertEq(vetoGovernor.COUNCIL(), address(councilGovernor));
    assertEq(vetoGovernor.timelock(), address(protocolTimelock));
    assertEq(vetoGovernor.owner(), GOVERNANCE_ADMIN);
    assertEq(vetoGovernor.votingDelay(), 1 days);
    assertEq(vetoGovernor.votingPeriod(), 7 days);
    assertEq(vetoGovernor.vetoThreshold(block.timestamp), 630_000_000e18);
    assertEq(vetoGovernor.votingPeriodExtension(), 2 days);
    assertEq(vetoGovernor.minorVetoExtensionThresholdPct(), 50);
    assertEq(vetoGovernor.vetoGuardian(), 0xF197677d63BF6E2841F5108b8dFd2FD6eCEff74B);
    assertEq(vetoGovernor.vetoOverrideRole(), address(overrideTimelock));
    assertEq(vetoGovernor.vetoOverrideDuration(), 14 days);
  }

  function test_LeavesTheDeployerNoSeatOrAdminRole() public view {
    assertEq(councilToken.balanceOf(DEFAULT_SENDER), 0);
    assertTrue(councilToken.owner() != DEFAULT_SENDER);
    assertTrue(councilGovernor.owner() != DEFAULT_SENDER);
    assertTrue(vetoGovernor.owner() != DEFAULT_SENDER);
  }
}

contract Check is DeployZkProtocolUpgradeGovernanceTest {
  function test_PassesForTheDeploymentRunMade() public {
    run();
    vm.setEnv("SUPERMAJORITY_GOVERNOR", vm.toString(address(supermajorityGovernor)));
    vm.setEnv("OVERRIDE_TIMELOCK", vm.toString(address(overrideTimelock)));
    vm.setEnv("COUNCIL_TOKEN", vm.toString(address(councilToken)));
    vm.setEnv("COUNCIL_GOVERNOR", vm.toString(address(councilGovernor)));
    vm.setEnv("VETO_GOVERNOR", vm.toString(address(vetoGovernor)));
    vm.setEnv("DEPLOYER", vm.toString(DEFAULT_SENDER));

    check();
  }
}

// `vm.expectRevert` applies to the next external call, so these tests call `run` through `this`.
contract RunReverts is DeployZkProtocolUpgradeGovernanceTest {
  function test_RevertIf_TheOverrideTimelockDoesNotBelongToTheSupermajorityGovernor() public {
    supermajorityGovernor = new FakeSupermajorityGovernor(_supermajorityGovernorSettings(makeAddr("Other Timelock")));

    vm.expectRevert("SupermajorityGovernorChecks: the Supermajority Governor's timelock is not the override timelock");
    this.run();
  }

  function test_RevertIf_TheSupermajorityGovernorHasADifferentQuorum() public {
    FakeSupermajorityGovernor.Settings memory _settings = _supermajorityGovernorSettings(address(overrideTimelock));
    _settings.quorum += 1;
    supermajorityGovernor = new FakeSupermajorityGovernor(_settings);
    overrideTimelock.grantRole(overrideTimelock.PROPOSER_ROLE(), address(supermajorityGovernor));
    overrideTimelock.grantRole(overrideTimelock.CANCELLER_ROLE(), address(supermajorityGovernor));

    vm.expectRevert("SupermajorityGovernorChecks: Supermajority Governor quorum does not match the params");
    this.run();
  }

  function test_RevertIf_TheVetoOverrideWindowIsShorterThanASupermajorityOverride() public {
    shortenVetoOverrideWindow = true;

    vm.expectRevert(
      "DeployZkProtocolUpgradeGovernance: vetoGovernorVetoOverrideDuration is too short for a supermajority override"
    );
    this.run();
  }

  function test_RevertIf_TheProtocolTimelockHasNoCode() public {
    protocolTimelock = TimelockController(payable(makeAddr("Account Without Code")));

    vm.expectRevert("DeployZkProtocolUpgradeGovernance: protocolTimelock has no code; set it to the Protocol Timelock");
    this.run();
  }

  function test_RevertIf_TheDeployerHoldsARoleOnTheOverrideTimelock() public {
    _deployStepOneAs(DEFAULT_SENDER);
    vm.prank(DEFAULT_SENDER);
    overrideTimelock.grantRole(TIMELOCK_ADMIN_ROLE, DEFAULT_SENDER);

    vm.expectRevert("SupermajorityGovernorChecks: the deployer holds a role on the override timelock");
    this.run();
  }
}

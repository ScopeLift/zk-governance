// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/configs/ZkProtocolUpgradeDeploymentConfig.sol";
import {FakeSupermajorityGovernor} from "test/fakes/FakeSupermajorityGovernor.sol";
import {
  DeployZkProtocolUpgradeGovernanceEraMainnetHarness
} from "test/harnesses/DeployZkProtocolUpgradeGovernanceHarness.sol";

interface IZkCheatcodes {
  function zkVmSkip() external;
}

/// @notice Runs the Era mainnet council deployment on a fork of Era mainnet, against the live ZK token and Protocol
/// Timelock. Only the Supermajority Governor and override timelock, which are not deployed yet, are test doubles.
/// @dev The script is deployed behind `zkVmSkip`, so under `--zksync` it lands in the EVM, where its cheatcodes work,
/// as `forge script --zksync` runs it.
contract DeployZkProtocolUpgradeGovernanceTest is Test {
  string constant ZKSYNC_RPC_URL = "https://mainnet.era.zksync.io";
  // A fork block where the ZK token and the Protocol Timelock are both deployed.
  uint256 constant FORK_BLOCK = 72_650_000;
  // The real override timelock is OpenZeppelin v4, whose admin role is TIMELOCK_ADMIN_ROLE.
  bytes32 constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

  DeployZkProtocolUpgradeGovernanceEraMainnetHarness script;
  TimelockController overrideTimelock;
  FakeSupermajorityGovernor supermajorityGovernor;

  function setUp() public virtual {
    vm.createSelectFork(ZKSYNC_RPC_URL, FORK_BLOCK);
    // The default sender pays for the EraVM transactions the script broadcasts.
    vm.deal(DEFAULT_SENDER, 1 ether);
    IZkCheatcodes(address(vm)).zkVmSkip();
    script = new DeployZkProtocolUpgradeGovernanceEraMainnetHarness();
    script.disableLogging();
    _deploySupermajorityGovernor();
  }

  // Deploys test doubles of the override timelock and Supermajority Governor as `DeploySupermajorityGovernor` leaves
  // them: the governor proposes and cancels, anyone executes, and the timelock administers itself. The real ones are
  // OpenZeppelin v4 contracts this project cannot build. The test contract keeps OpenZeppelin v5's admin role, so tests
  // can grant extra roles; it is not the deployer the checks look at.
  function _deploySupermajorityGovernor() internal {
    address[] memory _openExecutor = new address[](1);
    overrideTimelock = new TimelockController(1 days, new address[](0), _openExecutor, address(this));
    supermajorityGovernor = new FakeSupermajorityGovernor(_supermajorityGovernorSettings(address(overrideTimelock)));
    overrideTimelock.grantRole(overrideTimelock.PROPOSER_ROLE(), address(supermajorityGovernor));
    overrideTimelock.grantRole(overrideTimelock.CANCELLER_ROLE(), address(supermajorityGovernor));
    overrideTimelock.grantRole(TIMELOCK_ADMIN_ROLE, address(overrideTimelock));
    script.setSupermajorityGovernorContracts(address(supermajorityGovernor), overrideTimelock);
  }

  // The settings `DeploySupermajorityGovernor` gives the Supermajority Governor, from the same params the council
  // deployment checks it against.
  function _supermajorityGovernorSettings(address _timelock)
    internal
    view
    returns (FakeSupermajorityGovernor.Settings memory)
  {
    ZkProtocolUpgradeDeploymentConfig.DeploymentParams memory _params = script.deploymentParams();
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
}

contract Run is DeployZkProtocolUpgradeGovernanceTest {
  function setUp() public override {
    super.setUp();
    script.run();
  }

  function test_MintsOneSeatToEachCouncilMemberAndHandsTheTokenToTheGovernanceAdmin() public view {
    ZkProtocolUpgradeDeploymentConfig.DeploymentParams memory _params = script.deploymentParams();
    CouncilERC20 _councilToken = script.councilToken();

    assertEq(_councilToken.name(), "ZKsync Protocol Upgrade Council Seat");
    assertEq(_councilToken.symbol(), "ZKPUC");
    assertEq(_councilToken.owner(), _params.governanceAdmin);
    assertEq(_councilToken.totalSupply(), 8e18);
    for (uint256 _i = 0; _i < _params.councilMembers.length; _i += 1) {
      assertEq(_councilToken.getVotes(_params.councilMembers[_i]), 1e18);
    }
  }

  function test_DeploysTheCouncilGovernorWiredToTheVetoGovernor() public view {
    ZkProtocolUpgradeCouncilGovernor _councilGovernor = script.councilGovernor();

    assertEq(_councilGovernor.name(), "ZKsync Protocol Upgrade Council");
    assertEq(address(_councilGovernor.token()), address(script.councilToken()));
    assertEq(_councilGovernor.QUORUM(), 1e18);
    assertEq(address(_councilGovernor.councilVetoGovernor()), address(script.vetoGovernor()));
    assertEq(_councilGovernor.owner(), script.deploymentParams().governanceAdmin);
    assertEq(_councilGovernor.votingDelay(), 1 days);
    assertEq(_councilGovernor.votingPeriod(), 3 days);
    assertEq(_councilGovernor.proposalThreshold(), 1e18);
  }

  function test_DeploysTheVetoGovernorWithTheZipParameters() public view {
    ZkProtocolUpgradeDeploymentConfig.DeploymentParams memory _params = script.deploymentParams();
    ZkProtocolUpgradeVetoGovernor _vetoGovernor = script.vetoGovernor();

    assertEq(_vetoGovernor.name(), "ZKsync Protocol Upgrade Veto Governor");
    assertEq(address(_vetoGovernor.token()), _params.zkToken);
    assertEq(_vetoGovernor.COUNCIL(), address(script.councilGovernor()));
    assertEq(_vetoGovernor.timelock(), _params.protocolTimelock);
    assertEq(_vetoGovernor.owner(), _params.governanceAdmin);
    assertEq(_vetoGovernor.votingDelay(), 1 days);
    assertEq(_vetoGovernor.votingPeriod(), 7 days);
    assertEq(_vetoGovernor.vetoThreshold(block.timestamp), 630_000_000e18);
    assertEq(_vetoGovernor.votingPeriodExtension(), 2 days);
    assertEq(_vetoGovernor.minorVetoExtensionThresholdPct(), 50);
    assertEq(_vetoGovernor.vetoGuardian(), 0xF197677d63BF6E2841F5108b8dFd2FD6eCEff74B);
    assertEq(_vetoGovernor.vetoOverrideRole(), address(overrideTimelock));
    assertEq(_vetoGovernor.vetoOverrideDuration(), 14 days);
  }

  function test_LeavesTheDeployerNoSeatOrAdminRole() public view {
    assertEq(script.councilToken().balanceOf(DEFAULT_SENDER), 0);
    assertTrue(script.councilToken().owner() != DEFAULT_SENDER);
    assertTrue(script.councilGovernor().owner() != DEFAULT_SENDER);
    assertTrue(script.vetoGovernor().owner() != DEFAULT_SENDER);
  }

  function test_DeploysWhenTheSupermajorityGovernorHasADifferentDeployer() public {
    script.setSupermajorityGovernorDeployer(makeAddr("Supermajority Governor Deployer"));

    script.run();

    assertEq(script.vetoGovernor().vetoOverrideRole(), address(overrideTimelock));
  }
}

contract Check is DeployZkProtocolUpgradeGovernanceTest {
  function test_PassesForTheDeploymentRunMade() public {
    // Reads the Supermajority Governor's deployer from `SUPERMAJORITY_GOVERNOR_DEPLOYER`, as the script does.
    script.setReadSupermajorityGovernorDeployerFromEnv(true);
    vm.setEnv("SUPERMAJORITY_GOVERNOR_DEPLOYER", vm.toString(makeAddr("Supermajority Governor Deployer")));
    script.run();
    vm.setEnv("SUPERMAJORITY_GOVERNOR", vm.toString(address(supermajorityGovernor)));
    vm.setEnv("OVERRIDE_TIMELOCK", vm.toString(address(overrideTimelock)));
    vm.setEnv("COUNCIL_TOKEN", vm.toString(address(script.councilToken())));
    vm.setEnv("COUNCIL_GOVERNOR", vm.toString(address(script.councilGovernor())));
    vm.setEnv("VETO_GOVERNOR", vm.toString(address(script.vetoGovernor())));
    vm.setEnv("DEPLOYER", vm.toString(DEFAULT_SENDER));

    script.check();
  }
}

contract RunReverts is DeployZkProtocolUpgradeGovernanceTest {
  function test_RevertIf_TheOverrideTimelockDoesNotBelongToTheSupermajorityGovernor() public {
    supermajorityGovernor = new FakeSupermajorityGovernor(_supermajorityGovernorSettings(makeAddr("Other Timelock")));
    script.setSupermajorityGovernorContracts(address(supermajorityGovernor), overrideTimelock);

    vm.expectRevert("SupermajorityGovernorChecks: the Supermajority Governor's timelock is not the override timelock");
    script.run();
  }

  function test_RevertIf_TheSupermajorityGovernorHasADifferentQuorum() public {
    FakeSupermajorityGovernor.Settings memory _settings = _supermajorityGovernorSettings(address(overrideTimelock));
    _settings.quorum += 1;
    supermajorityGovernor = new FakeSupermajorityGovernor(_settings);
    overrideTimelock.grantRole(overrideTimelock.PROPOSER_ROLE(), address(supermajorityGovernor));
    overrideTimelock.grantRole(overrideTimelock.CANCELLER_ROLE(), address(supermajorityGovernor));
    script.setSupermajorityGovernorContracts(address(supermajorityGovernor), overrideTimelock);

    vm.expectRevert("SupermajorityGovernorChecks: Supermajority Governor quorum does not match the params");
    script.run();
  }

  function test_RevertIf_TheVetoOverrideWindowIsShorterThanASupermajorityOverride() public {
    script.setShortenVetoOverrideWindow(true);

    vm.expectRevert(
      "SupermajorityGovernorChecks: vetoGovernorVetoOverrideDuration is too short for a supermajority override"
    );
    script.run();
  }

  function test_RevertIf_TheVetoGuardianIsTheZeroAddress() public {
    script.setOmitVetoGuardian(true);

    vm.expectRevert(
      "DeployZkProtocolUpgradeGovernance: vetoGovernorVetoGuardian is the zero address; set the veto guardian"
    );
    script.run();
  }

  function test_RevertIf_TheProtocolTimelockHasNoCode() public {
    script.setUseCodelessProtocolTimelock(true);

    vm.expectRevert("DeployZkProtocolUpgradeGovernance: protocolTimelock has no code; set it to the Protocol Timelock");
    script.run();
  }

  // The real override timelock is OpenZeppelin v4, so the v4 admin role is checked on its own.
  function test_RevertIf_TheDeployerHoldsTheV4AdminRoleOnTheOverrideTimelock() public {
    overrideTimelock.grantRole(TIMELOCK_ADMIN_ROLE, DEFAULT_SENDER);

    vm.expectRevert("SupermajorityGovernorChecks: the deployer holds a role on the override timelock");
    script.run();
  }

  // A wrong OpenZeppelin v5 timelock still administered by the deployer is caught too.
  function test_RevertIf_TheDeployerHoldsTheV5AdminRoleOnTheOverrideTimelock() public {
    overrideTimelock.grantRole(bytes32(0), DEFAULT_SENDER);

    vm.expectRevert("SupermajorityGovernorChecks: the deployer holds a role on the override timelock");
    script.run();
  }

  function test_RevertIf_TheSupermajorityGovernorDeployerHoldsARoleOnTheOverrideTimelock() public {
    address _supermajorityGovernorDeployer = makeAddr("Supermajority Governor Deployer");
    script.setSupermajorityGovernorDeployer(_supermajorityGovernorDeployer);
    overrideTimelock.grantRole(overrideTimelock.PROPOSER_ROLE(), _supermajorityGovernorDeployer);

    vm.expectRevert("SupermajorityGovernorChecks: the deployer holds a role on the override timelock");
    script.run();
  }
}

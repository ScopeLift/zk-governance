// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProposeProtocolTimelockRoleMigrationEraMainnet} from "script/ProposeProtocolTimelockRoleMigration.s.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/ZkProtocolUpgradeEraMainnetConfig.sol";
import {FakeProtocolGovernor} from "test/fakes/FakeProtocolGovernor.sol";

/// @notice Runs the Era mainnet role migration script against a fake `ZkProtocolGovernor` and a Protocol Timelock set
/// up as on mainnet: self-administered, no delay, and `ZkProtocolGovernor` holding the three roles.
/// @dev The deployment checks the script runs first are covered by `DeployZkProtocolUpgradeGovernance.t.sol`, so they
/// are skipped here, where no council governance is deployed. The test inherits the script, so its cheatcodes run in
/// the EVM under `--zksync`.
contract ProposeProtocolTimelockRoleMigrationTest is Test, ProposeProtocolTimelockRoleMigrationEraMainnet {
  TimelockController protocolTimelock;
  FakeProtocolGovernor protocolGovernor;
  address vetoGovernor = makeAddr("Veto Governor");
  // The proposals the fake governor reports having created, in place of its `ProposalCreated` logs.
  uint256[] protocolGovernorProposalIds;
  // Each test that writes a manifest uses its own path, since tests run in parallel.
  string manifestPath;

  function setUp() public virtual {
    vm.warp(1_700_000_000);
    protocolTimelock = new TimelockController(0, new address[](0), new address[](0), address(this));
    protocolGovernor = new FakeProtocolGovernor(address(protocolTimelock));
    protocolTimelock.grantRole(PROPOSER_ROLE, address(protocolGovernor));
    protocolTimelock.grantRole(EXECUTOR_ROLE, address(protocolGovernor));
    protocolTimelock.grantRole(CANCELLER_ROLE, address(protocolGovernor));
    // The real Protocol Timelock is OpenZeppelin v4, whose admin role is TIMELOCK_ADMIN_ROLE.
    protocolTimelock.grantRole(TIMELOCK_ADMIN_ROLE, address(protocolTimelock));
    disableLogging();
  }

  function _deploymentParams()
    internal
    view
    override(ZkProtocolUpgradeDeploymentConfig, ZkProtocolUpgradeEraMainnetConfig)
    returns (DeploymentParams memory _params)
  {
    _params = ZkProtocolUpgradeEraMainnetConfig._deploymentParams();
    _params.protocolTimelock = address(protocolTimelock);
  }

  function _protocolGovernor() internal view override returns (address) {
    return address(protocolGovernor);
  }

  function _deployedVetoGovernor() internal view override returns (address) {
    return vetoGovernor;
  }

  function _validateExistingDeployment() internal view override {}

  function _protocolGovernorProposalIds() internal view override returns (uint256[] memory) {
    return protocolGovernorProposalIds;
  }

  function _manifestPath() internal view override returns (string memory) {
    return manifestPath;
  }

  // Records a `ZkProtocolGovernor` proposal other than the migration, in a given state.
  function _addProtocolGovernorProposal(uint256 _proposalId, IGovernor.ProposalState _state) internal {
    protocolGovernor.setState(_proposalId, _state);
    protocolGovernorProposalIds.push(_proposalId);
  }

  // Sets the migration proposal's state on the fake `ZkProtocolGovernor`.
  function _setMigrationProposalState(IGovernor.ProposalState _state) internal {
    protocolGovernor.setState(_hashProposal(_migrationProposal(vetoGovernor)), _state);
  }

  // Schedules the migration batch on the timelock, as `ZkProtocolGovernor` does when the proposal is queued.
  function _queueMigrationProposal() internal {
    Proposal memory _proposal = _migrationProposal(vetoGovernor);
    vm.prank(address(protocolGovernor));
    protocolTimelock.scheduleBatch(
      _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), keccak256(bytes(_proposal.description)), 0
    );
  }

  function _assertRolesMovedToTheVetoGovernor() internal view {
    bytes32[3] memory _roles = _migratedRoles();
    for (uint256 _i = 0; _i < 3; _i += 1) {
      assertTrue(protocolTimelock.hasRole(_roles[_i], vetoGovernor));
      assertFalse(protocolTimelock.hasRole(_roles[_i], address(protocolGovernor)));
    }
  }
}

contract MigrationProposal is ProposeProtocolTimelockRoleMigrationTest {
  function test_GrantsEveryRoleToTheVetoGovernorBeforeRevokingAnyFromZkProtocolGovernor() public view {
    Proposal memory _proposal = _migrationProposal(vetoGovernor);
    bytes32[3] memory _roles = _migratedRoles();

    assertEq(_proposal.targets.length, 6);
    for (uint256 _i = 0; _i < 3; _i += 1) {
      assertEq(_proposal.targets[_i], address(protocolTimelock));
      assertEq(_proposal.calldatas[_i], abi.encodeCall(IAccessControl.grantRole, (_roles[_i], vetoGovernor)));
      assertEq(_proposal.targets[_i + 3], address(protocolTimelock));
      assertEq(
        _proposal.calldatas[_i + 3], abi.encodeCall(IAccessControl.revokeRole, (_roles[_i], address(protocolGovernor)))
      );
    }
  }
}

contract Run is ProposeProtocolTimelockRoleMigrationTest {
  function test_WritesAManifestOfTheProposalAndSimulatesItsExecution() public {
    manifestPath = "proposals/test-run-writes-a-manifest.json";

    run();

    Proposal memory _proposal = _migrationProposal(vetoGovernor);
    string memory _manifest = vm.readFile(manifestPath);
    vm.removeFile(manifestPath);
    assertEq(vm.parseJsonBytes32(_manifest, ".proposalId"), bytes32(_hashProposal(_proposal)));
    assertEq(vm.parseJsonBytes32(_manifest, ".timelockOperationId"), _timelockOperationId(_proposal));
    assertEq(vm.parseJsonAddress(_manifest, ".vetoGovernor"), vetoGovernor);
    assertEq(vm.parseJsonStringArray(_manifest, ".calls").length, 6);
    _assertRolesMovedToTheVetoGovernor();
  }

  function test_RecordsButDoesNotFailOnOtherProposalsInFlight() public {
    manifestPath = "proposals/test-run-records-proposals-in-flight.json";
    _addProtocolGovernorProposal(1, IGovernor.ProposalState.Active);
    _addProtocolGovernorProposal(2, IGovernor.ProposalState.Executed);

    run();

    string memory _manifest = vm.readFile(manifestPath);
    vm.removeFile(manifestPath);
    bytes32[] memory _inFlight = vm.parseJsonBytes32Array(_manifest, ".inFlightProposalsAtGeneration");
    assertEq(_inFlight.length, 1);
    assertEq(_inFlight[0], bytes32(uint256(1)));
  }
}

contract CheckReadyToExecute is ProposeProtocolTimelockRoleMigrationTest {
  function test_PassesOnceTheMigrationProposalSucceedsBeforeItIsQueued() public {
    _setMigrationProposalState(IGovernor.ProposalState.Succeeded);

    checkReadyToExecute();

    _assertRolesMovedToTheVetoGovernor();
  }

  function test_PassesOnceTheMigrationProposalIsQueued() public {
    _setMigrationProposalState(IGovernor.ProposalState.Queued);
    _queueMigrationProposal();

    checkReadyToExecute();

    _assertRolesMovedToTheVetoGovernor();
  }

  function test_IgnoresProposalsThatCanNoLongerUseTheRoles() public {
    _setMigrationProposalState(IGovernor.ProposalState.Succeeded);
    _addProtocolGovernorProposal(1, IGovernor.ProposalState.Defeated);
    _addProtocolGovernorProposal(2, IGovernor.ProposalState.Canceled);
    _addProtocolGovernorProposal(3, IGovernor.ProposalState.Executed);

    checkReadyToExecute();

    _assertRolesMovedToTheVetoGovernor();
  }

  function test_RevertIf_OtherProposalsArePendingOrQueued() public {
    _setMigrationProposalState(IGovernor.ProposalState.Succeeded);
    _addProtocolGovernorProposal(7, IGovernor.ProposalState.Pending);
    _addProtocolGovernorProposal(8, IGovernor.ProposalState.Queued);

    vm.expectRevert(
      bytes(
        string.concat(
          "ProposeProtocolTimelockRoleMigration: other ZkProtocolGovernor proposals are in flight: ",
          vm.toString(bytes32(uint256(7))),
          ", ",
          vm.toString(bytes32(uint256(8)))
        )
      )
    );
    this.checkReadyToExecute();
  }

  function test_RevertIf_TheMigrationProposalHasNotPassed() public {
    _setMigrationProposalState(IGovernor.ProposalState.Active);

    vm.expectRevert("ProtocolTimelockRoleMigration: the migration proposal has not passed on ZkProtocolGovernor");
    this.checkReadyToExecute();
  }

  function test_RevertIf_TheVetoGovernorAlreadyHoldsARole() public {
    protocolTimelock.grantRole(PROPOSER_ROLE, vetoGovernor);

    vm.expectRevert("ProtocolTimelockRoleMigration: the Veto Governor already holds a Protocol Timelock role");
    this.checkReadyToExecute();
  }

  function test_RevertIf_ZkProtocolGovernorDoesNotUseTheProtocolTimelock() public {
    protocolGovernor = new FakeProtocolGovernor(makeAddr("Other Timelock"));

    vm.expectRevert("ProtocolTimelockRoleMigration: ZkProtocolGovernor does not use the Protocol Timelock");
    this.checkReadyToExecute();
  }

  function test_RevertIf_ZkProtocolGovernorIsMissingARole() public {
    protocolTimelock.revokeRole(EXECUTOR_ROLE, address(protocolGovernor));

    vm.expectRevert(
      "ProtocolTimelockRoleMigration: ZkProtocolGovernor is missing a Protocol Timelock role it should hold"
    );
    this.checkReadyToExecute();
  }

  function test_RevertIf_ARoleIsOpenToEveryAccount() public {
    protocolTimelock.grantRole(CANCELLER_ROLE, address(0));

    vm.expectRevert("ProtocolTimelockRoleMigration: a Protocol Timelock role is open to every account");
    this.checkReadyToExecute();
  }
}

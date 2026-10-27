// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
  ProposeProtocolTimelockRoleMigrationEraMainnet
} from "script/ProposeProtocolTimelockRoleMigrationEraMainnet.s.sol";
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

  function setUp() public virtual {
    vm.warp(1_700_000_000);
    protocolTimelock = new TimelockController(0, new address[](0), new address[](0), address(this));
    protocolGovernor = new FakeProtocolGovernor(address(protocolTimelock));
    protocolTimelock.grantRole(PROPOSER_ROLE, address(protocolGovernor));
    protocolTimelock.grantRole(EXECUTOR_ROLE, address(protocolGovernor));
    protocolTimelock.grantRole(CANCELLER_ROLE, address(protocolGovernor));
    // The real Protocol Timelock is OpenZeppelin v4, whose admin role is TIMELOCK_ADMIN_ROLE.
    protocolTimelock.grantRole(TIMELOCK_ADMIN_ROLE, address(protocolTimelock));
    // The fake governor has no `proposalSnapshot`, so by default it reports that no proposal exists.
    vm.mockCall(
      address(protocolGovernor), abi.encodeWithSelector(IGovernor.proposalSnapshot.selector), abi.encode(uint256(0))
    );
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

  // Records a `ZkProtocolGovernor` proposal in a given state, with a snapshot so that it exists.
  function _addProtocolGovernorProposal(uint256 _proposalId, IGovernor.ProposalState _state) internal {
    protocolGovernor.setState(_proposalId, _state);
    vm.mockCall(
      address(protocolGovernor), abi.encodeCall(IGovernor.proposalSnapshot, (_proposalId)), abi.encode(block.number)
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
  function test_ProposesTheMigrationOnZkProtocolGovernor() public {
    run();

    uint256 _proposalId = _hashProposal(_migrationProposal(vetoGovernor));
    assertEq(uint8(protocolGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Pending));
    _assertRolesMovedToTheVetoGovernor();
  }

  function test_RevertIf_TheMigrationProposalAlreadyExists() public {
    _addProtocolGovernorProposal(_hashProposal(_migrationProposal(vetoGovernor)), IGovernor.ProposalState.Active);

    vm.expectRevert(
      "ProposeProtocolTimelockRoleMigration: the migration proposal already exists on ZkProtocolGovernor (Active)"
    );
    this.run();
  }

  function test_RevertIf_TheProposerIsBelowTheProposalThreshold() public {
    protocolGovernor.setProposalThreshold(1);

    vm.expectRevert(
      "ProposeProtocolTimelockRoleMigration: the proposer's votes are below ZkProtocolGovernor's threshold"
    );
    this.run();
  }

  function test_RevertIf_TheVetoGovernorAlreadyHoldsARole() public {
    protocolTimelock.grantRole(PROPOSER_ROLE, vetoGovernor);

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: the Veto Governor already holds a Protocol Timelock role");
    this.run();
  }

  function test_RevertIf_ZkProtocolGovernorDoesNotUseTheProtocolTimelock() public {
    protocolGovernor = new FakeProtocolGovernor(makeAddr("Other Timelock"));

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor does not use the Protocol Timelock");
    this.run();
  }

  function test_RevertIf_ZkProtocolGovernorIsMissingARole() public {
    protocolTimelock.revokeRole(EXECUTOR_ROLE, address(protocolGovernor));

    vm.expectRevert(
      "ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor is missing a Protocol Timelock role it should hold"
    );
    this.run();
  }

  function test_RevertIf_AGovernorWouldAdministerTheTimelockAfterTheMigration() public {
    protocolTimelock.grantRole(TIMELOCK_ADMIN_ROLE, vetoGovernor);

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: a governor administers the Protocol Timelock");
    this.run();
  }

  function test_RevertIf_ARoleIsOpenToEveryAccount() public {
    protocolTimelock.grantRole(CANCELLER_ROLE, address(0));

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: a Protocol Timelock role is open to every account");
    this.run();
  }
}

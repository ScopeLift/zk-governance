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
    // A zero-delay operation scheduled at timestamp 1 would read as done, since the timelock marks done operations
    // with timestamp 1.
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

  // Excludes the accounts the Veto Governor cannot be: the zero address, which the timelock treats as every account,
  // `ZkProtocolGovernor`, which gives up the roles, and the Protocol Timelock, which administers itself.
  function _assumeValidVetoGovernor(address _vetoGovernor) internal view {
    vm.assume(_vetoGovernor != address(0));
    vm.assume(_vetoGovernor != address(protocolGovernor));
    vm.assume(_vetoGovernor != address(protocolTimelock));
  }

  function _boundToMigratedRole(uint256 _roleIndex) internal pure returns (bytes32) {
    return _migratedRoles()[_bound(_roleIndex, 0, 2)];
  }

  function _boundToProposalState(uint8 _state) internal pure returns (IGovernor.ProposalState) {
    return IGovernor.ProposalState(_bound(_state, 0, uint8(type(IGovernor.ProposalState).max)));
  }

  // The name the script reports for a proposal state.
  function _proposalStateName(IGovernor.ProposalState _state) internal pure returns (string memory) {
    string[8] memory _stateNames =
      ["Pending", "Active", "Canceled", "Defeated", "Succeeded", "Queued", "Expired", "Executed"];
    return _stateNames[uint8(_state)];
  }
}

contract MigrationProposal is ProposeProtocolTimelockRoleMigrationTest {
  function testFuzz_GrantsEveryRoleToTheVetoGovernorBeforeRevokingAnyFromZkProtocolGovernor(address _vetoGovernor)
    public
    view
  {
    Proposal memory _proposal = _migrationProposal(_vetoGovernor);
    bytes32[3] memory _roles = _migratedRoles();

    assertEq(_proposal.targets.length, 6);
    for (uint256 _i = 0; _i < 3; _i += 1) {
      assertEq(_proposal.targets[_i], address(protocolTimelock));
      assertEq(_proposal.calldatas[_i], abi.encodeCall(IAccessControl.grantRole, (_roles[_i], _vetoGovernor)));
      assertEq(_proposal.targets[_i + 3], address(protocolTimelock));
      assertEq(
        _proposal.calldatas[_i + 3], abi.encodeCall(IAccessControl.revokeRole, (_roles[_i], address(protocolGovernor)))
      );
    }
  }
}

contract Run is ProposeProtocolTimelockRoleMigrationTest {
  function testFuzz_ProposesTheMigrationOnZkProtocolGovernor(address _vetoGovernor) public {
    _assumeValidVetoGovernor(_vetoGovernor);
    vetoGovernor = _vetoGovernor;

    run();

    uint256 _proposalId = _hashProposal(_migrationProposal(_vetoGovernor));
    assertEq(uint8(protocolGovernor.state(_proposalId)), uint8(IGovernor.ProposalState.Pending));
  }

  function testFuzz_RevertIf_TheMigrationProposalAlreadyExists(uint8 _state) public {
    IGovernor.ProposalState _existingState = _boundToProposalState(_state);
    _addProtocolGovernorProposal(_hashProposal(_migrationProposal(vetoGovernor)), _existingState);

    vm.expectRevert(
      bytes(
        string.concat(
          "ProposeProtocolTimelockRoleMigration: the migration proposal already exists on ZkProtocolGovernor (",
          _proposalStateName(_existingState),
          ")"
        )
      )
    );
    this.run();
  }

  function testFuzz_RevertIf_TheProposerIsBelowTheProposalThreshold(uint256 _proposalThreshold) public {
    protocolGovernor.setProposalThreshold(_bound(_proposalThreshold, 1, type(uint256).max));

    vm.expectRevert(
      "ProposeProtocolTimelockRoleMigration: the proposer's votes are below ZkProtocolGovernor's threshold"
    );
    this.run();
  }

  function testFuzz_RevertIf_TheVetoGovernorAlreadyHoldsARole(uint256 _roleIndex) public {
    protocolTimelock.grantRole(_boundToMigratedRole(_roleIndex), vetoGovernor);

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: the Veto Governor already holds a Protocol Timelock role");
    this.run();
  }

  function testFuzz_RevertIf_ZkProtocolGovernorDoesNotUseTheProtocolTimelock(address _otherTimelock) public {
    vm.assume(_otherTimelock != address(protocolTimelock));
    protocolGovernor = new FakeProtocolGovernor(_otherTimelock);

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor does not use the Protocol Timelock");
    this.run();
  }

  function testFuzz_RevertIf_ZkProtocolGovernorIsMissingARole(uint256 _roleIndex) public {
    protocolTimelock.revokeRole(_boundToMigratedRole(_roleIndex), address(protocolGovernor));

    vm.expectRevert(
      "ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor is missing a Protocol Timelock role it should hold"
    );
    this.run();
  }

  function testFuzz_RevertIf_AGovernorWouldAdministerTheTimelockAfterTheMigration(bool _vetoGovernorIsAdmin) public {
    protocolTimelock.grantRole(TIMELOCK_ADMIN_ROLE, _vetoGovernorIsAdmin ? vetoGovernor : address(protocolGovernor));

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: a governor administers the Protocol Timelock");
    this.run();
  }

  function testFuzz_RevertIf_ARoleIsOpenToEveryAccount(uint256 _roleIndex) public {
    protocolTimelock.grantRole(_boundToMigratedRole(_roleIndex), address(0));

    vm.expectRevert("ProposeProtocolTimelockRoleMigration: a Protocol Timelock role is open to every account");
    this.run();
  }
}

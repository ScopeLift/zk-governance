// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {VmSafe} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ZkProtocolUpgradeDeploymentChecks} from "script/ZkProtocolUpgradeDeploymentChecks.sol";

/// @title ProtocolTimelockRoleMigration
/// @author [ScopeLift](https://scopelift.co)
/// @notice Builds and checks the `ZkProtocolGovernor` proposal that moves the proposer, executor and canceller roles on
/// the Protocol Timelock from `ZkProtocolGovernor` to `ZkProtocolUpgradeVetoGovernor`.
/// @dev The Protocol Timelock is an OpenZeppelin v4 `TimelockController` that administers itself, so the proposal's
/// calls target the timelock directly and run with the timelock as `msg.sender`. All three roles are granted to the
/// Veto Governor before any is revoked from `ZkProtocolGovernor`, in one proposal, so the timelock is never left
/// without a proposer, executor or canceller. Revoking `EXECUTOR_ROLE` from `ZkProtocolGovernor` while it executes this
/// proposal is safe, because the timelock checks the role only on entry to `executeBatch`.
///
/// The timelock's minimum delay of zero and its self-administration are unchanged.
///
/// Once the proposal executes, `ZkProtocolGovernor` can no longer queue, execute or cancel on the timelock, so any of
/// its other proposals still in flight at that point are stranded. `_inFlightProposals` lists them.
abstract contract ProtocolTimelockRoleMigration is ZkProtocolUpgradeDeploymentChecks {
  /// @notice The governor that currently holds the proposer, executor and canceller roles on the Protocol Timelock.
  address internal constant PROTOCOL_GOVERNOR = 0x76705327e682F2d96943280D99464Ab61219e34f;

  /// @notice The block of `ZkProtocolGovernor`'s first proposal, from which its `ProposalCreated` logs are scanned.
  uint256 internal constant PROTOCOL_GOVERNOR_FIRST_PROPOSAL_BLOCK = 49_077_771;

  /// @notice The admin role of an OpenZeppelin v4 `TimelockController`, which v5 replaced with `DEFAULT_ADMIN_ROLE`.
  bytes32 internal constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

  bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
  bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

  /// @notice A `ZkProtocolGovernor` proposal, in the form `propose` takes it.
  struct Proposal {
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string description;
  }

  /// @notice Builds the migration proposal: grant the three roles to the Veto Governor, then revoke them from
  /// `ZkProtocolGovernor`.
  /// @param _vetoGovernor The Veto Governor that receives the roles.
  /// @return _proposal The proposal.
  function _migrationProposal(address _vetoGovernor) internal pure returns (Proposal memory _proposal) {
    bytes32[3] memory _roles = _migratedRoles();
    _proposal.targets = new address[](6);
    _proposal.values = new uint256[](6);
    _proposal.calldatas = new bytes[](6);
    for (uint256 _i = 0; _i < 3; _i++) {
      _proposal.targets[_i] = PROTOCOL_TIMELOCK;
      _proposal.calldatas[_i] = abi.encodeCall(IAccessControl.grantRole, (_roles[_i], _vetoGovernor));
      _proposal.targets[_i + 3] = PROTOCOL_TIMELOCK;
      _proposal.calldatas[_i + 3] = abi.encodeCall(IAccessControl.revokeRole, (_roles[_i], PROTOCOL_GOVERNOR));
    }
    _proposal.description = _migrationDescription(_vetoGovernor);
  }

  /// @notice The description of the migration proposal. It determines the proposal ID, so it is fixed by the Veto
  /// Governor's address.
  function _migrationDescription(address _vetoGovernor) internal pure returns (string memory) {
    return string.concat(
      "# Move Protocol Timelock roles to the ZKsync Protocol Upgrade Veto Governor\n\n",
      "Grants PROPOSER_ROLE, EXECUTOR_ROLE and CANCELLER_ROLE on the Protocol Timelock (",
      vm.toString(PROTOCOL_TIMELOCK),
      ") to ZkProtocolUpgradeVetoGovernor (",
      vm.toString(_vetoGovernor),
      "), then revokes the same roles from ZkProtocolGovernor (",
      vm.toString(PROTOCOL_GOVERNOR),
      "). After this proposal executes, protocol upgrades are proposed through the ZKsync Protocol Upgrade Council ",
      "and the Veto Governor instead of ZkProtocolGovernor. The timelock's minimum delay and administration are unchanged."
    );
  }

  /// @notice The ID `ZkProtocolGovernor` assigns to a proposal.
  function _hashProposal(Proposal memory _proposal) internal pure returns (uint256) {
    return IGovernor(PROTOCOL_GOVERNOR)
      .hashProposal(_proposal.targets, _proposal.values, _proposal.calldatas, keccak256(bytes(_proposal.description)));
  }

  /// @notice The ID of the batch operation `ZkProtocolGovernor` schedules on the Protocol Timelock when it queues a
  /// proposal. OpenZeppelin v4's `GovernorTimelockControl` uses no predecessor and the description hash as the salt.
  function _timelockOperationId(Proposal memory _proposal) internal pure returns (bytes32) {
    return TimelockController(payable(PROTOCOL_TIMELOCK))
      .hashOperationBatch(
        _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), keccak256(bytes(_proposal.description))
      );
  }

  /// @notice Checks the state the migration starts from: the Veto Governor is fully configured, `ZkProtocolGovernor`
  /// holds the three roles and the Veto Governor holds none, and the timelock administers itself with no delay.
  /// @param _deployment The deployed council governance contracts.
  /// @param _deployer The account that deployed them.
  function _checkBeforeMigration(Deployment memory _deployment, address _deployer) internal view {
    _checkDeployment(_deployment, _deployer);

    TimelockController _timelock = TimelockController(payable(PROTOCOL_TIMELOCK));
    address _vetoGovernor = address(_deployment.vetoGovernor);
    require(
      GovernorTimelockControl(payable(PROTOCOL_GOVERNOR)).timelock() == PROTOCOL_TIMELOCK,
      "migration: protocol governor timelock"
    );
    bytes32[3] memory _roles = _migratedRoles();
    for (uint256 _i = 0; _i < 3; _i++) {
      require(_timelock.hasRole(_roles[_i], PROTOCOL_GOVERNOR), "migration: protocol governor lacks a role");
      require(!_timelock.hasRole(_roles[_i], _vetoGovernor), "migration: veto governor already holds a role");
    }
    _checkProtocolTimelockSettings();
  }

  /// @notice Checks the state the migration ends in: the Veto Governor holds the three roles, `ZkProtocolGovernor`
  /// holds none, and the timelock still administers itself with no delay.
  /// @param _vetoGovernor The Veto Governor.
  function _checkAfterMigration(address _vetoGovernor) internal view {
    TimelockController _timelock = TimelockController(payable(PROTOCOL_TIMELOCK));
    bytes32[3] memory _roles = _migratedRoles();
    for (uint256 _i = 0; _i < 3; _i++) {
      require(_timelock.hasRole(_roles[_i], _vetoGovernor), "migration: veto governor lacks a role");
      require(!_timelock.hasRole(_roles[_i], PROTOCOL_GOVERNOR), "migration: protocol governor kept a role");
    }
    require(!_timelock.hasRole(TIMELOCK_ADMIN_ROLE, PROTOCOL_GOVERNOR), "migration: protocol governor is admin");
    require(!_timelock.hasRole(TIMELOCK_ADMIN_ROLE, _vetoGovernor), "migration: veto governor is admin");
    _checkProtocolTimelockSettings();
  }

  /// @notice Checks the Protocol Timelock settings the migration leaves unchanged.
  function _checkProtocolTimelockSettings() internal view {
    TimelockController _timelock = TimelockController(payable(PROTOCOL_TIMELOCK));
    require(_timelock.getMinDelay() == 0, "migration: protocol timelock delay");
    require(
      _timelock.hasRole(TIMELOCK_ADMIN_ROLE, PROTOCOL_TIMELOCK), "migration: protocol timelock not self-administered"
    );
  }

  /// @notice Executes the migration proposal on the current chain state the way `ZkProtocolGovernor` would after it
  /// passes: queued as a timelock batch, then executed through the timelock by the governor.
  /// @dev For simulation only. It pranks `ZkProtocolGovernor`, so it must not run while broadcasting.
  function _simulateMigration(Proposal memory _proposal) internal {
    TimelockController _timelock = TimelockController(payable(PROTOCOL_TIMELOCK));
    bytes32 _salt = keccak256(bytes(_proposal.description));
    vm.prank(PROTOCOL_GOVERNOR);
    _timelock.scheduleBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt, 0);
    vm.prank(PROTOCOL_GOVERNOR);
    _timelock.executeBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt);
  }

  /// @notice Lists `ZkProtocolGovernor` proposals, other than the migration proposal, that still need the roles the
  /// migration revokes: those that are pending, active, succeeded or queued.
  /// @param _migrationProposalId The ID of the migration proposal, which is excluded.
  /// @return _proposalIds The IDs of the proposals in flight.
  function _inFlightProposals(uint256 _migrationProposalId) internal returns (uint256[] memory _proposalIds) {
    bytes32[] memory _topics = new bytes32[](1);
    _topics[0] = IGovernor.ProposalCreated.selector;
    VmSafe.EthGetLogs[] memory _logs =
      vm.eth_getLogs(PROTOCOL_GOVERNOR_FIRST_PROPOSAL_BLOCK, block.number, PROTOCOL_GOVERNOR, _topics);
    // `ZkProtocolGovernor` has made proposals, so no logs means the RPC endpoint does not serve historical logs (e.g. a
    // local fork), and an empty result would wrongly report that nothing is in flight.
    require(_logs.length > 0, "migration: RPC returned no ZkProtocolGovernor proposals");

    _proposalIds = new uint256[](_logs.length);
    uint256 _count = 0;
    for (uint256 _i = 0; _i < _logs.length; _i++) {
      // `proposalId` is the first, non-indexed field of `ProposalCreated`.
      uint256 _proposalId = abi.decode(_logs[_i].data, (uint256));
      if (_proposalId != _migrationProposalId && _isInFlight(IGovernor(PROTOCOL_GOVERNOR).state(_proposalId))) {
        _proposalIds[_count++] = _proposalId;
      }
    }
    assembly {
      mstore(_proposalIds, _count)
    }
  }

  /// @notice Returns whether a proposal in a given state can still queue, execute or cancel on the timelock.
  function _isInFlight(IGovernor.ProposalState _state) internal pure returns (bool) {
    return _state == IGovernor.ProposalState.Pending || _state == IGovernor.ProposalState.Active
      || _state == IGovernor.ProposalState.Succeeded || _state == IGovernor.ProposalState.Queued;
  }

  /// @notice The roles the migration moves, in the order they are granted and revoked.
  function _migratedRoles() internal pure returns (bytes32[3] memory) {
    return [PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE];
  }
}

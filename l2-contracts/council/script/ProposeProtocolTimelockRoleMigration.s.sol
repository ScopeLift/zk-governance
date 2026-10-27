// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {VmSafe} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IZkProtocolGovernor} from "script/SupermajorityGovernorChecks.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/ZkProtocolUpgradeEraMainnetConfig.sol";
import {ZkProtocolUpgradeGovernanceChecks} from "script/ZkProtocolUpgradeGovernanceChecks.sol";

// Proposes, from the broadcasting delegate, the `ZkProtocolGovernor` proposal that moves the proposer, executor and
// canceller roles on the Protocol Timelock from `ZkProtocolGovernor` to `ZkProtocolUpgradeVetoGovernor`. The proposal
// ID depends on the exact description, so proposing from the script keeps the description on chain, and with it the ID
// `checkReadyToExecute` looks for, exactly as built here.
//
// The Protocol Timelock is an OpenZeppelin v4 `TimelockController` that administers itself, so the proposal's calls
// target the timelock directly and run with the timelock as `msg.sender`. All three roles are granted to the Veto
// Governor before any is revoked from `ZkProtocolGovernor`, in one proposal, so the timelock is never left without a
// proposer, executor or canceller. Revoking `EXECUTOR_ROLE` from `ZkProtocolGovernor` while it executes this proposal
// is safe, because the timelock checks the role only on entry to `executeBatch`. The timelock's minimum delay of zero
// and its self-administration are unchanged.
//
// Once the proposal executes, `ZkProtocolGovernor` can no longer queue, execute or cancel on the timelock, so any of
// its other proposals still in flight at that point are stranded. `_inFlightProposals` lists them.
//
// `run` checks that the deployment is fully configured, that the roles have not moved yet, that the migration has not
// been proposed already, and that the delegate's votes meet the proposal threshold. It then proposes the migration,
// simulates its execution against the live chain state, and checks the result. It lists, but does not fail on, other
// `ZkProtocolGovernor` proposals still in flight, since those may finish before the migration executes.
//
// `checkReadyToExecute` repeats the checks just before the migration proposal executes, whether or not it is queued
// yet. It also fails unless the migration proposal has passed on `ZkProtocolGovernor`, and if any other
// `ZkProtocolGovernor` proposal is still in flight, since executing the migration would strand it.
abstract contract ProposeProtocolTimelockRoleMigration is ZkProtocolUpgradeGovernanceChecks {
  bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
  bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

  // A `ZkProtocolGovernor` proposal, in the form `propose` takes it.
  struct Proposal {
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string description;
  }

  // The governor that holds the three roles on the Protocol Timelock before the migration.
  function _protocolGovernor() internal view virtual returns (address);

  // The block of `ZkProtocolGovernor`'s first proposal, from which its `ProposalCreated` logs are scanned.
  function _protocolGovernorFirstProposalBlock() internal view virtual returns (uint256);

  // Proposes the migration from the broadcasting delegate, and simulates and checks its execution.
  function run() public virtual {
    address _vetoGovernor = _deployedVetoGovernor();
    _checkBeforeMigration(_vetoGovernor);

    Proposal memory _proposal = _migrationProposal(_vetoGovernor);
    uint256 _proposalId = _hashProposal(_proposal);
    uint256[] memory _proposalIds = _protocolGovernorProposalIds();
    uint256[] memory _inFlight = _inFlightProposals(_proposalIds, _proposalId);
    _checkNotAlreadyProposed(_proposalIds, _proposalId);
    _checkProposerMeetsThreshold(msg.sender);

    // Proposed before the simulation, which pranks `ZkProtocolGovernor` and so must stay out of the broadcast.
    vm.startBroadcast();
    uint256 _proposedId = IGovernor(_protocolGovernor())
      .propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
    vm.stopBroadcast();
    if (_proposedId != _proposalId) {
      revert("ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor returned an unexpected proposal ID");
    }

    _simulateMigration(_proposal);
    _checkAfterMigration(_vetoGovernor);

    _log(string.concat("Proposal ID: ", vm.toString(bytes32(_proposalId))));
    _log(string.concat("Governor: ", vm.toString(_protocolGovernor())));
    _log(string.concat("Proposed by: ", vm.toString(msg.sender)));
    _logInFlight(_inFlight);
    _log("Simulated execution: all migration checks passed");
  }

  // Checks that the migration proposal can execute without stranding another `ZkProtocolGovernor` proposal, and that
  // executing it now ends in the expected state.
  function checkReadyToExecute() public virtual {
    address _vetoGovernor = _deployedVetoGovernor();
    _checkBeforeMigration(_vetoGovernor);

    Proposal memory _proposal = _migrationProposal(_vetoGovernor);
    uint256 _proposalId = _hashProposal(_proposal);
    _checkMigrationProposalPassed(_proposalId);
    uint256[] memory _inFlight = _inFlightProposals(_protocolGovernorProposalIds(), _proposalId);
    _logInFlight(_inFlight);
    if (_inFlight.length != 0) {
      revert(
        string.concat(
          "ProposeProtocolTimelockRoleMigration: other ZkProtocolGovernor proposals are in flight: ",
          _joinProposalIds(_inFlight)
        )
      );
    }

    _simulateMigration(_proposal);
    _checkAfterMigration(_vetoGovernor);
    _log("Ready to execute: all migration checks passed");
  }

  // The Protocol Timelock, the timelock the Veto Governor queues and executes through.
  function _protocolTimelock() internal view returns (TimelockController) {
    return TimelockController(payable(_deploymentParams().protocolTimelock));
  }

  // The Veto Governor that receives the roles, read from `VETO_GOVERNOR`.
  function _deployedVetoGovernor() internal view virtual returns (address) {
    return vm.envAddress("VETO_GOVERNOR");
  }

  // Runs every deployment check against the deployed council governance, reading its addresses and their deployer from
  // `COUNCIL_TOKEN`, `COUNCIL_GOVERNOR`, `VETO_GOVERNOR`, `SUPERMAJORITY_GOVERNOR`, `OVERRIDE_TIMELOCK` and `DEPLOYER`.
  function _validateExistingDeployment() internal view virtual {
    _validateDeployment(_deploymentParams(), _deploymentFromEnv(), vm.envAddress("DEPLOYER"));
  }

  // The IDs of every proposal `ZkProtocolGovernor` has created, read from its `ProposalCreated` logs. The RPC endpoint
  // must serve historical logs.
  function _protocolGovernorProposalIds() internal virtual returns (uint256[] memory _proposalIds) {
    bytes32[] memory _topics = new bytes32[](1);
    _topics[0] = IGovernor.ProposalCreated.selector;
    VmSafe.EthGetLogs[] memory _logs =
      vm.eth_getLogs(_protocolGovernorFirstProposalBlock(), block.number, _protocolGovernor(), _topics);
    // `ZkProtocolGovernor` has made proposals, so no logs means the RPC endpoint does not serve historical logs (e.g. a
    // local fork), and an empty result would wrongly report that nothing is in flight.
    if (_logs.length == 0) {
      revert(
        "ProposeProtocolTimelockRoleMigration: the RPC returned no ZkProtocolGovernor proposals; use one with history"
      );
    }
    _proposalIds = new uint256[](_logs.length);
    for (uint256 _i = 0; _i < _logs.length; _i += 1) {
      // `proposalId` is the first, non-indexed field of `ProposalCreated`.
      _proposalIds[_i] = abi.decode(_logs[_i].data, (uint256));
    }
  }

  // Builds the migration proposal: grant the three roles to the Veto Governor, then revoke them from
  // `ZkProtocolGovernor`.
  function _migrationProposal(address _vetoGovernor) internal view returns (Proposal memory _proposal) {
    address _timelock = address(_protocolTimelock());
    bytes32[3] memory _roles = _migratedRoles();
    _proposal.targets = new address[](6);
    _proposal.values = new uint256[](6);
    _proposal.calldatas = new bytes[](6);
    for (uint256 _i = 0; _i < 3; _i += 1) {
      _proposal.targets[_i] = _timelock;
      _proposal.calldatas[_i] = abi.encodeCall(IAccessControl.grantRole, (_roles[_i], _vetoGovernor));
      _proposal.targets[_i + 3] = _timelock;
      _proposal.calldatas[_i + 3] = abi.encodeCall(IAccessControl.revokeRole, (_roles[_i], _protocolGovernor()));
    }
    _proposal.description = _migrationDescription(_vetoGovernor);
  }

  // The description of the migration proposal. It is part of the proposal ID, so it depends only on the addresses
  // involved.
  function _migrationDescription(address _vetoGovernor) internal view returns (string memory) {
    return string.concat(
      "# Move Protocol Timelock roles to the ZKsync Protocol Upgrade Veto Governor\n\n",
      "Grants PROPOSER_ROLE, EXECUTOR_ROLE and CANCELLER_ROLE on the Protocol Timelock (",
      vm.toString(address(_protocolTimelock())),
      ") to ZkProtocolUpgradeVetoGovernor (",
      vm.toString(_vetoGovernor),
      "), then revokes the same roles from ZkProtocolGovernor (",
      vm.toString(_protocolGovernor()),
      "). After this proposal executes, protocol upgrades are proposed through the ZKsync Protocol Upgrade Council ",
      "and the Veto Governor instead of ZkProtocolGovernor. The timelock's minimum delay and administration are unchanged."
    );
  }

  // The ID `ZkProtocolGovernor` assigns to a proposal.
  function _hashProposal(Proposal memory _proposal) internal view returns (uint256) {
    return IGovernor(_protocolGovernor())
      .hashProposal(_proposal.targets, _proposal.values, _proposal.calldatas, keccak256(bytes(_proposal.description)));
  }

  // The ID of the batch operation `ZkProtocolGovernor` schedules on the Protocol Timelock when it queues a proposal.
  // OpenZeppelin v4's `GovernorTimelockControl` uses no predecessor and the description hash as the salt.
  function _timelockOperationId(Proposal memory _proposal) internal view returns (bytes32) {
    return _protocolTimelock()
      .hashOperationBatch(
        _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), keccak256(bytes(_proposal.description))
      );
  }

  // Checks the state the migration starts from: the council governance is fully deployed and configured,
  // `ZkProtocolGovernor` uses the Protocol Timelock and holds the three roles, the Veto Governor holds none, and the
  // timelock administers itself with no delay.
  function _checkBeforeMigration(address _vetoGovernor) internal view {
    _validateExistingDeployment();

    TimelockController _timelock = _protocolTimelock();
    if (IZkProtocolGovernor(_protocolGovernor()).timelock() != address(_timelock)) {
      revert("ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor does not use the Protocol Timelock");
    }
    bytes32[3] memory _roles = _migratedRoles();
    for (uint256 _i = 0; _i < 3; _i += 1) {
      if (!_timelock.hasRole(_roles[_i], _protocolGovernor())) {
        revert(
          "ProposeProtocolTimelockRoleMigration: ZkProtocolGovernor is missing a Protocol Timelock role it should hold"
        );
      }
      if (_timelock.hasRole(_roles[_i], _vetoGovernor)) {
        revert("ProposeProtocolTimelockRoleMigration: the Veto Governor already holds a Protocol Timelock role");
      }
    }
    _checkProtocolTimelockSettings();
  }

  // Checks that the migration proposal exists on `ZkProtocolGovernor` with the ID built here, and has passed: it is
  // succeeded and not yet queued, or queued. Any difference in its actions or description would give it another ID.
  function _checkMigrationProposalPassed(uint256 _migrationProposalId) internal view {
    IGovernor.ProposalState _state = IGovernor(_protocolGovernor()).state(_migrationProposalId);
    if (_state != IGovernor.ProposalState.Succeeded && _state != IGovernor.ProposalState.Queued) {
      revert("ProposeProtocolTimelockRoleMigration: the migration proposal has not passed on ZkProtocolGovernor");
    }
  }

  // Checks the state the migration ends in: the Veto Governor holds the three roles, `ZkProtocolGovernor` holds none,
  // neither administers the timelock, and the timelock still administers itself with no delay.
  function _checkAfterMigration(address _vetoGovernor) internal view {
    TimelockController _timelock = _protocolTimelock();
    bytes32[3] memory _roles = _migratedRoles();
    for (uint256 _i = 0; _i < 3; _i += 1) {
      if (!_timelock.hasRole(_roles[_i], _vetoGovernor)) {
        revert(
          "ProposeProtocolTimelockRoleMigration: after the migration, the Veto Governor lacks a Protocol Timelock role"
        );
      }
      if (_timelock.hasRole(_roles[_i], _protocolGovernor())) {
        revert(
          "ProposeProtocolTimelockRoleMigration: after the migration, ZkProtocolGovernor still holds a timelock role"
        );
      }
    }
    if (
      _timelock.hasRole(TIMELOCK_ADMIN_ROLE, _protocolGovernor())
        || _timelock.hasRole(TIMELOCK_ADMIN_ROLE, _vetoGovernor)
    ) {
      revert("ProposeProtocolTimelockRoleMigration: a governor administers the Protocol Timelock");
    }
    _checkProtocolTimelockSettings();
  }

  // Checks the Protocol Timelock settings the migration leaves unchanged: no minimum delay, self-administration, and
  // none of the three roles open to every account.
  function _checkProtocolTimelockSettings() internal view {
    TimelockController _timelock = _protocolTimelock();
    if (_timelock.getMinDelay() != 0) {
      revert("ProposeProtocolTimelockRoleMigration: the Protocol Timelock's minimum delay is not 0");
    }
    if (!_timelock.hasRole(TIMELOCK_ADMIN_ROLE, address(_timelock))) {
      revert("ProposeProtocolTimelockRoleMigration: the Protocol Timelock does not administer itself");
    }
    bytes32[3] memory _roles = _migratedRoles();
    for (uint256 _i = 0; _i < 3; _i += 1) {
      if (_timelock.hasRole(_roles[_i], address(0))) {
        revert("ProposeProtocolTimelockRoleMigration: a Protocol Timelock role is open to every account");
      }
    }
  }

  // Checks that the migration proposal does not exist on `ZkProtocolGovernor` yet, since proposing it again reverts.
  function _checkNotAlreadyProposed(uint256[] memory _proposalIds, uint256 _migrationProposalId) internal view {
    string[8] memory _stateNames =
      ["Pending", "Active", "Canceled", "Defeated", "Succeeded", "Queued", "Expired", "Executed"];
    for (uint256 _i = 0; _i < _proposalIds.length; _i += 1) {
      if (_proposalIds[_i] == _migrationProposalId) {
        IGovernor.ProposalState _state = IGovernor(_protocolGovernor()).state(_migrationProposalId);
        revert(
          string.concat(
            "ProposeProtocolTimelockRoleMigration: the migration proposal already exists on ZkProtocolGovernor (",
            _stateNames[uint8(_state)],
            ")"
          )
        );
      }
    }
  }

  // Checks that `_proposer` has the votes `ZkProtocolGovernor` requires to propose, counted at the previous block as
  // the governor counts them.
  function _checkProposerMeetsThreshold(address _proposer) internal view {
    IGovernor _governor = IGovernor(_protocolGovernor());
    if (_governor.getVotes(_proposer, block.number - 1) < _governor.proposalThreshold()) {
      revert("ProposeProtocolTimelockRoleMigration: the proposer's votes are below ZkProtocolGovernor's threshold");
    }
  }

  // Executes the migration proposal on the current chain state the way `ZkProtocolGovernor` does once it passes: as a
  // timelock batch, scheduled when the proposal is queued and then executed by the governor. If the proposal is already
  // queued, its batch is already scheduled, and only the execution is simulated. For simulation only: it pranks
  // `ZkProtocolGovernor`, so it must not run while broadcasting.
  function _simulateMigration(Proposal memory _proposal) internal {
    TimelockController _timelock = _protocolTimelock();
    bytes32 _salt = keccak256(bytes(_proposal.description));
    if (!_timelock.isOperation(_timelockOperationId(_proposal))) {
      vm.prank(_protocolGovernor());
      _timelock.scheduleBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt, 0);
    }
    vm.prank(_protocolGovernor());
    _timelock.executeBatch(_proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _salt);
  }

  // Lists the `ZkProtocolGovernor` proposals among `_proposalIds`, other than the migration proposal, that still need
  // the roles the migration revokes: those that are pending, active, succeeded or queued.
  function _inFlightProposals(uint256[] memory _proposalIds, uint256 _migrationProposalId)
    internal
    view
    returns (uint256[] memory _inFlightIds)
  {
    _inFlightIds = new uint256[](_proposalIds.length);
    uint256 _count = 0;
    for (uint256 _i = 0; _i < _proposalIds.length; _i += 1) {
      if (_proposalIds[_i] != _migrationProposalId && _isInFlight(_proposalIds[_i])) {
        _inFlightIds[_count] = _proposalIds[_i];
        _count += 1;
      }
    }
    assembly {
      mstore(_inFlightIds, _count)
    }
  }

  // Returns whether a `ZkProtocolGovernor` proposal can still queue, execute or cancel on the timelock. A proposal that
  // succeeded but was never queued counts, since it could still be queued.
  function _isInFlight(uint256 _proposalId) internal view returns (bool) {
    IGovernor.ProposalState _state = IGovernor(_protocolGovernor()).state(_proposalId);
    return _state == IGovernor.ProposalState.Pending || _state == IGovernor.ProposalState.Active
      || _state == IGovernor.ProposalState.Succeeded || _state == IGovernor.ProposalState.Queued;
  }

  // The roles the migration moves, in the order they are granted and revoked.
  function _migratedRoles() internal pure returns (bytes32[3] memory) {
    return [PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE];
  }

  function _logInFlight(uint256[] memory _inFlight) internal view {
    if (_inFlight.length == 0) {
      _log("No other ZkProtocolGovernor proposals in flight");
      return;
    }
    _log(
      string.concat(
        "WARNING: other ZkProtocolGovernor proposals in flight; they must finish before the migration executes: ",
        _joinProposalIds(_inFlight)
      )
    );
  }

  function _joinProposalIds(uint256[] memory _proposalIds) internal pure returns (string memory _joined) {
    for (uint256 _i = 0; _i < _proposalIds.length; _i += 1) {
      if (_i > 0) {
        _joined = string.concat(_joined, ", ");
      }
      _joined = string.concat(_joined, vm.toString(bytes32(_proposalIds[_i])));
    }
  }
}

// The Protocol Timelock role migration on ZKsync Era mainnet.
//
// Usage, from `l2-contracts/council`, with the deployed council governance's addresses and deployer in
// `COUNCIL_TOKEN`, `COUNCIL_GOVERNOR`, `VETO_GOVERNOR`, `SUPERMAJORITY_GOVERNOR`, `OVERRIDE_TIMELOCK` and `DEPLOYER`:
// `forge script script/ProposeProtocolTimelockRoleMigration.s.sol:ProposeProtocolTimelockRoleMigrationEraMainnet
// --zksync --rpc-url <era-rpc> --broadcast --account <delegate-keystore-account> --sender <delegate-address>`, where the
// delegate's votes meet `ZkProtocolGovernor`'s proposal threshold. Run it with `--sig "checkReadyToExecute()"` and
// without `--broadcast` right before execution. The RPC endpoint must serve historical logs, which local forks usually
// do not.
contract ProposeProtocolTimelockRoleMigrationEraMainnet is
  ProposeProtocolTimelockRoleMigration,
  ZkProtocolUpgradeEraMainnetConfig
{
  // The governor that holds the Protocol Timelock roles on Era mainnet before the migration.
  address internal constant PROTOCOL_GOVERNOR = 0x76705327e682F2d96943280D99464Ab61219e34f;

  // The block of `ZkProtocolGovernor`'s first proposal on Era mainnet.
  uint256 internal constant PROTOCOL_GOVERNOR_FIRST_PROPOSAL_BLOCK = 49_077_771;

  // Script entrypoint
  function run() public override {
    ProposeProtocolTimelockRoleMigration.run();
  }

  function _protocolGovernor() internal view virtual override returns (address) {
    return PROTOCOL_GOVERNOR;
  }

  function _protocolGovernorFirstProposalBlock() internal view virtual override returns (uint256) {
    return PROTOCOL_GOVERNOR_FIRST_PROPOSAL_BLOCK;
  }
}

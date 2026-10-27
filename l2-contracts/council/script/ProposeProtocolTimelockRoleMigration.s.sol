// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ProtocolTimelockRoleMigration} from "script/ProtocolTimelockRoleMigration.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/ZkProtocolUpgradeEraMainnetConfig.sol";

// Proposes, from the broadcasting delegate, the `ZkProtocolGovernor` proposal that moves the proposer, executor and
// canceller roles on the Protocol Timelock to `ZkProtocolUpgradeVetoGovernor`. The proposal ID depends on the exact
// description, so proposing from the script keeps the description on chain, and with it the ID `checkReadyToExecute`
// looks for, exactly as built here.
//
// `run` checks that the deployment is fully configured, that the roles have not moved yet, that the migration has not
// been proposed already, and that the delegate's votes meet the proposal threshold. It then proposes the migration,
// simulates its execution against the live chain state, and checks the result. It lists, but does not fail on, other
// `ZkProtocolGovernor` proposals still in flight, since those may finish before the migration executes.
//
// `checkReadyToExecute` repeats the checks just before the migration proposal executes, whether or not it is queued
// yet. It also fails unless the migration proposal has passed on `ZkProtocolGovernor`, and if any other
// `ZkProtocolGovernor` proposal is still in flight, since executing the migration would strand it.
abstract contract ProposeProtocolTimelockRoleMigration is ProtocolTimelockRoleMigration {
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

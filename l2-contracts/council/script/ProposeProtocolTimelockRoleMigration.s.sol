// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ProtocolTimelockRoleMigration} from "script/ProtocolTimelockRoleMigration.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/ZkProtocolUpgradeEraMainnetConfig.sol";

// Generates the `ZkProtocolGovernor` proposal that moves the proposer, executor and canceller roles on the Protocol
// Timelock to `ZkProtocolUpgradeVetoGovernor`, and an execution manifest describing it. Nothing is broadcast: the
// proposal is submitted separately with the `propose` calldata this script prints. Submit that calldata unchanged:
// the proposal ID depends on the exact description, so a proposal whose description a UI reformats gets a different ID
// and fails `checkReadyToExecute`.
//
// `run` checks that the deployment is fully configured and that the roles have not moved yet, simulates the proposal's
// execution against the live chain state, checks the result, and writes the manifest. It lists, but does not fail on,
// other `ZkProtocolGovernor` proposals still in flight, since those may finish before the migration executes.
//
// `checkReadyToExecute` repeats the checks just before the migration proposal executes, whether or not it is queued
// yet. It also fails unless the migration proposal has passed on `ZkProtocolGovernor`, and if any other
// `ZkProtocolGovernor` proposal is still in flight, since executing the migration would strand it.
abstract contract ProposeProtocolTimelockRoleMigration is ProtocolTimelockRoleMigration {
  // The directory the manifest is written to, which `fs_permissions` in `foundry.toml` lets the script write.
  string internal constant MANIFEST_DIR = "proposals";

  // The manifest's file name in `MANIFEST_DIR` unless `MANIFEST_FILE` is set.
  string internal constant DEFAULT_MANIFEST_FILE = "protocol-timelock-role-migration.json";

  // Generates, simulates and checks the migration proposal, and writes its execution manifest.
  function run() public virtual {
    address _vetoGovernor = _deployedVetoGovernor();
    _checkBeforeMigration(_vetoGovernor);

    Proposal memory _proposal = _migrationProposal(_vetoGovernor);
    uint256 _proposalId = _hashProposal(_proposal);
    uint256[] memory _proposalIds = _protocolGovernorProposalIds();
    uint256[] memory _inFlight = _inFlightProposals(_proposalIds, _proposalId);
    _logIfAlreadyProposed(_proposalIds, _proposalId);

    _simulateMigration(_proposal);
    _checkAfterMigration(_vetoGovernor);

    string memory _writtenManifestPath = _writeManifest(_proposal, _proposalId, _vetoGovernor, _inFlight);

    _log(string.concat("Proposal ID: ", vm.toString(bytes32(_proposalId))));
    _log(string.concat("Governor: ", vm.toString(_protocolGovernor())));
    _log(string.concat("propose calldata: ", vm.toString(_proposeCalldata(_proposal))));
    _log(string.concat("Manifest written to ", _writtenManifestPath));
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

  // The manifest's file name in `MANIFEST_DIR`, `MANIFEST_FILE` if set.
  function _manifestFileName() internal view virtual returns (string memory) {
    return vm.envOr("MANIFEST_FILE", DEFAULT_MANIFEST_FILE);
  }

  // Notes when the migration proposal already exists on `ZkProtocolGovernor`, in which case proposing it again reverts.
  function _logIfAlreadyProposed(uint256[] memory _proposalIds, uint256 _migrationProposalId) internal view {
    string[8] memory _stateNames =
      ["Pending", "Active", "Canceled", "Defeated", "Succeeded", "Queued", "Expired", "Executed"];
    for (uint256 _i = 0; _i < _proposalIds.length; _i += 1) {
      if (_proposalIds[_i] == _migrationProposalId) {
        IGovernor.ProposalState _state = IGovernor(_protocolGovernor()).state(_migrationProposalId);
        _log(
          string.concat(
            "NOTE: the migration proposal already exists on ZkProtocolGovernor (",
            _stateNames[uint8(_state)],
            "); proposing it again reverts"
          )
        );
        return;
      }
    }
  }

  function _proposeCalldata(Proposal memory _proposal) internal pure returns (bytes memory) {
    return abi.encodeCall(
      IGovernor.propose, (_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description)
    );
  }

  // Writes the execution manifest: the proposal and its IDs, the calldata to propose, queue and execute it, a readable
  // list of its calls, the expected end state, and the proposals in flight when it was generated.
  function _writeManifest(
    Proposal memory _proposal,
    uint256 _proposalId,
    address _vetoGovernor,
    uint256[] memory _inFlight
  ) internal returns (string memory _path) {
    bytes32 _descriptionHash = keccak256(bytes(_proposal.description));
    // `vm.serialize*` builds the JSON object under this key, and the last call returns it.
    string memory _manifestKey = "manifest";

    vm.serializeUint(_manifestKey, "chainId", block.chainid);
    vm.serializeUint(_manifestKey, "generatedAtBlock", block.number);
    vm.serializeAddress(_manifestKey, "governor", _protocolGovernor());
    vm.serializeAddress(_manifestKey, "timelock", address(_protocolTimelock()));
    vm.serializeAddress(_manifestKey, "vetoGovernor", _vetoGovernor);
    vm.serializeBytes32(_manifestKey, "proposalId", bytes32(_proposalId));
    vm.serializeString(_manifestKey, "description", _proposal.description);
    vm.serializeBytes32(_manifestKey, "descriptionHash", _descriptionHash);
    vm.serializeBytes32(_manifestKey, "timelockOperationId", _timelockOperationId(_proposal));
    vm.serializeAddress(_manifestKey, "targets", _proposal.targets);
    vm.serializeUint(_manifestKey, "values", _proposal.values);
    vm.serializeBytes(_manifestKey, "calldatas", _proposal.calldatas);
    vm.serializeString(_manifestKey, "calls", _describeCalls(_vetoGovernor));
    vm.serializeBytes(_manifestKey, "proposeCalldata", _proposeCalldata(_proposal));
    vm.serializeBytes(
      _manifestKey,
      "queueCalldata",
      abi.encodeCall(IGovernor.queue, (_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash))
    );
    vm.serializeBytes(
      _manifestKey,
      "executeCalldata",
      abi.encodeCall(IGovernor.execute, (_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash))
    );
    vm.serializeString(_manifestKey, "expectedEndState", _describeEndState(_vetoGovernor));
    bytes32[] memory _inFlightIds = new bytes32[](_inFlight.length);
    for (uint256 _i = 0; _i < _inFlight.length; _i += 1) {
      _inFlightIds[_i] = bytes32(_inFlight[_i]);
    }
    string memory _manifest = vm.serializeBytes32(_manifestKey, "inFlightProposalsAtGeneration", _inFlightIds);

    _path = string.concat(MANIFEST_DIR, "/", _manifestFileName());
    vm.createDir(MANIFEST_DIR, true);
    vm.writeJson(_manifest, _path);
  }

  // A readable line for each call in the migration proposal, in execution order.
  function _describeCalls(address _vetoGovernor) internal view returns (string[] memory _calls) {
    string[3] memory _roleNames = ["PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"];
    _calls = new string[](6);
    for (uint256 _i = 0; _i < 3; _i += 1) {
      _calls[_i] = string.concat(
        "ProtocolTimelock.grantRole(",
        _roleNames[_i],
        ", ZkProtocolUpgradeVetoGovernor ",
        vm.toString(_vetoGovernor),
        ")"
      );
      _calls[_i + 3] = string.concat(
        "ProtocolTimelock.revokeRole(", _roleNames[_i], ", ZkProtocolGovernor ", vm.toString(_protocolGovernor()), ")"
      );
    }
  }

  // A readable line for each property of the state the migration ends in, as `_checkAfterMigration` checks it.
  function _describeEndState(address _vetoGovernor) internal view returns (string[] memory _state) {
    _state = new string[](4);
    _state[0] = string.concat(
      "ZkProtocolUpgradeVetoGovernor ",
      vm.toString(_vetoGovernor),
      " holds PROPOSER_ROLE, EXECUTOR_ROLE and CANCELLER_ROLE on the Protocol Timelock"
    );
    _state[1] = string.concat(
      "ZkProtocolGovernor ",
      vm.toString(_protocolGovernor()),
      " holds none of PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE or TIMELOCK_ADMIN_ROLE on the Protocol Timelock"
    );
    _state[2] = "The Protocol Timelock holds TIMELOCK_ADMIN_ROLE on itself";
    _state[3] = "The Protocol Timelock's minimum delay is 0";
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
// --zksync --rpc-url <era-rpc>`. Add `--sig "checkReadyToExecute()"` right before execution. `MANIFEST_FILE` optionally
// names the manifest file written in `proposals/`. The RPC endpoint must serve historical logs, which
// local forks usually do not.
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

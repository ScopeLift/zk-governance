// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ProtocolTimelockRoleMigration} from "script/ProtocolTimelockRoleMigration.sol";

/// @title ProposeProtocolTimelockRoleMigration
/// @author [ScopeLift](https://scopelift.co)
/// @notice Generates the `ZkProtocolGovernor` proposal that moves the proposer, executor and canceller roles on the
/// Protocol Timelock to `ZkProtocolUpgradeVetoGovernor`, and an execution manifest describing it. Nothing is broadcast:
/// the proposal is submitted separately, e.g. through Tally, with the calldata this script prints.
/// @dev Reads the deployed council governance addresses and their deployer from the environment: `COUNCIL_TOKEN`,
/// `COUNCIL_GOVERNOR`, `VETO_GOVERNOR`, `SUPERMAJORITY_GOVERNOR`, `OVERRIDE_TIMELOCK` and `DEPLOYER`. `MANIFEST_PATH`
/// optionally overrides where the manifest is written, within `proposals/`. The RPC endpoint must serve historical
/// logs, which local forks usually do not.
///
/// `run` checks that the deployment is fully configured and that the roles have not moved yet, simulates the
/// proposal's execution against the live chain state, checks the result, and writes the manifest. It lists, but does
/// not fail on, other `ZkProtocolGovernor` proposals still in flight, since those may finish before the migration
/// executes.
///
/// `checkReadyToExecute` repeats the checks just before the migration proposal is executed and also fails if any other
/// `ZkProtocolGovernor` proposal is still in flight, since executing the migration would strand it.
///
/// Usage, against ZKsync Era:
/// - `forge script script/ProposeProtocolTimelockRoleMigration.s.sol --zksync --rpc-url <era-rpc>`
/// - `forge script script/ProposeProtocolTimelockRoleMigration.s.sol --zksync --rpc-url <era-rpc> \
///   --sig "checkReadyToExecute()"`
contract ProposeProtocolTimelockRoleMigration is Script, ProtocolTimelockRoleMigration {
  /// @notice The directory the script may write to, as allowed by `fs_permissions` in `foundry.toml`.
  string internal constant MANIFEST_DIR = "proposals";

  /// @notice Where the manifest is written unless `MANIFEST_PATH` is set.
  string internal constant DEFAULT_MANIFEST_PATH = "proposals/protocol-timelock-role-migration.json";

  /// @notice Generates, simulates and checks the migration proposal, and writes its execution manifest.
  /// @return _proposal The migration proposal.
  function run() public returns (Proposal memory _proposal) {
    address _vetoGovernor = vm.envAddress("VETO_GOVERNOR");
    _checkBeforeMigration(_vetoGovernor);

    _proposal = _migrationProposal(_vetoGovernor);
    uint256 _proposalId = _hashProposal(_proposal);
    uint256[] memory _inFlight = _inFlightProposals(_proposalId);

    _simulateMigration(_proposal);
    _checkAfterMigration(_vetoGovernor);

    string memory _manifest = _writeManifest(_proposal, _proposalId, _vetoGovernor, _inFlight);

    console2.log("Proposal ID:", vm.toString(bytes32(_proposalId)));
    console2.log("Governor:", PROTOCOL_GOVERNOR);
    console2.log("propose calldata:");
    console2.logBytes(
      abi.encodeCall(
        IGovernor.propose, (_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description)
      )
    );
    console2.log("Manifest written to", _manifest);
    _logInFlight(_inFlight);
    console2.log("Simulated execution: all migration checks passed");
  }

  /// @notice Checks that the migration proposal can execute without stranding another `ZkProtocolGovernor` proposal,
  /// and that executing it now ends in the expected state.
  function checkReadyToExecute() public {
    address _vetoGovernor = vm.envAddress("VETO_GOVERNOR");
    _checkBeforeMigration(_vetoGovernor);

    Proposal memory _proposal = _migrationProposal(_vetoGovernor);
    uint256[] memory _inFlight = _inFlightProposals(_hashProposal(_proposal));
    _logInFlight(_inFlight);
    require(_inFlight.length == 0, "migration: other ZkProtocolGovernor proposals in flight");

    _simulateMigration(_proposal);
    _checkAfterMigration(_vetoGovernor);
    console2.log("Ready to execute: all migration checks passed");
  }

  /// @notice Writes the execution manifest: the proposal and its IDs, the calldata to propose, queue and execute it,
  /// a readable list of its calls, the expected end state, and the proposals in flight when it was generated.
  /// @return _path The path the manifest was written to.
  function _writeManifest(
    Proposal memory _proposal,
    uint256 _proposalId,
    address _vetoGovernor,
    uint256[] memory _inFlight
  ) internal returns (string memory _path) {
    bytes32 _descriptionHash = keccak256(bytes(_proposal.description));
    string memory _json = "manifest";

    vm.serializeUint(_json, "chainId", block.chainid);
    vm.serializeUint(_json, "generatedAtBlock", block.number);
    vm.serializeAddress(_json, "governor", PROTOCOL_GOVERNOR);
    vm.serializeAddress(_json, "timelock", PROTOCOL_TIMELOCK);
    vm.serializeAddress(_json, "vetoGovernor", _vetoGovernor);
    vm.serializeBytes32(_json, "proposalId", bytes32(_proposalId));
    vm.serializeString(_json, "description", _proposal.description);
    vm.serializeBytes32(_json, "descriptionHash", _descriptionHash);
    vm.serializeBytes32(_json, "timelockOperationId", _timelockOperationId(_proposal));
    vm.serializeAddress(_json, "targets", _proposal.targets);
    vm.serializeUint(_json, "values", _proposal.values);
    vm.serializeBytes(_json, "calldatas", _proposal.calldatas);
    vm.serializeString(_json, "calls", _describeCalls(_vetoGovernor));
    vm.serializeBytes(
      _json,
      "proposeCalldata",
      abi.encodeCall(
        IGovernor.propose, (_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description)
      )
    );
    vm.serializeBytes(
      _json,
      "queueCalldata",
      abi.encodeCall(IGovernor.queue, (_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash))
    );
    vm.serializeBytes(
      _json,
      "executeCalldata",
      abi.encodeCall(IGovernor.execute, (_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash))
    );
    vm.serializeString(_json, "expectedEndState", _describeEndState(_vetoGovernor));
    bytes32[] memory _inFlightIds = new bytes32[](_inFlight.length);
    for (uint256 _i = 0; _i < _inFlight.length; _i++) {
      _inFlightIds[_i] = bytes32(_inFlight[_i]);
    }
    _json = vm.serializeBytes32(_json, "inFlightProposalsAtGeneration", _inFlightIds);

    _path = vm.envOr("MANIFEST_PATH", DEFAULT_MANIFEST_PATH);
    vm.createDir(MANIFEST_DIR, true);
    vm.writeJson(_json, _path);
  }

  /// @notice A readable line for each call in the migration proposal, in execution order.
  function _describeCalls(address _vetoGovernor) internal pure returns (string[] memory _calls) {
    string[3] memory _roleNames = ["PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"];
    _calls = new string[](6);
    for (uint256 _i = 0; _i < 3; _i++) {
      _calls[_i] = string.concat(
        "ProtocolTimelock.grantRole(",
        _roleNames[_i],
        ", ZkProtocolUpgradeVetoGovernor ",
        vm.toString(_vetoGovernor),
        ")"
      );
      _calls[_i + 3] = string.concat(
        "ProtocolTimelock.revokeRole(", _roleNames[_i], ", ZkProtocolGovernor ", vm.toString(PROTOCOL_GOVERNOR), ")"
      );
    }
  }

  /// @notice A readable line for each property of the state the migration ends in, as `_checkAfterMigration` checks it.
  function _describeEndState(address _vetoGovernor) internal pure returns (string[] memory _state) {
    _state = new string[](4);
    _state[0] = string.concat(
      "ZkProtocolUpgradeVetoGovernor ",
      vm.toString(_vetoGovernor),
      " holds PROPOSER_ROLE, EXECUTOR_ROLE and CANCELLER_ROLE on the Protocol Timelock"
    );
    _state[1] = string.concat(
      "ZkProtocolGovernor ",
      vm.toString(PROTOCOL_GOVERNOR),
      " holds none of PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE or TIMELOCK_ADMIN_ROLE on the Protocol Timelock"
    );
    _state[2] = "The Protocol Timelock holds TIMELOCK_ADMIN_ROLE on itself";
    _state[3] = "The Protocol Timelock's minimum delay is 0";
  }

  /// @notice Logs the `ZkProtocolGovernor` proposals still in flight.
  function _logInFlight(uint256[] memory _inFlight) internal pure {
    if (_inFlight.length == 0) {
      console2.log("No other ZkProtocolGovernor proposals in flight");
      return;
    }
    console2.log(
      "WARNING: other ZkProtocolGovernor proposals in flight; they must finish before the migration executes:"
    );
    for (uint256 _i = 0; _i < _inFlight.length; _i++) {
      console2.log(" ", vm.toString(bytes32(_inFlight[_i])));
    }
  }
}

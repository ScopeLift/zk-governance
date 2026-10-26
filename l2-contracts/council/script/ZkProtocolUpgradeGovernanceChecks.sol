// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {DeployBase} from "script/DeployBase.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/ZkProtocolUpgradeDeploymentConfig.sol";

// The parts of the Supermajority Governor, the OpenZeppelin v4 `ZkProtocolGovernor`, that the checks read. This project
// cannot import the contract itself.
interface ISupermajorityGovernor {
  function name() external view returns (string memory);
  function token() external view returns (address);
  function timelock() external view returns (address);
  function clock() external view returns (uint48);
  function votingDelay() external view returns (uint256);
  function votingPeriod() external view returns (uint256);
  function proposalThreshold() external view returns (uint256);
  function quorum(uint256 _timepoint) external view returns (uint256);
  function lateQuorumVoteExtension() external view returns (uint64);
}

// Checks a protocol upgrade governance deployment against its params: every contract's settings, the wiring between
// them, the handover of every admin role to the governance admin, and that the deployer kept no privileges. The deploy
// script runs these checks after deploying, and other scripts inherit them to check an existing deployment.
abstract contract ZkProtocolUpgradeGovernanceChecks is DeployBase, ZkProtocolUpgradeDeploymentConfig {
  struct Deployment {
    CouncilERC20 councilToken;
    ZkProtocolUpgradeCouncilGovernor councilGovernor;
    ZkProtocolUpgradeVetoGovernor vetoGovernor;
    // From step 1. The override timelock is an OpenZeppelin v4 `TimelockController`, read through the v5 type, whose
    // ABI matches for the functions used here; its admin role is `TIMELOCK_ADMIN_ROLE`.
    address supermajorityGovernor;
    TimelockController overrideTimelock;
  }

  // Reads an existing deployment's addresses from `COUNCIL_TOKEN`, `COUNCIL_GOVERNOR`, `VETO_GOVERNOR`,
  // `SUPERMAJORITY_GOVERNOR` and `OVERRIDE_TIMELOCK`.
  function _deploymentFromEnv() internal view returns (Deployment memory) {
    return Deployment({
      councilToken: CouncilERC20(vm.envAddress("COUNCIL_TOKEN")),
      councilGovernor: ZkProtocolUpgradeCouncilGovernor(payable(vm.envAddress("COUNCIL_GOVERNOR"))),
      vetoGovernor: ZkProtocolUpgradeVetoGovernor(payable(vm.envAddress("VETO_GOVERNOR"))),
      supermajorityGovernor: vm.envAddress("SUPERMAJORITY_GOVERNOR"),
      overrideTimelock: TimelockController(payable(vm.envAddress("OVERRIDE_TIMELOCK")))
    });
  }

  // Runs every check against a deployment made by `_deployer`.
  function _validateDeployment(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    _validateCouncilToken(_params, _deployment, _deployer);
    _validateCouncilGovernor(_params, _deployment);
    _validateVetoGovernor(_params, _deployment);
    _validateStepOneContracts(_params, _deployment, _deployer);
  }

  // Checks the contracts step 1 deployed: the Supermajority Governor's settings, and that the override timelock belongs
  // to it, administers itself, and gives `_deployer` no role.
  function _validateStepOneContracts(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    if (_deployment.supermajorityGovernor.code.length == 0 || address(_deployment.overrideTimelock).code.length == 0) {
      revert("ZkProtocolUpgradeGovernanceChecks: the Supermajority Governor or override timelock is not deployed");
    }
    _validateSupermajorityGovernor(_params, _deployment);
    _validateOverrideTimelock(_params, _deployment, _deployer);
  }

  function _validateSupermajorityGovernor(DeploymentParams memory _params, Deployment memory _deployment)
    internal
    view
  {
    ISupermajorityGovernor _governor = ISupermajorityGovernor(_deployment.supermajorityGovernor);

    if (!_eq(_governor.name(), _params.supermajorityGovernorName)) {
      revert("ZkProtocolUpgradeGovernanceChecks: Supermajority Governor name does not match the params");
    }
    if (_governor.token() != _params.zkToken) {
      revert("ZkProtocolUpgradeGovernanceChecks: Supermajority Governor token is not the ZK token");
    }
    if (_governor.timelock() != address(_deployment.overrideTimelock)) {
      revert("ZkProtocolUpgradeGovernanceChecks: the Supermajority Governor's timelock is not the override timelock");
    }
    if (_governor.votingDelay() != _params.supermajorityGovernorVotingDelay) {
      revert("ZkProtocolUpgradeGovernanceChecks: Supermajority Governor voting delay does not match the params");
    }
    if (_governor.votingPeriod() != _params.supermajorityGovernorVotingPeriod) {
      revert("ZkProtocolUpgradeGovernanceChecks: Supermajority Governor voting period does not match the params");
    }
    if (_governor.proposalThreshold() != _params.supermajorityGovernorProposalThreshold) {
      revert("ZkProtocolUpgradeGovernanceChecks: Supermajority Governor proposal threshold does not match the params");
    }
    if (_governor.quorum(_governor.clock()) != _params.supermajorityGovernorQuorum) {
      revert("ZkProtocolUpgradeGovernanceChecks: Supermajority Governor quorum does not match the params");
    }
    if (_governor.lateQuorumVoteExtension() != _params.supermajorityGovernorLateQuorumVoteExtension) {
      revert(
        "ZkProtocolUpgradeGovernanceChecks: Supermajority Governor late-quorum extension does not match the params"
      );
    }
  }

  function _validateCouncilToken(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    CouncilERC20 _token = _deployment.councilToken;
    address[] memory _members = _params.councilMembers;

    if (!_eq(_token.name(), _params.councilTokenName)) {
      revert("ZkProtocolUpgradeGovernanceChecks: council token name does not match the params");
    }
    if (!_eq(_token.symbol(), _params.councilTokenSymbol)) {
      revert("ZkProtocolUpgradeGovernanceChecks: council token symbol does not match the params");
    }
    if (_token.owner() != _params.governanceAdmin) {
      revert("ZkProtocolUpgradeGovernanceChecks: council token owner is not the governance admin");
    }
    if (_token.MAX_TOKENS_PER_MEMBER() != _params.votesPerCouncilSeat) {
      revert("ZkProtocolUpgradeGovernanceChecks: council token max tokens per member is not one seat");
    }
    if (_token.totalSupply() != _params.votesPerCouncilSeat * _members.length) {
      revert("ZkProtocolUpgradeGovernanceChecks: council token supply is not one seat per member");
    }
    for (uint256 _i = 0; _i < _members.length; _i += 1) {
      if (
        _token.balanceOf(_members[_i]) != _params.votesPerCouncilSeat
          || _token.getVotes(_members[_i]) != _params.votesPerCouncilSeat
      ) {
        revert(
          string.concat(
            "ZkProtocolUpgradeGovernanceChecks: council member ",
            vm.toString(_members[_i]),
            " does not hold and vote one seat"
          )
        );
      }
    }
    if (_token.balanceOf(_deployer) != 0) {
      revert("ZkProtocolUpgradeGovernanceChecks: the deployer holds a council seat");
    }
  }

  function _validateCouncilGovernor(DeploymentParams memory _params, Deployment memory _deployment) internal view {
    ZkProtocolUpgradeCouncilGovernor _governor = _deployment.councilGovernor;

    if (!_eq(_governor.name(), _params.councilGovernorName)) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor name does not match the params");
    }
    if (address(_governor.token()) != address(_deployment.councilToken)) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor token is not the council token");
    }
    if (_governor.QUORUM() != _params.votesPerCouncilSeat) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor seat size does not match the params");
    }
    if (address(_governor.councilVetoGovernor()) != address(_deployment.vetoGovernor)) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor does not submit proposals to the Veto Governor");
    }
    if (_governor.owner() != _params.governanceAdmin) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor admin is not the governance admin");
    }
    if (_governor.votingDelay() != _params.councilGovernorVotingDelay) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor voting delay does not match the params");
    }
    if (_governor.votingPeriod() != _params.councilGovernorVotingPeriod) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor voting period does not match the params");
    }
    if (_governor.proposalThreshold() != _params.councilGovernorProposalThreshold) {
      revert("ZkProtocolUpgradeGovernanceChecks: council governor proposal threshold does not match the params");
    }
  }

  function _validateVetoGovernor(DeploymentParams memory _params, Deployment memory _deployment) internal view {
    ZkProtocolUpgradeVetoGovernor _governor = _deployment.vetoGovernor;

    if (!_eq(_governor.name(), _params.vetoGovernorName)) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor name does not match the params");
    }
    if (address(_governor.token()) != _params.zkToken) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor token is not the ZK token");
    }
    if (_governor.COUNCIL() != address(_deployment.councilGovernor)) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor council is not the Council Governor");
    }
    if (_governor.timelock() != _params.protocolTimelock) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor timelock is not the Protocol Timelock");
    }
    if (_governor.owner() != _params.governanceAdmin) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor admin is not the governance admin");
    }
    if (_governor.votingDelay() != _params.vetoGovernorVotingDelay) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor voting delay does not match the params");
    }
    if (_governor.votingPeriod() != _params.vetoGovernorVotingPeriod) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor voting period does not match the params");
    }
    if (_governor.proposalThreshold() != _params.vetoGovernorProposalThreshold) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor proposal threshold does not match the params");
    }
    if (_governor.vetoThreshold(_governor.clock()) != _params.vetoGovernorVetoThreshold) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor veto threshold does not match the params");
    }
    if (_governor.votingPeriodExtension() != _params.vetoGovernorVotingPeriodExtension) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor voting period extension does not match the params");
    }
    if (_governor.minorVetoExtensionThresholdPct() != _params.vetoGovernorVotingPeriodExtensionThresholdPct) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor extension threshold does not match the params");
    }
    if (_governor.vetoGuardian() != _params.vetoGovernorVetoGuardian) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor veto guardian does not match the params");
    }
    if (_governor.vetoOverrideRole() != address(_deployment.overrideTimelock)) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor veto override role is not the override timelock");
    }
    if (_governor.vetoOverrideDuration() != _params.vetoGovernorVetoOverrideDuration) {
      revert("ZkProtocolUpgradeGovernanceChecks: veto governor override duration does not match the params");
    }
  }

  // Checks that the override timelock from step 1 is the Supermajority Governor's proposer and canceller, administers
  // itself, and gives the deployer no role.
  function _validateOverrideTimelock(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    TimelockController _timelock = _deployment.overrideTimelock;
    address _governor = _deployment.supermajorityGovernor;

    if (_timelock.getMinDelay() != _params.overrideTimelockMinDelay) {
      revert("ZkProtocolUpgradeGovernanceChecks: override timelock delay does not match the params");
    }
    if (!_timelock.hasRole(_timelock.PROPOSER_ROLE(), _governor)) {
      revert("ZkProtocolUpgradeGovernanceChecks: the Supermajority Governor is not the override timelock's proposer");
    }
    if (!_timelock.hasRole(_timelock.CANCELLER_ROLE(), _governor)) {
      revert("ZkProtocolUpgradeGovernanceChecks: the Supermajority Governor is not the override timelock's canceller");
    }
    if (!_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0))) {
      revert("ZkProtocolUpgradeGovernanceChecks: override timelock execution is not open to everyone");
    }
    if (!_timelock.hasRole(TIMELOCK_ADMIN_ROLE, address(_timelock))) {
      revert("ZkProtocolUpgradeGovernanceChecks: the override timelock does not administer itself");
    }
    if (
      _timelock.hasRole(TIMELOCK_ADMIN_ROLE, _deployer) || _timelock.hasRole(_timelock.PROPOSER_ROLE(), _deployer)
        || _timelock.hasRole(_timelock.CANCELLER_ROLE(), _deployer)
        || _timelock.hasRole(_timelock.EXECUTOR_ROLE(), _deployer)
    ) {
      revert("ZkProtocolUpgradeGovernanceChecks: the deployer holds a role on the override timelock");
    }
  }
}

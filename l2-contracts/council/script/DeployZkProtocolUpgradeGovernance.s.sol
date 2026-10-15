// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BasicCouncilGovernor} from "council-governance/BasicCouncilGovernor.sol";
import {BasicCouncilVetoGovernor} from "council-governance/BasicCouncilVetoGovernor.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {ZkSupermajorityGovernor} from "src/ZkSupermajorityGovernor.sol";
import {ZkProtocolUpgradeDeploymentChecks} from "script/ZkProtocolUpgradeDeploymentChecks.sol";

/// @title DeployZkProtocolUpgradeGovernance
/// @author [ScopeLift](https://scopelift.co)
/// @notice Deploys the ZKsync protocol upgrade council governance contracts on ZKsync Era with the ZIP parameters in
/// `ZkProtocolUpgradeDeploymentConfig`, hands every admin role to the aliased L1 ProtocolUpgradeHandler, and then runs
/// `ZkProtocolUpgradeDeploymentChecks` against the result.
/// @dev The contracts reference each other, so they are deployed first and wired afterwards, rather than by predicting
/// addresses, which ZKsync Era derives differently from the EVM:
/// - The override timelock is deployed with the deployer as a temporary admin, so that it can grant roles to the
///   Supermajority Governor deployed after it. The deployer then renounces the admin role.
/// - The Council Governor is deployed with no Veto Governor and the deployer as a temporary admin. The Veto Governor
///   stores the Council Governor's address immutably, so it is deployed next; the deployer then points the Council
///   Governor at it and transfers the admin role.
/// - `CouncilERC20` is owned by the deployer only while seats are minted.
/// The checks run at the end of the script fail the deployment if the deployer keeps any of these privileges.
///
/// Usage: `forge script script/DeployZkProtocolUpgradeGovernance.s.sol --zksync --rpc-url <era-rpc> --broadcast`
/// with the deployer passed through the usual forge wallet options, e.g. `--account` or `--private-key`.
/// Omit `--broadcast` for a dry run against the live chain state.
contract DeployZkProtocolUpgradeGovernance is Script, ZkProtocolUpgradeDeploymentChecks {
  /// @notice Deploys, wires and checks the contracts.
  /// @return _deployment The deployed contracts.
  function run() public returns (Deployment memory _deployment) {
    vm.startBroadcast();
    (VmSafe.CallerMode _mode, address _deployer,) = vm.readCallers();
    require(_mode == VmSafe.CallerMode.RecurrentBroadcast, "deployer not broadcasting");

    _deployment.councilToken = _deployCouncilToken(_deployer);
    (_deployment.supermajorityGovernor, _deployment.overrideTimelock) = _deploySupermajorityGovernor(_deployer);
    (_deployment.councilGovernor, _deployment.vetoGovernor) =
      _deployCouncilAndVetoGovernors(_deployer, _deployment.councilToken, _deployment.overrideTimelock);

    vm.stopBroadcast();

    _checkDeployment(_deployment, _deployer);

    console2.log("CouncilERC20:", address(_deployment.councilToken));
    console2.log("ZkProtocolUpgradeCouncilGovernor:", address(_deployment.councilGovernor));
    console2.log("ZkProtocolUpgradeVetoGovernor:", address(_deployment.vetoGovernor));
    console2.log("ZkSupermajorityGovernor:", address(_deployment.supermajorityGovernor));
    console2.log("Override TimelockController:", address(_deployment.overrideTimelock));
  }

  /// @notice Deploys `CouncilERC20`, mints one seat to each council member, and hands ownership to the governance
  /// admin.
  function _deployCouncilToken(address _deployer) internal returns (CouncilERC20 _councilToken) {
    _councilToken = new CouncilERC20(COUNCIL_TOKEN_NAME, COUNCIL_TOKEN_SYMBOL, _deployer, COUNCIL_SEAT);
    address[] memory _members = _councilMembers();
    for (uint256 _i = 0; _i < _members.length; _i++) {
      _councilToken.mint(_members[_i], COUNCIL_SEAT);
    }
    _councilToken.transferOwnership(GOVERNANCE_ADMIN);
  }

  /// @notice Deploys the override timelock and the Supermajority Governor, makes the governor the timelock's only
  /// proposer and canceller with open execution, and renounces the deployer's admin role on the timelock.
  function _deploySupermajorityGovernor(address _deployer)
    internal
    returns (ZkSupermajorityGovernor _governor, TimelockController _timelock)
  {
    address[] memory _executors = new address[](1);
    _executors[0] = address(0);
    _timelock = new TimelockController(OVERRIDE_TIMELOCK_MIN_DELAY, new address[](0), _executors, _deployer);

    _governor = new ZkSupermajorityGovernor(
      SUPERMAJORITY_GOVERNOR_NAME,
      IVotes(ZK_TOKEN),
      _timelock,
      SUPERMAJORITY_GOVERNOR_VOTING_DELAY,
      SUPERMAJORITY_GOVERNOR_VOTING_PERIOD,
      SUPERMAJORITY_GOVERNOR_PROPOSAL_THRESHOLD,
      SUPERMAJORITY_GOVERNOR_QUORUM,
      SUPERMAJORITY_GOVERNOR_LATE_QUORUM_EXTENSION
    );

    _timelock.grantRole(_timelock.PROPOSER_ROLE(), address(_governor));
    _timelock.grantRole(_timelock.CANCELLER_ROLE(), address(_governor));
    _timelock.renounceRole(_timelock.DEFAULT_ADMIN_ROLE(), _deployer);
  }

  /// @notice Deploys the Council and Veto Governors, points the Council Governor at the Veto Governor, and hands the
  /// Council Governor's admin role to the governance admin.
  function _deployCouncilAndVetoGovernors(
    address _deployer,
    CouncilERC20 _councilToken,
    TimelockController _overrideTimelock
  ) internal returns (ZkProtocolUpgradeCouncilGovernor _councilGovernor, ZkProtocolUpgradeVetoGovernor _vetoGovernor) {
    _councilGovernor = new ZkProtocolUpgradeCouncilGovernor(
      COUNCIL_GOVERNOR_NAME,
      IERC5805(address(_councilToken)),
      IGovernor(address(0)),
      _deployer,
      BasicCouncilGovernor.InitialCouncilParams({
        initialVotingDelay: COUNCIL_GOVERNOR_VOTING_DELAY,
        initialVotingPeriod: COUNCIL_GOVERNOR_VOTING_PERIOD,
        initialProposalThreshold: COUNCIL_GOVERNOR_PROPOSAL_THRESHOLD,
        initialQuorumFraction: COUNCIL_GOVERNOR_QUORUM_FRACTION,
        initialSuperQuorumFraction: COUNCIL_GOVERNOR_SUPER_QUORUM_FRACTION
      })
    );

    _vetoGovernor = new ZkProtocolUpgradeVetoGovernor(
      BasicCouncilVetoGovernor.ConstructorParams({
        name: VETO_GOVERNOR_NAME,
        token: ZK_TOKEN,
        votingDelay: VETO_GOVERNOR_VOTING_DELAY,
        votingPeriod: VETO_GOVERNOR_VOTING_PERIOD,
        proposalThreshold: VETO_GOVERNOR_PROPOSAL_THRESHOLD,
        vetoGuardian: VETO_GOVERNOR_VETO_GUARDIAN,
        vetoOverrideRole: address(_overrideTimelock),
        vetoOverrideDuration: VETO_GOVERNOR_VETO_OVERRIDE_DURATION,
        votingPeriodExtension: VETO_GOVERNOR_VOTING_PERIOD_EXTENSION,
        votingPeriodExtensionThresholdPct: VETO_GOVERNOR_EXTENSION_THRESHOLD_PCT,
        vetoThresholdNumerator: 0,
        timelock: TimelockController(payable(PROTOCOL_TIMELOCK)),
        governorAdmin: GOVERNANCE_ADMIN,
        council: address(_councilGovernor)
      }),
      VETO_GOVERNOR_VETO_THRESHOLD
    );

    _councilGovernor.setCouncilVetoGovernor(IGovernor(address(_vetoGovernor)));
    _councilGovernor.transferOwnership(GOVERNANCE_ADMIN);
  }
}

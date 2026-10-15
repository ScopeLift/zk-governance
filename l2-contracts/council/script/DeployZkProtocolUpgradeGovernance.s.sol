// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BasicCouncilGovernor} from "council-governance/BasicCouncilGovernor.sol";
import {BasicCouncilVetoGovernor} from "council-governance/BasicCouncilVetoGovernor.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/ZkProtocolUpgradeEraMainnetConfig.sol";

// The Supermajority Governor is the OpenZeppelin v4 `ZkProtocolGovernor`, which this project cannot import.
interface IGovernorTimelock {
  function timelock() external view returns (address);
}

// Step 2 of 2. Deploys `CouncilERC20`, `ZkProtocolUpgradeCouncilGovernor` and `ZkProtocolUpgradeVetoGovernor`, wires
// the Veto Governor to the override timelock from step 1, hands every admin role to the governance admin, and then
// checks the whole deployment. Step 1 is `DeploySupermajorityGovernor` in the main l2-contracts project, which checks
// the Supermajority Governor's own parameters. Both steps must use the same deployer account, since the checks confirm
// it kept no privileges on any contract.
//
// `run` reads the step 1 addresses from the `SUPERMAJORITY_GOVERNOR` and `OVERRIDE_TIMELOCK` environment variables.
// `check` runs the same checks against an existing deployment, reading `COUNCIL_TOKEN`, `COUNCIL_GOVERNOR`,
// `VETO_GOVERNOR`, `SUPERMAJORITY_GOVERNOR`, `OVERRIDE_TIMELOCK` and `DEPLOYER`.
//
// The contracts reference each other, so they are deployed first and wired afterwards, rather than by predicting
// addresses, which ZKsync Era derives differently from the EVM:
// - The Council Governor is deployed with no Veto Governor and the deployer as a temporary admin. The Veto Governor
//   stores the Council Governor's address immutably, so it is deployed next; the deployer then points the Council
//   Governor at it and transfers the admin role.
// - `CouncilERC20` is owned by the deployer only while seats are minted.
abstract contract DeployZkProtocolUpgradeGovernance is Script, ZkProtocolUpgradeDeploymentConfig {
  struct Deployment {
    CouncilERC20 councilToken;
    ZkProtocolUpgradeCouncilGovernor councilGovernor;
    ZkProtocolUpgradeVetoGovernor vetoGovernor;
    // From step 1. The override timelock is an OpenZeppelin v4 `TimelockController`, read through the v5 type, whose
    // ABI matches for the functions used here; its admin role is `TIMELOCK_ADMIN_ROLE`.
    address supermajorityGovernor;
    TimelockController overrideTimelock;
  }

  CouncilERC20 public councilToken;
  ZkProtocolUpgradeCouncilGovernor public councilGovernor;
  ZkProtocolUpgradeVetoGovernor public vetoGovernor;
  bool internal isLogging = true;

  function run() public virtual {
    DeploymentParams memory _params = _deploymentParams();
    Deployment memory _deployment;
    _deployment.supermajorityGovernor = vm.envAddress("SUPERMAJORITY_GOVERNOR");
    _deployment.overrideTimelock = TimelockController(payable(vm.envAddress("OVERRIDE_TIMELOCK")));
    _logDeploymentParams(_params, _deployment);

    vm.startBroadcast();
    (VmSafe.CallerMode _mode, address _deployer,) = vm.readCallers();
    vm.stopBroadcast();
    if (_mode != VmSafe.CallerMode.RecurrentBroadcast) {
      revert("DeployZkProtocolUpgradeGovernance: the deployer is not broadcasting");
    }
    // Fail before deploying anything if the step 1 contracts are wrong. Once the Veto Governor is deployed, replacing
    // its override timelock takes a full ZIP, since only the governance admin can call `setVetoOverrideRole`.
    _validateOverrideTimelock(_params, _deployment, _deployer);

    vm.startBroadcast();
    _deployCouncilToken(_params, _deployer);
    _deployCouncilAndVetoGovernors(_params, _deployment, _deployer);
    vm.stopBroadcast();

    _deployment.councilToken = councilToken;
    _deployment.councilGovernor = councilGovernor;
    _deployment.vetoGovernor = vetoGovernor;
    _validateDeployment(_params, _deployment, _deployer);

    _log(string.concat("CouncilERC20 (COUNCIL_TOKEN): ", vm.toString(address(councilToken))));
    _log(string.concat("ZkProtocolUpgradeCouncilGovernor (COUNCIL_GOVERNOR): ", vm.toString(address(councilGovernor))));
    _log(string.concat("ZkProtocolUpgradeVetoGovernor (VETO_GOVERNOR): ", vm.toString(address(vetoGovernor))));
  }

  function check() public view virtual {
    _validateDeployment(_deploymentParams(), _deploymentFromEnv(), vm.envAddress("DEPLOYER"));
    _log("All deployment checks passed");
  }

  function disableLogging() public {
    isLogging = false;
  }

  function _deploymentFromEnv() internal view returns (Deployment memory _deployment) {
    _deployment = Deployment({
      councilToken: CouncilERC20(vm.envAddress("COUNCIL_TOKEN")),
      councilGovernor: ZkProtocolUpgradeCouncilGovernor(payable(vm.envAddress("COUNCIL_GOVERNOR"))),
      vetoGovernor: ZkProtocolUpgradeVetoGovernor(payable(vm.envAddress("VETO_GOVERNOR"))),
      supermajorityGovernor: vm.envAddress("SUPERMAJORITY_GOVERNOR"),
      overrideTimelock: TimelockController(payable(vm.envAddress("OVERRIDE_TIMELOCK")))
    });
  }

  function _log(string memory _msg) internal view {
    if (isLogging) {
      console2.log(_msg);
    }
  }

  function _logDeploymentParams(DeploymentParams memory _params, Deployment memory _deployment) internal view {
    _log("Deploying the protocol upgrade council governance with:");
    _log(string.concat("  zkToken:               ", vm.toString(_params.zkToken)));
    _log(string.concat("  protocolTimelock:      ", vm.toString(_params.protocolTimelock)));
    _log(string.concat("  governanceAdmin:       ", vm.toString(_params.governanceAdmin)));
    _log(string.concat("  supermajorityGovernor: ", vm.toString(_deployment.supermajorityGovernor)));
    _log(string.concat("  overrideTimelock:      ", vm.toString(address(_deployment.overrideTimelock))));
    _log(string.concat("  council members:       ", vm.toString(_params.councilMembers.length)));
    for (uint256 _i = 0; _i < _params.councilMembers.length; _i += 1) {
      _log(string.concat("    ", vm.toString(_params.councilMembers[_i])));
    }
  }

  // Deploys `CouncilERC20`, mints one seat to each council member, and hands ownership to the governance admin.
  function _deployCouncilToken(DeploymentParams memory _params, address _deployer) internal {
    // BROADCAST: deploy CouncilERC20 with the deployer as a temporary owner
    _log("[1/7] Deploying CouncilERC20");
    councilToken =
      new CouncilERC20(_params.councilTokenName, _params.councilTokenSymbol, _deployer, _params.councilSeat);

    for (uint256 _i = 0; _i < _params.councilMembers.length; _i += 1) {
      // BROADCAST: mint one seat to each council member
      _log(string.concat("[2/7] Minting a seat to ", vm.toString(_params.councilMembers[_i])));
      councilToken.mint(_params.councilMembers[_i], _params.councilSeat);
    }

    // BROADCAST: hand CouncilERC20 ownership to the governance admin
    _log(string.concat("[3/7] Transferring CouncilERC20 ownership to ", vm.toString(_params.governanceAdmin)));
    councilToken.transferOwnership(_params.governanceAdmin);
  }

  // Deploys the Council and Veto Governors, points the Council Governor at the Veto Governor, and hands the Council
  // Governor's admin role to the governance admin.
  function _deployCouncilAndVetoGovernors(
    DeploymentParams memory _params,
    Deployment memory _deployment,
    address _deployer
  ) internal {
    // BROADCAST: deploy the Council Governor with no Veto Governor and the deployer as a temporary admin
    _log("[4/7] Deploying ZkProtocolUpgradeCouncilGovernor");
    councilGovernor = new ZkProtocolUpgradeCouncilGovernor(
      _params.councilGovernorName,
      IERC5805(address(councilToken)),
      IGovernor(address(0)),
      _deployer,
      BasicCouncilGovernor.InitialCouncilParams({
        initialVotingDelay: _params.councilGovernorVotingDelay,
        initialVotingPeriod: _params.councilGovernorVotingPeriod,
        initialProposalThreshold: _params.councilGovernorProposalThreshold,
        initialQuorumFraction: _params.councilGovernorQuorumFraction,
        initialSuperQuorumFraction: _params.councilGovernorSuperQuorumFraction
      })
    );

    // BROADCAST: deploy the Veto Governor
    _log("[5/7] Deploying ZkProtocolUpgradeVetoGovernor");
    vetoGovernor = new ZkProtocolUpgradeVetoGovernor(
      BasicCouncilVetoGovernor.ConstructorParams({
        name: _params.vetoGovernorName,
        token: _params.zkToken,
        votingDelay: _params.vetoGovernorVotingDelay,
        votingPeriod: _params.vetoGovernorVotingPeriod,
        proposalThreshold: _params.vetoGovernorProposalThreshold,
        vetoGuardian: _params.vetoGovernorVetoGuardian,
        vetoOverrideRole: address(_deployment.overrideTimelock),
        vetoOverrideDuration: _params.vetoGovernorVetoOverrideDuration,
        votingPeriodExtension: _params.vetoGovernorVotingPeriodExtension,
        votingPeriodExtensionThresholdPct: _params.vetoGovernorExtensionThresholdPct,
        vetoThresholdNumerator: 0,
        timelock: TimelockController(payable(_params.protocolTimelock)),
        governorAdmin: _params.governanceAdmin,
        council: address(councilGovernor)
      }),
      _params.vetoGovernorVetoThreshold
    );

    // BROADCAST: point the Council Governor at the Veto Governor
    _log("[6/7] Setting the Council Governor's Veto Governor");
    councilGovernor.setCouncilVetoGovernor(IGovernor(address(vetoGovernor)));

    // BROADCAST: hand the Council Governor's admin role to the governance admin
    _log(
      string.concat("[7/7] Transferring the Council Governor's admin role to ", vm.toString(_params.governanceAdmin))
    );
    councilGovernor.transferOwnership(_params.governanceAdmin);
  }

  // Runs every check against a deployment made by `_deployer`.
  function _validateDeployment(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    _validateCouncilToken(_params, _deployment, _deployer);
    _validateCouncilGovernor(_params, _deployment);
    _validateVetoGovernor(_params, _deployment);
    _validateOverrideTimelock(_params, _deployment, _deployer);
  }

  function _validateCouncilToken(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    CouncilERC20 _token = _deployment.councilToken;
    address[] memory _members = _params.councilMembers;

    if (!_eq(_token.name(), _params.councilTokenName)) {
      revert("DeployZkProtocolUpgradeGovernance: council token name does not match the params");
    }
    if (!_eq(_token.symbol(), _params.councilTokenSymbol)) {
      revert("DeployZkProtocolUpgradeGovernance: council token symbol does not match the params");
    }
    if (_token.owner() != _params.governanceAdmin) {
      revert("DeployZkProtocolUpgradeGovernance: council token owner is not the governance admin");
    }
    if (_token.MAX_TOKENS_PER_MEMBER() != _params.councilSeat) {
      revert("DeployZkProtocolUpgradeGovernance: council token max tokens per member is not one seat");
    }
    if (_token.totalSupply() != _params.councilSeat * _members.length) {
      revert("DeployZkProtocolUpgradeGovernance: council token supply is not one seat per member");
    }
    for (uint256 _i = 0; _i < _members.length; _i += 1) {
      if (_token.balanceOf(_members[_i]) != _params.councilSeat || _token.getVotes(_members[_i]) != _params.councilSeat)
      {
        revert(
          string.concat(
            "DeployZkProtocolUpgradeGovernance: council member ",
            vm.toString(_members[_i]),
            " does not hold and vote one seat"
          )
        );
      }
    }
    if (_token.balanceOf(_deployer) != 0) {
      revert("DeployZkProtocolUpgradeGovernance: the deployer holds a council seat");
    }
  }

  function _validateCouncilGovernor(DeploymentParams memory _params, Deployment memory _deployment) internal view {
    ZkProtocolUpgradeCouncilGovernor _governor = _deployment.councilGovernor;

    if (!_eq(_governor.name(), _params.councilGovernorName)) {
      revert("DeployZkProtocolUpgradeGovernance: council governor name does not match the params");
    }
    if (address(_governor.token()) != address(_deployment.councilToken)) {
      revert("DeployZkProtocolUpgradeGovernance: council governor token is not the council token");
    }
    if (address(_governor.councilVetoGovernor()) != address(_deployment.vetoGovernor)) {
      revert("DeployZkProtocolUpgradeGovernance: council governor does not submit proposals to the Veto Governor");
    }
    if (_governor.owner() != _params.governanceAdmin) {
      revert("DeployZkProtocolUpgradeGovernance: council governor admin is not the governance admin");
    }
    if (_governor.votingDelay() != _params.councilGovernorVotingDelay) {
      revert("DeployZkProtocolUpgradeGovernance: council governor voting delay does not match the params");
    }
    if (_governor.votingPeriod() != _params.councilGovernorVotingPeriod) {
      revert("DeployZkProtocolUpgradeGovernance: council governor voting period does not match the params");
    }
    if (_governor.proposalThreshold() != _params.councilGovernorProposalThreshold) {
      revert("DeployZkProtocolUpgradeGovernance: council governor proposal threshold does not match the params");
    }
    if (_governor.quorumNumerator() != _params.councilGovernorQuorumFraction) {
      revert("DeployZkProtocolUpgradeGovernance: council governor quorum does not match the params");
    }
    if (_governor.superQuorumNumerator() != _params.councilGovernorSuperQuorumFraction) {
      revert("DeployZkProtocolUpgradeGovernance: council governor super-quorum does not match the params");
    }
    // One seat must meet both quorum and super-quorum, so a single FOR vote is enough. The governor's `quorum` only
    // accepts past timepoints, so the values are computed from the current seat supply instead.
    uint256 _supply = _deployment.councilToken.totalSupply();
    uint256 _denominator = _governor.quorumDenominator();
    if (_supply * _governor.quorumNumerator() / _denominator > _params.councilSeat) {
      revert("DeployZkProtocolUpgradeGovernance: one council seat does not meet quorum");
    }
    if (_supply * _governor.superQuorumNumerator() / _denominator > _params.councilSeat) {
      revert("DeployZkProtocolUpgradeGovernance: one council seat does not meet super-quorum");
    }
  }

  function _validateVetoGovernor(DeploymentParams memory _params, Deployment memory _deployment) internal view {
    ZkProtocolUpgradeVetoGovernor _governor = _deployment.vetoGovernor;

    if (!_eq(_governor.name(), _params.vetoGovernorName)) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor name does not match the params");
    }
    if (address(_governor.token()) != _params.zkToken) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor token is not the ZK token");
    }
    if (_governor.COUNCIL() != address(_deployment.councilGovernor)) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor council is not the Council Governor");
    }
    if (_governor.timelock() != _params.protocolTimelock) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor timelock is not the Protocol Timelock");
    }
    if (_governor.owner() != _params.governanceAdmin) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor admin is not the governance admin");
    }
    if (_governor.votingDelay() != _params.vetoGovernorVotingDelay) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor voting delay does not match the params");
    }
    if (_governor.votingPeriod() != _params.vetoGovernorVotingPeriod) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor voting period does not match the params");
    }
    if (_governor.proposalThreshold() != _params.vetoGovernorProposalThreshold) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor proposal threshold does not match the params");
    }
    if (_governor.vetoThreshold(_governor.clock()) != _params.vetoGovernorVetoThreshold) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor veto threshold does not match the params");
    }
    if (_governor.vetoThresholdNumerator() != 0) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor uses a fractional veto threshold");
    }
    if (_governor.votingPeriodExtension() != _params.vetoGovernorVotingPeriodExtension) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor voting period extension does not match the params");
    }
    if (_governor.minorVetoExtensionThresholdPct() != _params.vetoGovernorExtensionThresholdPct) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor extension threshold does not match the params");
    }
    if (_governor.vetoGuardian() != _params.vetoGovernorVetoGuardian) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor veto guardian does not match the params");
    }
    if (_governor.vetoOverrideRole() != address(_deployment.overrideTimelock)) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor veto override role is not the override timelock");
    }
    if (_governor.vetoOverrideDuration() != _params.vetoGovernorVetoOverrideDuration) {
      revert("DeployZkProtocolUpgradeGovernance: veto governor override duration does not match the params");
    }
  }

  // Checks that the override timelock from step 1 belongs to the Supermajority Governor, administers itself, and gives
  // the deployer no role.
  function _validateOverrideTimelock(DeploymentParams memory _params, Deployment memory _deployment, address _deployer)
    internal
    view
  {
    TimelockController _timelock = _deployment.overrideTimelock;
    address _governor = _deployment.supermajorityGovernor;

    if (_governor.code.length == 0 || address(_timelock).code.length == 0) {
      revert("DeployZkProtocolUpgradeGovernance: the Supermajority Governor or override timelock is not deployed");
    }
    if (IGovernorTimelock(_governor).timelock() != address(_timelock)) {
      revert("DeployZkProtocolUpgradeGovernance: the Supermajority Governor's timelock is not the override timelock");
    }
    if (_timelock.getMinDelay() != _params.overrideTimelockMinDelay) {
      revert("DeployZkProtocolUpgradeGovernance: override timelock delay does not match the params");
    }
    if (!_timelock.hasRole(_timelock.PROPOSER_ROLE(), _governor)) {
      revert("DeployZkProtocolUpgradeGovernance: the Supermajority Governor is not the override timelock's proposer");
    }
    if (!_timelock.hasRole(_timelock.CANCELLER_ROLE(), _governor)) {
      revert("DeployZkProtocolUpgradeGovernance: the Supermajority Governor is not the override timelock's canceller");
    }
    if (!_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0))) {
      revert("DeployZkProtocolUpgradeGovernance: override timelock execution is not open to everyone");
    }
    if (!_timelock.hasRole(TIMELOCK_ADMIN_ROLE, address(_timelock))) {
      revert("DeployZkProtocolUpgradeGovernance: the override timelock does not administer itself");
    }
    if (
      _timelock.hasRole(TIMELOCK_ADMIN_ROLE, _deployer) || _timelock.hasRole(_timelock.PROPOSER_ROLE(), _deployer)
        || _timelock.hasRole(_timelock.CANCELLER_ROLE(), _deployer)
        || _timelock.hasRole(_timelock.EXECUTOR_ROLE(), _deployer)
    ) {
      revert("DeployZkProtocolUpgradeGovernance: the deployer holds a role on the override timelock");
    }
  }

  function _eq(string memory _a, string memory _b) internal pure returns (bool) {
    return keccak256(bytes(_a)) == keccak256(bytes(_b));
  }
}

// Deploys the protocol upgrade council governance on ZKsync Era mainnet with the ZIP parameters in
// `ZkProtocolUpgradeEraMainnetConfig`.
//
// Usage, from `l2-contracts/council`, with the deployer passed through the usual forge wallet options, e.g.
// `--account`: `SUPERMAJORITY_GOVERNOR=<addr> OVERRIDE_TIMELOCK=<addr> forge script
// script/DeployZkProtocolUpgradeGovernance.s.sol:DeployZkProtocolUpgradeGovernanceEraMainnet --zksync
// --rpc-url <era-rpc> --broadcast`
// Omit `--broadcast` for a dry run against the live chain state. Add `--sig "check()"` to check an existing deployment.
contract DeployZkProtocolUpgradeGovernanceEraMainnet is
  DeployZkProtocolUpgradeGovernance,
  ZkProtocolUpgradeEraMainnetConfig
{
  // Script entrypoint
  function run() public override {
    DeployZkProtocolUpgradeGovernance.run();
  }
}

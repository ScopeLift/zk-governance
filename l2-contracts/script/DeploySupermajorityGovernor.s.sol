// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ZkProtocolGovernor} from "src/ZkProtocolGovernor.sol";
import {DeployBase} from "council/script/DeployBase.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "council/script/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "council/script/ZkProtocolUpgradeEraMainnetConfig.sol";

// Step 1 of 2. Deploys the ZKsync Supermajority Governor and its override timelock. Step 2 is
// `DeployZkProtocolUpgradeGovernance` in `l2-contracts/council`, which deploys the council contracts and makes this
// override timelock the Veto Governor's `vetoOverrideRole`. Both steps must use the same deployer account.
//
// The Supermajority Governor is the existing `ZkProtocolGovernor`, deployed unchanged: its quorum counts FOR votes only
// and a proposal succeeds only with more FOR than AGAINST votes, which are the ZIP's supermajority rules. It and the
// override timelock are OpenZeppelin v4 contracts, so they are deployed from this project rather than the council
// project, which uses OpenZeppelin v5.
//
// The governor needs the timelock's address and the timelock needs the governor as its proposer, so the timelock is
// deployed with the deployer as a temporary admin. The deployer grants the governor the proposer and canceller roles
// and then renounces the admin role, leaving the timelock administered only by itself.
abstract contract DeploySupermajorityGovernor is DeployBase, ZkProtocolUpgradeDeploymentConfig {
  ZkProtocolGovernor public governor;
  TimelockController public timelock;

  function run() public virtual {
    DeploymentParams memory _params = _deploymentParams();
    _validateDeploymentParams(_params);
    _logDeploymentParams(_params);

    vm.startBroadcast();
    // The broadcasting account, read inside the broadcast so it is the deployer rather than the script contract.
    (, address _deployer,) = vm.readCallers();

    address[] memory _executors = new address[](1);
    _executors[0] = address(0);

    // BROADCAST: deploy the override timelock with the deployer as a temporary admin
    _log("[1/5] Deploying the override TimelockController");
    timelock = new TimelockController(_params.overrideTimelockMinDelay, new address[](0), _executors, _deployer);

    // BROADCAST: deploy the Supermajority Governor
    _log("[2/5] Deploying the Supermajority Governor (ZkProtocolGovernor)");
    governor = new ZkProtocolGovernor(
      _params.supermajorityGovernorName,
      IVotes(_params.zkToken),
      timelock,
      _params.supermajorityGovernorVotingDelay,
      _params.supermajorityGovernorVotingPeriod,
      _params.supermajorityGovernorProposalThreshold,
      _params.supermajorityGovernorQuorum,
      _params.supermajorityGovernorLateQuorumVoteExtension
    );

    // BROADCAST: make the governor the timelock's proposer
    _log("[3/5] Granting PROPOSER_ROLE on the override timelock to the governor");
    timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));

    // BROADCAST: make the governor the timelock's canceller
    _log("[4/5] Granting CANCELLER_ROLE on the override timelock to the governor");
    timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

    // BROADCAST: renounce the deployer's temporary admin role
    _log("[5/5] Renouncing the deployer's TIMELOCK_ADMIN_ROLE on the override timelock");
    timelock.renounceRole(timelock.TIMELOCK_ADMIN_ROLE(), _deployer);

    vm.stopBroadcast();

    _validateDeployment(_params, _deployer);

    _log(string.concat("Supermajority Governor (SUPERMAJORITY_GOVERNOR): ", vm.toString(address(governor))));
    _log(string.concat("Override TimelockController (OVERRIDE_TIMELOCK): ", vm.toString(address(timelock))));
  }

  // Runs the same checks against an existing step 1 deployment, reading `SUPERMAJORITY_GOVERNOR`, `OVERRIDE_TIMELOCK`
  // and `DEPLOYER`, the account that ran step 1.
  function check() public virtual {
    governor = ZkProtocolGovernor(payable(vm.envAddress("SUPERMAJORITY_GOVERNOR")));
    timelock = TimelockController(payable(vm.envAddress("OVERRIDE_TIMELOCK")));
    _validateDeployment(_deploymentParams(), vm.envAddress("DEPLOYER"));
    _log("All step 1 deployment checks passed");
  }

  function _logDeploymentParams(DeploymentParams memory _params) internal view {
    _log("Deploying the Supermajority Governor with:");
    _log(string.concat("  token:                    ", vm.toString(_params.zkToken)));
    _log(string.concat("  name:                     ", _params.supermajorityGovernorName));
    _log(string.concat("  votingDelay:              ", vm.toString(_params.supermajorityGovernorVotingDelay)));
    _log(string.concat("  votingPeriod:             ", vm.toString(_params.supermajorityGovernorVotingPeriod)));
    _log(string.concat("  proposalThreshold:        ", vm.toString(_params.supermajorityGovernorProposalThreshold)));
    _log(string.concat("  quorum:                   ", vm.toString(uint256(_params.supermajorityGovernorQuorum))));
    _log(
      string.concat("  lateQuorumVoteExtension:  ", vm.toString(_params.supermajorityGovernorLateQuorumVoteExtension))
    );
    _log(string.concat("  overrideTimelockMinDelay: ", vm.toString(_params.overrideTimelockMinDelay)));
  }

  function _validateDeploymentParams(DeploymentParams memory _params) internal view {
    if (_params.zkToken.code.length == 0) {
      revert("DeploySupermajorityGovernor: token has no code; set it to the ZK token");
    }
  }

  // Checks every parameter and role, and that the deployer kept no role on the override timelock. Step 2 checks the
  // link between the override timelock and the governor again before deploying anything.
  function _validateDeployment(DeploymentParams memory _params, address _deployer) internal view {
    if (!_eq(governor.name(), _params.supermajorityGovernorName)) {
      revert("DeploySupermajorityGovernor: governor name does not match the params");
    }
    if (address(governor.token()) != _params.zkToken) {
      revert("DeploySupermajorityGovernor: governor token does not match the params");
    }
    if (governor.timelock() != address(timelock)) {
      revert("DeploySupermajorityGovernor: governor timelock is not the override timelock");
    }
    if (governor.votingDelay() != _params.supermajorityGovernorVotingDelay) {
      revert("DeploySupermajorityGovernor: governor voting delay does not match the params");
    }
    if (governor.votingPeriod() != _params.supermajorityGovernorVotingPeriod) {
      revert("DeploySupermajorityGovernor: governor voting period does not match the params");
    }
    if (governor.proposalThreshold() != _params.supermajorityGovernorProposalThreshold) {
      revert("DeploySupermajorityGovernor: governor proposal threshold does not match the params");
    }
    if (governor.quorum(governor.clock()) != _params.supermajorityGovernorQuorum) {
      revert("DeploySupermajorityGovernor: governor quorum does not match the params");
    }
    if (governor.lateQuorumVoteExtension() != _params.supermajorityGovernorLateQuorumVoteExtension) {
      revert("DeploySupermajorityGovernor: governor late-quorum extension does not match the params");
    }

    if (timelock.getMinDelay() != _params.overrideTimelockMinDelay) {
      revert("DeploySupermajorityGovernor: override timelock delay does not match the params");
    }
    if (!timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor))) {
      revert("DeploySupermajorityGovernor: the governor is not the override timelock's proposer");
    }
    if (!timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor))) {
      revert("DeploySupermajorityGovernor: the governor is not the override timelock's canceller");
    }
    if (!timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))) {
      revert("DeploySupermajorityGovernor: override timelock execution is not open to everyone");
    }
    if (!timelock.hasRole(timelock.TIMELOCK_ADMIN_ROLE(), address(timelock))) {
      revert("DeploySupermajorityGovernor: the override timelock does not administer itself");
    }
    if (
      timelock.hasRole(timelock.TIMELOCK_ADMIN_ROLE(), _deployer)
        || timelock.hasRole(timelock.PROPOSER_ROLE(), _deployer)
        || timelock.hasRole(timelock.CANCELLER_ROLE(), _deployer)
        || timelock.hasRole(timelock.EXECUTOR_ROLE(), _deployer)
    ) {
      revert("DeploySupermajorityGovernor: the deployer kept a role on the override timelock");
    }
  }
}

// The ZIP parameters for the Supermajority Governor on ZKsync Era mainnet.
//
// Usage, from `l2-contracts`, with the deployer passed through the usual forge wallet options, e.g. `--account`:
// `forge script script/DeploySupermajorityGovernor.s.sol:DeploySupermajorityGovernorEraMainnet --zksync
// --rpc-url <era-rpc> --broadcast`
// Omit `--broadcast` for a dry run. Pass the logged addresses to step 2 as `SUPERMAJORITY_GOVERNOR` and
// `OVERRIDE_TIMELOCK`. After broadcasting, add `--sig "check()"` with those two and `DEPLOYER` set to check the
// deployment on chain.
contract DeploySupermajorityGovernorEraMainnet is DeploySupermajorityGovernor, ZkProtocolUpgradeEraMainnetConfig {
  // Script entrypoint
  function run() public override {
    DeploySupermajorityGovernor.run();
  }
}

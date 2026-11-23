// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/configs/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/configs/ZkProtocolUpgradeEraMainnetConfig.sol";
import {ZkProtocolUpgradeGovernanceChecks} from "script/ZkProtocolUpgradeGovernanceChecks.sol";
import {ProposeProtocolTimelockRoleMigration} from "script/ProposeProtocolTimelockRoleMigration.s.sol";
import {
  DeployZkProtocolUpgradeGovernanceEraMainnetHarness
} from "test/harnesses/DeployZkProtocolUpgradeGovernanceHarness.sol";
import {
  ProtocolTimelockRoleMigrationEraMainnetHarness
} from "test/harnesses/ProtocolTimelockRoleMigrationEraMainnetHarness.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {IZkCheatcodes} from "test/interfaces/IZkCheatcodes.sol";

/// @notice The protocol upgrade governance deployed on a fork of Era mainnet with the Era mainnet configuration, and
/// handed the Protocol Timelock roles by a role migration proposal that passes through the live `ZkProtocolGovernor`.
/// The ZK token, the Protocol Timelock and `ZkProtocolGovernor` are the live contracts.
/// @dev Run under `--zksync`, after `forge build src/ZkProtocolGovernor.sol` and
/// `forge build --zksync src/ZkProtocolGovernor.sol` in the main l2-contracts project, which write its EVM and EraVM
/// artifacts. The deployment follows the production steps:
///
/// `DeploySupermajorityGovernor` deploys the override timelock and the Supermajority Governor, which are OpenZeppelin
/// v4 contracts this project cannot compile. foundry-zksync v0.1.10 cannot run that script here: a broadcast `new` of a
/// contract this project did not compile panics, because `zkRegisterContract` gives it no factory dependencies. So the
/// test makes the same deployments and calls from the same deployer with the main project's EraVM bytecode.
/// `DeployZkProtocolUpgradeGovernanceEraMainnet` then checks them with `SupermajorityGovernorChecks`, the checks
/// `DeploySupermajorityGovernor` itself runs, and deploys the council contracts, and the Protocol Timelock role
/// migration proposal from `ProposeProtocolTimelockRoleMigrationEraMainnet` passes through `ZkProtocolGovernor` with a
/// ZK delegate's votes.
///
/// Both deploy scripts run from `DEFAULT_SENDER`, the account a test broadcasts from, as on mainnet, where one account
/// runs both.
abstract contract ZkProtocolUpgradeGovernanceEraMainnetScript is
  ZkProtocolUpgradeGovernanceTest,
  ZkProtocolUpgradeEraMainnetConfig
{
  function _setUpNetwork() internal override {
    vm.createSelectFork(vm.envOr("ZKSYNC_RPC_URL", string("https://mainnet.era.zksync.io")), ERA_MAINNET_FORK_BLOCK);
    // The deployer pays the fees of the EraVM transactions the deploy scripts broadcast.
    vm.deal(DEFAULT_SENDER, 1 ether);
  }

  function _fetchOrDeploySystem() internal override returns (SystemUnderTest memory _system) {
    DeploymentParams memory _params = _deploymentParams();

    // Step 1: the Supermajority Governor and override timelock.
    (address _supermajorityGovernor, TimelockController _overrideTimelock) = _deploySupermajorityGovernor(_params);

    // Step 2: the council contracts, wired to the override timelock, after the script checks the step 1 contracts.
    ZkProtocolUpgradeGovernanceChecks.Deployment memory _deployment =
      _deployCouncilGovernance(_params, _supermajorityGovernor, _overrideTimelock);

    // Step 3: `ZkProtocolGovernor` moves the Protocol Timelock roles to the Veto Governor.
    IGovernor _protocolGovernor = _migrateProtocolTimelockRoles(_params, _deployment);

    _system = SystemUnderTest({
      councilToken: _deployment.councilToken,
      councilGovernor: _deployment.councilGovernor,
      vetoGovernor: _deployment.vetoGovernor,
      supermajorityGovernor: IGovernor(_supermajorityGovernor),
      overrideTimelock: _overrideTimelock,
      protocolTimelock: TimelockController(payable(_params.protocolTimelock)),
      protocolGovernor: _protocolGovernor,
      zkToken: IVotes(_params.zkToken)
    });
  }

  /*///////////////////////////////////////////////////////////////
                  Step 1: DeploySupermajorityGovernor
  //////////////////////////////////////////////////////////////*/

  /// @notice Makes the deployments and calls `DeploySupermajorityGovernor.run` makes, in its order and from its
  /// deployer: the override timelock with the deployer as a temporary admin and anyone as executor, the Supermajority
  /// Governor, the governor's proposer and canceller roles, and the deployer renouncing the admin role.
  function _deploySupermajorityGovernor(DeploymentParams memory _params)
    internal
    returns (address _governor, TimelockController _timelock)
  {
    _registerMainProjectContract(OVERRIDE_TIMELOCK_ARTIFACT);
    _registerMainProjectContract(SUPERMAJORITY_GOVERNOR_ARTIFACT);
    // The zero address as executor lets anyone execute a ready operation.
    address[] memory _executors = new address[](1);

    vm.startPrank(DEFAULT_SENDER);
    _timelock = TimelockController(
      payable(deployCode(
          _mainProjectEvmArtifact(OVERRIDE_TIMELOCK_ARTIFACT),
          abi.encode(_params.overrideTimelockMinDelay, new address[](0), _executors, DEFAULT_SENDER)
        ))
    );
    _governor = deployCode(
      _mainProjectEvmArtifact(SUPERMAJORITY_GOVERNOR_ARTIFACT),
      abi.encode(
        _params.supermajorityGovernorName,
        _params.zkToken,
        address(_timelock),
        _params.supermajorityGovernorVotingDelay,
        _params.supermajorityGovernorVotingPeriod,
        _params.supermajorityGovernorProposalThreshold,
        _params.supermajorityGovernorQuorum,
        _params.supermajorityGovernorLateQuorumVoteExtension
      )
    );
    _timelock.grantRole(PROPOSER_ROLE, _governor);
    _timelock.grantRole(CANCELLER_ROLE, _governor);
    _timelock.renounceRole(TIMELOCK_ADMIN_ROLE, DEFAULT_SENDER);
    vm.stopPrank();
  }

  /// @notice Makes a CREATE with a main project contract's EVM init code deploy its EraVM bytecode, as for a contract
  /// this project compiles. `zkRegisterContract` gives the contract no factory dependencies, so its bytecode is also
  /// stored on an unused account, where EraVM can load it, and marked as known.
  function _registerMainProjectContract(string memory _artifact) internal {
    string memory _evmArtifact = vm.readFile(_mainProjectEvmArtifact(_artifact));
    string memory _eraVmArtifact = vm.readFile(string.concat(MAIN_PROJECT_ERAVM_ARTIFACTS, _artifact));
    bytes memory _evmDeployedBytecode = vm.parseJsonBytes(_evmArtifact, ".deployedBytecode.object");
    // zksolc writes the bytecode without a `0x` prefix.
    bytes memory _eraVmBytecode = vm.parseBytes(vm.parseJsonString(_eraVmArtifact, ".bytecode.object"));
    bytes32 _eraVmBytecodeHash = _mainProjectEraVmBytecodeHash(_artifact);

    IZkCheatcodes(address(vm))
      .zkRegisterContract(
        _artifact,
        keccak256(_evmDeployedBytecode),
        _evmDeployedBytecode,
        vm.parseJsonBytes(_evmArtifact, ".bytecode.object"),
        _eraVmBytecodeHash,
        _eraVmBytecode
      );
    // An account derived from the hash, so it holds nothing else and the two contracts' accounts differ.
    vm.etch(address(uint160(uint256(_eraVmBytecodeHash))), _eraVmBytecode);
    vm.store(KNOWN_CODES_STORAGE, _eraVmBytecodeHash, bytes32(uint256(1)));
  }

  function _mainProjectEvmArtifact(string memory _artifact) internal pure returns (string memory) {
    return string.concat(MAIN_PROJECT_EVM_ARTIFACTS, _artifact);
  }

  /*///////////////////////////////////////////////////////////////
               Step 2: DeployZkProtocolUpgradeGovernance
  //////////////////////////////////////////////////////////////*/

  /// @notice Runs `DeployZkProtocolUpgradeGovernanceEraMainnet` with the Era mainnet params against the step 1
  /// contracts. The harness takes the step 1 addresses through its constructor rather than the environment. The script
  /// runs in the EVM, as `forge script --zksync` runs it, and its broadcast deployments land in EraVM.
  function _deployCouncilGovernance(
    DeploymentParams memory _params,
    address _supermajorityGovernor,
    TimelockController _overrideTimelock
  ) internal returns (ZkProtocolUpgradeGovernanceChecks.Deployment memory) {
    IZkCheatcodes(address(vm)).zkVmSkip();
    DeployZkProtocolUpgradeGovernanceEraMainnetHarness _script = new DeployZkProtocolUpgradeGovernanceEraMainnetHarness(
      _params, _supermajorityGovernor, _overrideTimelock, address(0)
    );
    _script.disableLogging();
    _script.run();
    return ZkProtocolUpgradeGovernanceChecks.Deployment({
      councilToken: _script.councilToken(),
      councilGovernor: _script.councilGovernor(),
      vetoGovernor: _script.vetoGovernor(),
      supermajorityGovernor: _supermajorityGovernor,
      overrideTimelock: _overrideTimelock
    });
  }

  /*///////////////////////////////////////////////////////////////
                Step 3: Protocol Timelock role migration
  //////////////////////////////////////////////////////////////*/

  /// @notice Passes the role migration proposal the script builds through the live `ZkProtocolGovernor`, with the
  /// script's checks before and after. A delegate with `ZkProtocolGovernor`'s quorum proposes, votes FOR, and queues
  /// and executes it once the vote ends. Returns `ZkProtocolGovernor`.
  function _migrateProtocolTimelockRoles(
    DeploymentParams memory _params,
    ZkProtocolUpgradeGovernanceChecks.Deployment memory _deployment
  ) internal returns (IGovernor _protocolGovernor) {
    IZkCheatcodes(address(vm)).zkVmSkip();
    ProtocolTimelockRoleMigrationEraMainnetHarness _migration =
      new ProtocolTimelockRoleMigrationEraMainnetHarness(_deployment, DEFAULT_SENDER);
    _protocolGovernor = IGovernor(_migration.exposed__protocolGovernor());
    _migration.exposed__checkBeforeMigration();
    ProposeProtocolTimelockRoleMigration.Proposal memory _proposal = _migration.exposed__migrationProposal();

    // The delegate holds enough votes both to propose and to reach the quorum alone. Its votes count from the next
    // second, which the governor reads when it proposes.
    address _delegate = makeAddr("ZkProtocolGovernor Delegate");
    uint256 _votes = Math.max(_protocolGovernor.quorum(block.timestamp - 1), _protocolGovernor.proposalThreshold());
    deal(_params.zkToken, _delegate, _votes);
    vm.prank(_delegate);
    IVotes(_params.zkToken).delegate(_delegate);
    vm.warp(block.timestamp + 1);

    vm.prank(_delegate);
    uint256 _proposalId =
      _protocolGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
    vm.warp(_protocolGovernor.proposalSnapshot(_proposalId) + 1);
    vm.prank(_delegate);
    _protocolGovernor.castVote(_proposalId, 1);
    vm.warp(_protocolGovernor.proposalDeadline(_proposalId) + 1);
    bytes32 _descriptionHash = keccak256(bytes(_proposal.description));
    _protocolGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash);
    _protocolGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash);
    require(
      _protocolGovernor.state(_proposalId) == IGovernor.ProposalState.Executed,
      "setUp: ZkProtocolGovernor did not execute the role migration"
    );

    _migration.exposed__checkAfterMigration();
  }

  /// @notice Both configurations define the deployment params; the Era mainnet one supplies them.
  function _deploymentParams()
    internal
    view
    virtual
    override(ZkProtocolUpgradeDeploymentConfig, ZkProtocolUpgradeEraMainnetConfig)
    returns (DeploymentParams memory)
  {
    return ZkProtocolUpgradeEraMainnetConfig._deploymentParams();
  }
}

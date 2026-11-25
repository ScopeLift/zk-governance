// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/configs/ZkProtocolUpgradeDeploymentConfig.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "script/configs/ZkProtocolUpgradeEraMainnetConfig.sol";
import {ZkProtocolUpgradeGovernanceChecks} from "script/ZkProtocolUpgradeGovernanceChecks.sol";
import {
  DeployZkProtocolUpgradeGovernanceEraMainnetHarness
} from "test/harnesses/DeployZkProtocolUpgradeGovernanceHarness.sol";
import {
  ProposeProtocolTimelockRoleMigrationEraMainnetVoteHarness
} from "test/harnesses/ProposeProtocolTimelockRoleMigrationEraMainnetHarness.sol";
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
/// test makes the same deployments and calls from the same deployer with the main project's EraVM bytecode, after
/// checking that its build is of the sources on disk. The main project's own tests run `DeploySupermajorityGovernor`
/// itself, on a fork of Era mainnet too. `DeployZkProtocolUpgradeGovernanceEraMainnet` then checks these contracts with
/// `SupermajorityGovernorChecks`, the checks `DeploySupermajorityGovernor` itself runs, and deploys the council
/// contracts. Last, `ProposeProtocolTimelockRoleMigrationEraMainnet` runs with every check it makes on mainnet and
/// proposes the role migration, and the proposal passes through `ZkProtocolGovernor` with the proposer's votes in place
/// of the script's simulated execution.
///
/// `DEFAULT_SENDER`, the account a test broadcasts from, runs both deploy scripts, as one account does on mainnet, and
/// also proposes the role migration.
abstract contract ZkProtocolUpgradeGovernanceEraMainnetScript is
  ZkProtocolUpgradeGovernanceTest,
  ZkProtocolUpgradeEraMainnetConfig
{
  function _setUpNetwork() internal override {
    vm.createSelectFork(vm.envOr("ZKSYNC_RPC_URL", string("https://mainnet.era.zksync.io")), ERA_MAINNET_FORK_BLOCK);
    // The main project's scripts read the same variable for whichever network they target.
    require(block.chainid == ERA_MAINNET_CHAIN_ID, "setUp: ZKSYNC_RPC_URL is not an Era mainnet RPC");
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
    _requireMainProjectArtifact(_mainProjectEvmArtifact(_artifact));
    _requireMainProjectArtifact(string.concat(MAIN_PROJECT_ERAVM_ARTIFACTS, _artifact));
    _requireCurrentMainProjectBuild(_artifact);
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
    // `KnownCodesStorage` keeps each hash's marker in the slot equal to the hash, and a nonzero marker means known.
    vm.store(KNOWN_CODES_STORAGE, _eraVmBytecodeHash, bytes32(uint256(1)));
  }

  function _mainProjectEvmArtifact(string memory _artifact) internal pure returns (string memory) {
    return string.concat(MAIN_PROJECT_EVM_ARTIFACTS, _artifact);
  }

  // Without this, a missing build fails every test with a bare `vm.readFile` error that names neither build.
  function _requireMainProjectArtifact(string memory _path) internal view {
    require(vm.isFile(_path), string.concat("setUp: ", _path, " is missing; ", MAIN_PROJECT_BUILD_COMMANDS));
  }

  // A build of older sources would deploy other code than `DeploySupermajorityGovernor` deploys today, and the tests
  // would still pass. The EVM artifact records the keccak256 of each source it was built from, so each is compared with
  // the file on disk. zksolc records no sources, so the EraVM artifact is trusted to come from the same build, as the
  // two build commands produce it.
  function _requireCurrentMainProjectBuild(string memory _artifact) internal view {
    string memory _evmArtifactPath = _mainProjectEvmArtifact(_artifact);
    string memory _evmArtifact = vm.readFile(_evmArtifactPath);
    string[] memory _sources = vm.parseJsonKeys(_evmArtifact, ".metadata.sources");
    for (uint256 _i = 0; _i < _sources.length; _i += 1) {
      string memory _source = string.concat(MAIN_PROJECT_ROOT, _sources[_i]);
      bytes32 _builtHash =
        vm.parseJsonBytes32(_evmArtifact, string.concat(".metadata.sources['", _sources[_i], "'].keccak256"));
      require(
        keccak256(bytes(vm.readFile(_source))) == _builtHash,
        string.concat(
          "setUp: ", _source, " changed since ", _evmArtifactPath, " was built; ", MAIN_PROJECT_BUILD_COMMANDS
        )
      );
    }
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

  /// @notice Runs `ProposeProtocolTimelockRoleMigrationEraMainnet` from `DEFAULT_SENDER` with enough votes both to
  /// propose and to reach `ZkProtocolGovernor`'s quorum alone. Its proposal passes through the live
  /// `ZkProtocolGovernor` in place of the script's simulated execution, and the script then checks the roles the
  /// execution left. Returns `ZkProtocolGovernor`.
  function _migrateProtocolTimelockRoles(
    DeploymentParams memory _params,
    ZkProtocolUpgradeGovernanceChecks.Deployment memory _deployment
  ) internal returns (IGovernor _protocolGovernor) {
    IZkCheatcodes(address(vm)).zkVmSkip();
    ProposeProtocolTimelockRoleMigrationEraMainnetVoteHarness _migration =
      new ProposeProtocolTimelockRoleMigrationEraMainnetVoteHarness(_deployment, DEFAULT_SENDER, DEFAULT_SENDER);
    _migration.disableLogging();
    _protocolGovernor = IGovernor(_migration.exposed__protocolGovernor());

    // The governor counts votes one tick before its clock, and votes count from the second after they are delegated,
    // which is when the script proposes.
    uint256 _votes =
      Math.max(_protocolGovernor.quorum(_protocolGovernor.clock() - 1), _protocolGovernor.proposalThreshold());
    _dealAndDelegateZk(IVotes(_params.zkToken), DEFAULT_SENDER, _votes);
    vm.warp(block.timestamp + 1);

    _migration.run();
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

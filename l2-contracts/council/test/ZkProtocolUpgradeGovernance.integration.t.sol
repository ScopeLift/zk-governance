// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {
  DeployZkProtocolUpgradeGovernance,
  DeployZkProtocolUpgradeGovernanceEraMainnet
} from "script/DeployZkProtocolUpgradeGovernance.s.sol";
import {ProtocolTimelockRoleMigration} from "script/ProtocolTimelockRoleMigration.sol";

/// @notice Stands in for a contract upgraded by a protocol upgrade proposal, recording who called it.
contract ProtocolUpgradeTarget {
  address public caller;
  uint256 public version;

  function upgrade(uint256 _version) external {
    caller = msg.sender;
    version = _version;
  }
}

/// @notice Step 1 of the deployment, `DeploySupermajorityGovernorEraMainnet`, as this project calls it. The script is
/// an OpenZeppelin v4 contract from the main l2-contracts project, so it is deployed from that project's artifacts.
interface IDeploySupermajorityGovernor {
  function run() external;
  function disableLogging() external;
  function governor() external view returns (address);
  function timelock() external view returns (address);
}

/// @notice Exercises the ZKsync protocol upgrade governance system as it is planned for production: the council
/// contracts and the Supermajority Governor deployed with the ZIP parameters, and the Protocol Timelock's proposer,
/// executor and canceller roles moved to the Veto Governor.
abstract contract ZkProtocolUpgradeGovernanceTest is Test, ProtocolTimelockRoleMigration {
  ZkProtocolUpgradeCouncilGovernor councilGovernor;
  ZkProtocolUpgradeVetoGovernor vetoGovernor;
  IGovernor supermajorityGovernor;
  ProtocolUpgradeTarget upgradeTarget;

  address councilMember;
  address tokenHolder = makeAddr("Token Holder");
  address supermajorityVoter = makeAddr("Supermajority Voter");

  /// @notice The ZK token supply, an upper bound on the votes any holder can cast.
  uint256 constant ZK_TOKEN_SUPPLY = 21_000_000_000e18;

  function setUp() public virtual {
    _setUpNetwork();
    DeployZkProtocolUpgradeGovernance.Deployment memory _deployment = _fetchOrDeploySystem();

    // The suite only means anything against the production configuration, so stop here if it is not.
    _checkAfterMigration(address(_deployment.vetoGovernor));
    require(
      _deployment.councilGovernor.councilVetoGovernor() == IGovernor(address(_deployment.vetoGovernor)),
      "setUp: the Council Governor does not submit proposals to the Veto Governor"
    );
    require(
      _deployment.vetoGovernor.vetoOverrideRole() == address(_deployment.overrideTimelock),
      "setUp: the override timelock cannot override vetoes"
    );

    councilGovernor = _deployment.councilGovernor;
    vetoGovernor = _deployment.vetoGovernor;
    supermajorityGovernor = IGovernor(_deployment.supermajorityGovernor);
    upgradeTarget = new ProtocolUpgradeTarget();
    councilMember = _deploymentParams().councilMembers[0];

    // The Supermajority Governor checks a proposer's votes just before it proposes, so the voter delegates early.
    _dealAndDelegateZk(supermajorityVoter, _deploymentParams().supermajorityGovernorQuorum);
    vm.warp(block.timestamp + 1);
  }

  /// @notice Creates and selects a fork, or prepares the local EVM.
  function _setUpNetwork() internal virtual;

  /// @notice Deploys the system, or returns an existing deployment, in its post-migration production configuration.
  function _fetchOrDeploySystem() internal virtual returns (DeployZkProtocolUpgradeGovernance.Deployment memory);

  /*///////////////////////////////////////////////////////////////
                              Proposals
  //////////////////////////////////////////////////////////////*/

  function _protocolUpgradeProposal() internal view returns (Proposal memory _proposal) {
    _proposal.targets = new address[](1);
    _proposal.targets[0] = address(upgradeTarget);
    _proposal.values = new uint256[](1);
    _proposal.calldatas = new bytes[](1);
    _proposal.calldatas[0] = abi.encodeCall(ProtocolUpgradeTarget.upgrade, (2));
    _proposal.description = "# Upgrade the protocol to version 2";
  }

  function _overrideVetoProposal(uint256 _vetoedProposalId) internal view returns (Proposal memory _proposal) {
    _proposal.targets = new address[](1);
    _proposal.targets[0] = address(vetoGovernor);
    _proposal.values = new uint256[](1);
    _proposal.calldatas = new bytes[](1);
    _proposal.calldatas[0] = abi.encodeCall(vetoGovernor.overrideVeto, (_vetoedProposalId));
    _proposal.description = string.concat("# Override the veto on proposal ", vm.toString(_vetoedProposalId));
  }

  function _descriptionHash(Proposal memory _proposal) internal pure returns (bytes32) {
    return keccak256(bytes(_proposal.description));
  }

  /*///////////////////////////////////////////////////////////////
                          ZK token holders
  //////////////////////////////////////////////////////////////*/

  function _dealAndDelegateZk(address _holder, uint256 _amount) internal {
    deal(ZK_TOKEN, _holder, _amount);
    vm.prank(_holder);
    IVotes(ZK_TOKEN).delegate(_holder);
  }

  /*///////////////////////////////////////////////////////////////
                          Council Governor
  //////////////////////////////////////////////////////////////*/

  function _proposeToCouncil(Proposal memory _proposal) internal returns (uint256 _proposalId) {
    vm.prank(councilMember);
    _proposalId =
      councilGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
  }

  function _warpToCouncilVoting(uint256 _proposalId) internal {
    vm.warp(councilGovernor.proposalSnapshot(_proposalId) + 1);
  }

  function _castCouncilVote(address _member, uint256 _proposalId, uint8 _support) internal {
    vm.prank(_member);
    councilGovernor.castVote(_proposalId, _support);
  }

  /// @notice Queueing a council proposal submits it to the Veto Governor.
  function _queueOnCouncil(Proposal memory _proposal) internal {
    councilGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /// @notice A council member proposes, votes FOR, and submits the passed proposal to the Veto Governor.
  function _passCouncilProposal(Proposal memory _proposal) internal returns (uint256 _proposalId) {
    _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(councilMember, _proposalId, 1);
    require(
      councilGovernor.state(_proposalId) == IGovernor.ProposalState.Succeeded,
      "_passCouncilProposal: one FOR vote did not pass the council proposal"
    );
    _queueOnCouncil(_proposal);
    require(
      vetoGovernor.state(_proposalId) == IGovernor.ProposalState.Pending,
      "_passCouncilProposal: the proposal did not reach the Veto Governor"
    );
  }

  /// @notice Only the Council Governor can execute on the Veto Governor, so execution goes through it.
  function _executeThroughCouncil(Proposal memory _proposal) internal {
    councilGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /*///////////////////////////////////////////////////////////////
                            Veto Governor
  //////////////////////////////////////////////////////////////*/

  function _warpToVetoVoting(uint256 _proposalId) internal {
    vm.warp(vetoGovernor.proposalSnapshot(_proposalId) + 1);
  }

  function _warpPastVetoDeadline(uint256 _proposalId) internal {
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + 1);
  }

  function _castVeto(address _holder, uint256 _proposalId) internal {
    vm.prank(_holder);
    vetoGovernor.castVote(_proposalId, 0);
  }

  function _vetoByGuardian(uint256 _proposalId) internal {
    vm.prank(_deploymentParams().vetoGovernorVetoGuardian);
    vetoGovernor.vetoByGuardian(_proposalId);
  }

  function _queueOnVetoGovernor(Proposal memory _proposal) internal {
    vetoGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /*///////////////////////////////////////////////////////////////
                        Supermajority Governor
  //////////////////////////////////////////////////////////////*/

  /// @notice The Supermajority Governor passes a proposal calling `overrideVeto` and executes it through the override
  /// timelock, the Veto Governor's veto override role.
  function _overrideVetoThroughSupermajority(uint256 _vetoedProposalId) internal {
    Proposal memory _proposal = _overrideVetoProposal(_vetoedProposalId);

    vm.prank(supermajorityVoter);
    uint256 _proposalId =
      supermajorityGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
    vm.warp(supermajorityGovernor.proposalSnapshot(_proposalId) + 1);
    vm.prank(supermajorityVoter);
    supermajorityGovernor.castVote(_proposalId, 1);
    vm.warp(supermajorityGovernor.proposalDeadline(_proposalId) + 1);
    require(
      supermajorityGovernor.state(_proposalId) == IGovernor.ProposalState.Succeeded,
      "_overrideVetoThroughSupermajority: the supermajority did not pass the override"
    );

    supermajorityGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
    vm.warp(block.timestamp + _deploymentParams().overrideTimelockMinDelay);
    supermajorityGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /*///////////////////////////////////////////////////////////////
                              Assertions
  //////////////////////////////////////////////////////////////*/

  function _assertState(IGovernor _governor, uint256 _proposalId, IGovernor.ProposalState _expected) internal {
    assertEq(uint8(_governor.state(_proposalId)), uint8(_expected));
  }

  function _assertUpgradeExecutedByProtocolTimelock(Proposal memory _proposal) internal {
    assertEq(upgradeTarget.caller(), PROTOCOL_TIMELOCK);
    assertEq(upgradeTarget.version(), 2);
    bytes32 _operationId = TimelockController(payable(PROTOCOL_TIMELOCK))
      .hashOperationBatch(
        _proposal.targets,
        _proposal.values,
        _proposal.calldatas,
        bytes32(0),
        // OpenZeppelin v5's `GovernorTimelockControl` salts its timelock operations with its own address.
        bytes20(address(vetoGovernor)) ^ _descriptionHash(_proposal)
      );
    assertTrue(TimelockController(payable(PROTOCOL_TIMELOCK)).isOperationDone(_operationId));
  }

  function _assertUpgradeNotExecuted() internal {
    assertEq(upgradeTarget.caller(), address(0));
    assertEq(upgradeTarget.version(), 0);
  }

  function _expectRevertUnexpectedState(
    uint256 _proposalId,
    IGovernor.ProposalState _current,
    IGovernor.ProposalState _allowedA,
    IGovernor.ProposalState _allowedB
  ) internal {
    bytes32 _allowed = bytes32(1 << uint8(_allowedA)) | bytes32(1 << uint8(_allowedB));
    vm.expectRevert(
      abi.encodeWithSelector(IGovernor.GovernorUnexpectedProposalState.selector, _proposalId, _current, _allowed)
    );
  }

  /// @notice A vetoed proposal can be neither queued on the Veto Governor nor executed through the Council Governor,
  /// which reports it as canceled.
  function _assertVetoedProposalIsStuck(Proposal memory _proposal, uint256 _proposalId) internal {
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Defeated);
    _assertState(councilGovernor, _proposalId, IGovernor.ProposalState.Canceled);

    _expectRevertUnexpectedState(
      _proposalId,
      IGovernor.ProposalState.Defeated,
      IGovernor.ProposalState.Succeeded,
      IGovernor.ProposalState.Succeeded
    );
    _queueOnVetoGovernor(_proposal);

    _expectRevertUnexpectedState(
      _proposalId, IGovernor.ProposalState.Canceled, IGovernor.ProposalState.Succeeded, IGovernor.ProposalState.Queued
    );
    _executeThroughCouncil(_proposal);

    _assertUpgradeNotExecuted();
  }

  /*///////////////////////////////////////////////////////////////
                                Tests
  //////////////////////////////////////////////////////////////*/

  function testFuzz_CouncilProposalExecutesThroughTheProtocolTimelockWhenTokenHoldersDoNotVeto(uint256 _vetoVotes)
    public
  {
    _vetoVotes = bound(_vetoVotes, 0, _deploymentParams().vetoGovernorVetoThreshold - 1);
    _dealAndDelegateZk(tokenHolder, _vetoVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();

    // One council member sponsors the proposal, which goes to the Veto Governor.
    uint256 _proposalId = _passCouncilProposal(_proposal);

    // Token holders vote to veto, but stay below the veto threshold.
    _warpToVetoVoting(_proposalId);
    _castVeto(tokenHolder, _proposalId);
    _warpPastVetoDeadline(_proposalId);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Succeeded);

    // The proposal is queued on the Protocol Timelock and executed through the Council Governor.
    _queueOnVetoGovernor(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Executed);
    _assertState(councilGovernor, _proposalId, IGovernor.ProposalState.Executed);
  }

  function testFuzz_TokenHoldersVetoACouncilProposalSoItCanNeitherBeQueuedNorExecuted(uint256 _vetoVotes) public {
    _vetoVotes = bound(_vetoVotes, _deploymentParams().vetoGovernorVetoThreshold, ZK_TOKEN_SUPPLY);
    _dealAndDelegateZk(tokenHolder, _vetoVotes);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    // Token holders reach the veto threshold, which also extends the voting period.
    _warpToVetoVoting(_proposalId);
    _castVeto(tokenHolder, _proposalId);
    _warpPastVetoDeadline(_proposalId);

    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  function test_SupermajorityOverridesATokenHolderVetoSoTheCouncilProposalExecutes() public {
    _dealAndDelegateZk(tokenHolder, _deploymentParams().vetoGovernorVetoThreshold);
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    // Token holders veto the proposal.
    _warpToVetoVoting(_proposalId);
    _castVeto(tokenHolder, _proposalId);
    _warpPastVetoDeadline(_proposalId);
    require(
      vetoGovernor.state(_proposalId) == IGovernor.ProposalState.Defeated, "precondition: the proposal was not vetoed"
    );

    // Once the veto stands, the supermajority overrides it within the override window.
    uint256 _vetoDeadline = vetoGovernor.proposalDeadline(_proposalId);
    _overrideVetoThroughSupermajority(_proposalId);
    assertTrue(vetoGovernor.isVetoOverridden(_proposalId));
    assertLe(block.timestamp, _vetoDeadline + _deploymentParams().vetoGovernorVetoOverrideDuration);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Succeeded);
    _assertState(councilGovernor, _proposalId, IGovernor.ProposalState.Queued);

    // The revived proposal executes through the Protocol Timelock.
    _queueOnVetoGovernor(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Executed);
    _assertState(councilGovernor, _proposalId, IGovernor.ProposalState.Executed);
  }

  function test_GuardianVetoDefeatsACouncilProposalSoItCanNeitherBeQueuedNorExecuted() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    // The guardian vetoes while token holders are voting.
    _warpToVetoVoting(_proposalId);
    _vetoByGuardian(_proposalId);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Defeated);

    // The veto holds after the voting period ends.
    _warpPastVetoDeadline(_proposalId);
    _assertVetoedProposalIsStuck(_proposal, _proposalId);
  }

  /// @dev Pins the current behavior: the override role can revive any defeated proposal, including one the guardian
  /// vetoed. Whether that is intended is still to be confirmed with the ZKsync Association.
  function test_SupermajorityOverridesAGuardianVetoSoTheCouncilProposalExecutes() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    uint256 _proposalId = _passCouncilProposal(_proposal);

    // The guardian vetoes while token holders are voting.
    _warpToVetoVoting(_proposalId);
    _vetoByGuardian(_proposalId);

    // The supermajority starts its override straight away. It finishes after the veto's voting period ends, when
    // the override window opens, and well before the window closes.
    uint256 _vetoDeadline = vetoGovernor.proposalDeadline(_proposalId);
    _overrideVetoThroughSupermajority(_proposalId);
    assertGe(block.timestamp, _vetoDeadline);
    assertLe(block.timestamp, _vetoDeadline + _deploymentParams().vetoGovernorVetoOverrideDuration);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Succeeded);

    // The revived proposal executes through the Protocol Timelock.
    _queueOnVetoGovernor(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertState(vetoGovernor, _proposalId, IGovernor.ProposalState.Executed);
    _assertState(councilGovernor, _proposalId, IGovernor.ProposalState.Executed);
  }

  function test_CouncilProposalWithoutForVotesNeverReachesTheVetoGovernor() public {
    Proposal memory _proposal = _protocolUpgradeProposal();
    address[] memory _members = _deploymentParams().councilMembers;

    // The sponsor proposes, but the members who vote do not support it.
    uint256 _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(_members[1], _proposalId, 0);
    _castCouncilVote(_members[2], _proposalId, 2);
    vm.warp(councilGovernor.proposalDeadline(_proposalId) + 1);
    _assertState(councilGovernor, _proposalId, IGovernor.ProposalState.Defeated);

    // The defeated proposal cannot be submitted to the Veto Governor.
    _expectRevertUnexpectedState(
      _proposalId,
      IGovernor.ProposalState.Defeated,
      IGovernor.ProposalState.Succeeded,
      IGovernor.ProposalState.Succeeded
    );
    _queueOnCouncil(_proposal);

    assertEq(vetoGovernor.proposalSnapshot(_proposalId), 0);
    _assertUpgradeNotExecuted();
  }
}

/// @notice The system deployed on the local EVM by the production deploy scripts, with the existing ZKsync Era
/// contracts it depends on recreated at their mainnet addresses.
/// @dev The ZK token, the Protocol Timelock, `ZkProtocolGovernor` and the step 1 deploy script are OpenZeppelin v4
/// contracts, so they are deployed from the main l2-contracts project's artifacts. Run `forge build` in `l2-contracts`
/// before running this suite.
contract ZkProtocolUpgradeGovernanceLocal is ZkProtocolUpgradeGovernanceTest {
  string constant ZK_TOKEN_ARTIFACT = "../out/ERC20VotesFake.sol/ERC20VotesFake.json";
  string constant TIMELOCK_ARTIFACT = "../out/TimelockController.sol/TimelockController.json";
  string constant PROTOCOL_GOVERNOR_ARTIFACT = "../out/ZkProtocolGovernor.sol/ZkProtocolGovernor.json";
  string constant DEPLOY_SUPERMAJORITY_GOVERNOR_ARTIFACT =
    "../out/DeploySupermajorityGovernor.s.sol/DeploySupermajorityGovernorEraMainnet.json";

  function _setUpNetwork() internal override {
    // Local EVM — no fork. Start at a realistic time: OpenZeppelin v4's `TimelockController` marks executed
    // operations
    // with timestamp 1, the local EVM's default, so an operation scheduled then with no delay could never execute.
    vm.warp(1_760_000_000);
  }

  function _fetchOrDeploySystem()
    internal
    override
    returns (DeployZkProtocolUpgradeGovernance.Deployment memory _deployment)
  {
    _requireArtifact(ZK_TOKEN_ARTIFACT);
    _requireArtifact(TIMELOCK_ARTIFACT);
    _requireArtifact(PROTOCOL_GOVERNOR_ARTIFACT);
    _requireArtifact(DEPLOY_SUPERMAJORITY_GOVERNOR_ARTIFACT);

    _deployExistingEraContracts();

    // Step 1 deploys the Supermajority Governor and override timelock; step 2 deploys the council contracts.
    IDeploySupermajorityGovernor _step1 =
      IDeploySupermajorityGovernor(deployCode(DEPLOY_SUPERMAJORITY_GOVERNOR_ARTIFACT));
    _step1.disableLogging();
    _step1.run();
    vm.setEnv("SUPERMAJORITY_GOVERNOR", vm.toString(_step1.governor()));
    vm.setEnv("OVERRIDE_TIMELOCK", vm.toString(_step1.timelock()));

    DeployZkProtocolUpgradeGovernanceEraMainnet _step2 = new DeployZkProtocolUpgradeGovernanceEraMainnet();
    _step2.disableLogging();
    _step2.run();
    _deployment = DeployZkProtocolUpgradeGovernance.Deployment({
      councilToken: _step2.councilToken(),
      councilGovernor: _step2.councilGovernor(),
      vetoGovernor: _step2.vetoGovernor(),
      supermajorityGovernor: _step1.governor(),
      overrideTimelock: TimelockController(payable(_step1.timelock()))
    });

    // `ZkProtocolGovernor` passes the role migration proposal.
    vm.setEnv("COUNCIL_TOKEN", vm.toString(address(_deployment.councilToken)));
    vm.setEnv("COUNCIL_GOVERNOR", vm.toString(address(_deployment.councilGovernor)));
    vm.setEnv("VETO_GOVERNOR", vm.toString(address(_deployment.vetoGovernor)));
    vm.setEnv("DEPLOYER", vm.toString(DEFAULT_SENDER));
    _checkBeforeMigration(address(_deployment.vetoGovernor));
    _simulateMigration(_migrationProposal(address(_deployment.vetoGovernor)));
  }

  /// @notice Recreates the ZK token, the Protocol Timelock and `ZkProtocolGovernor` at their mainnet addresses, with
  /// `ZkProtocolGovernor` holding the Protocol Timelock roles the migration moves.
  function _deployExistingEraContracts() internal {
    deployCodeTo(ZK_TOKEN_ARTIFACT, ZK_TOKEN);

    address[] memory _protocolGovernor = new address[](1);
    _protocolGovernor[0] = PROTOCOL_GOVERNOR;
    deployCodeTo(TIMELOCK_ARTIFACT, abi.encode(0, _protocolGovernor, _protocolGovernor, address(0)), PROTOCOL_TIMELOCK);

    // The migration only reads `ZkProtocolGovernor`'s timelock; its other settings are placeholders.
    deployCodeTo(
      PROTOCOL_GOVERNOR_ARTIFACT,
      abi.encode(
        "ZkProtocolGovernor", ZK_TOKEN, PROTOCOL_TIMELOCK, uint48(1 days), uint32(7 days), uint256(0), uint224(1), 0
      ),
      PROTOCOL_GOVERNOR
    );
  }

  function _requireArtifact(string memory _path) internal {
    require(vm.exists(_path), string.concat(_path, " not found: run `forge build` in l2-contracts first"));
  }
}

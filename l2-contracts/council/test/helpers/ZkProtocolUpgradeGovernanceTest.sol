// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CouncilERC20} from "council-governance/CouncilERC20.sol";
import {ZkProtocolUpgradeCouncilGovernor} from "src/ZkProtocolUpgradeCouncilGovernor.sol";
import {ZkProtocolUpgradeVetoGovernor} from "src/ZkProtocolUpgradeVetoGovernor.sol";
import {ZkProtocolUpgradeDeploymentConfig} from "script/configs/ZkProtocolUpgradeDeploymentConfig.sol";
import {ProtocolUpgradeTarget} from "test/helpers/ProtocolUpgradeTarget.sol";
import {Constants} from "test/utils/Constants.sol";
import {TestHelpers} from "test/utils/TestHelpers.sol";

/// @notice The shared setup and steps of the protocol upgrade governance smoke tests: a council proposal that goes from
/// the Council Governor to the Veto Governor, where ZK token holders and the veto guardian can veto it and the
/// Supermajority Governor can override the veto, and that executes through the Protocol Timelock.
/// @dev Abstract in where the system comes from: a provenance such as `ZkProtocolUpgradeGovernanceEraMainnetScript`
/// supplies the network and the deployment. Suites inherit both this contract and a provenance. The deployment
/// parameters, including the council members, the veto guardian and the governance admin, come from the provenance's
/// configuration through `_deploymentParams`.
abstract contract ZkProtocolUpgradeGovernanceTest is TestHelpers, Constants, ZkProtocolUpgradeDeploymentConfig {
  // The OpenZeppelin `TimelockController` roles the Protocol Timelock role migration moves.
  bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
  bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
  bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

  /// @notice The contracts the smoke tests drive, in their production configuration after the Protocol Timelock role
  /// migration.
  struct SystemUnderTest {
    CouncilERC20 councilToken;
    ZkProtocolUpgradeCouncilGovernor councilGovernor;
    ZkProtocolUpgradeVetoGovernor vetoGovernor;
    // The OpenZeppelin v4 contracts are read through the v5 types, whose ABIs match for the functions the tests call.
    IGovernor supermajorityGovernor;
    TimelockController overrideTimelock;
    TimelockController protocolTimelock;
    // `ZkProtocolGovernor`, which held the Protocol Timelock roles before the migration.
    IGovernor protocolGovernor;
    IVotes zkToken;
  }

  /// @notice A governor proposal, in the form `propose` takes it.
  struct Proposal {
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string description;
  }

  CouncilERC20 councilToken;
  ZkProtocolUpgradeCouncilGovernor councilGovernor;
  ZkProtocolUpgradeVetoGovernor vetoGovernor;
  IGovernor supermajorityGovernor;
  TimelockController overrideTimelock;
  TimelockController protocolTimelock;
  IGovernor protocolGovernor;
  IVotes zkToken;
  ProtocolUpgradeTarget upgradeTarget;

  /// @notice The council member who proposes and votes FOR in `_passCouncilProposal`.
  address councilMember;
  address tokenHolder = makeAddr("Token Holder");
  /// @notice Holds the Supermajority Governor's quorum and proposes and votes FOR every veto override.
  address supermajorityVoter = makeAddr("Supermajority Voter");

  function setUp() public virtual {
    _setUpNetwork();
    SystemUnderTest memory _system = _fetchOrDeploySystem();
    councilToken = _system.councilToken;
    councilGovernor = _system.councilGovernor;
    vetoGovernor = _system.vetoGovernor;
    supermajorityGovernor = _system.supermajorityGovernor;
    overrideTimelock = _system.overrideTimelock;
    protocolTimelock = _system.protocolTimelock;
    protocolGovernor = _system.protocolGovernor;
    zkToken = _system.zkToken;

    _requireProductionWiring();

    upgradeTarget = new ProtocolUpgradeTarget();
    councilMember = _deploymentParams().councilMembers[0];

    // The Supermajority Governor counts a proposer's votes one second before it proposes, so the voter delegates now.
    _dealAndDelegateZk(supermajorityVoter, _deploymentParams().supermajorityGovernorQuorum);
    vm.warp(block.timestamp + 1);
  }

  /// @notice Creates and selects the fork the system lives on.
  function _setUpNetwork() internal virtual;

  /// @notice Produces the system under test in its post-migration production configuration.
  function _fetchOrDeploySystem() internal virtual returns (SystemUnderTest memory);

  // Every smoke test relies on the governors being wired to each other and to the Protocol Timelock as in production,
  // so a provenance that gets it wrong fails here rather than in each test.
  function _requireProductionWiring() internal view {
    require(
      address(councilGovernor.councilVetoGovernor()) == address(vetoGovernor),
      "setUp: the Council Governor does not forward proposals to the Veto Governor"
    );
    require(vetoGovernor.COUNCIL() == address(councilGovernor), "setUp: the Veto Governor's council is not the Council");
    require(vetoGovernor.timelock() == address(protocolTimelock), "setUp: the Veto Governor does not use the Timelock");
    require(
      vetoGovernor.vetoOverrideRole() == address(overrideTimelock),
      "setUp: the override timelock cannot override vetoes"
    );
    require(
      protocolTimelock.hasRole(PROPOSER_ROLE, address(vetoGovernor))
        && protocolTimelock.hasRole(EXECUTOR_ROLE, address(vetoGovernor))
        && protocolTimelock.hasRole(CANCELLER_ROLE, address(vetoGovernor)),
      "setUp: the role migration did not give the Veto Governor the Protocol Timelock roles"
    );
  }

  /*///////////////////////////////////////////////////////////////
                          Deployment values
  //////////////////////////////////////////////////////////////*/

  /// @notice The AGAINST votes at which token holders veto a proposal: 630M ZK with the Era mainnet params.
  function _vetoThreshold() internal view returns (uint256) {
    return _deploymentParams().vetoGovernorVetoThreshold;
  }

  /// @notice The AGAINST votes at which the Veto Governor extends a proposal's deadline, a percentage of the veto
  /// threshold rounded down as the governor rounds it: 315M ZK with the Era mainnet params.
  function _extensionThreshold() internal view returns (uint256) {
    DeploymentParams memory _params = _deploymentParams();
    return _params.vetoGovernorVetoThreshold * _params.vetoGovernorVotingPeriodExtensionThresholdPct / 100;
  }

  /// @notice The FOR votes a Supermajority Governor proposal needs: 1.26B ZK with the Era mainnet params.
  function _supermajorityQuorum() internal view returns (uint256) {
    return _deploymentParams().supermajorityGovernorQuorum;
  }

  /// @notice The ZK token's total supply, an upper bound on any holder's votes.
  function _zkTotalSupply() internal view returns (uint256) {
    return IERC20(address(zkToken)).totalSupply();
  }

  /// @notice Excludes the addresses a fuzzed caller must not be under `--zksync`: EraVM's system contracts and
  /// precompiles, and Foundry's own addresses such as the cheatcode address. Pranking those fails in ways unrelated to
  /// the access check a test makes.
  function _assumeSafeFuzzedCaller(address _caller) internal pure {
    _assumeNotASystemAddress(_caller);
    assumeNotForgeAddress(_caller);
  }

  /// @notice The EraVM bytecode hash zksolc recorded in a main project artifact, which is the code hash of every
  /// contract deployed from it.
  function _mainProjectEraVmBytecodeHash(string memory _artifact) internal view returns (bytes32) {
    string memory _json = vm.readFile(string.concat(MAIN_PROJECT_ERAVM_ARTIFACTS, _artifact));
    // zksolc writes the hash without a `0x` prefix.
    return vm.parseBytes32(string.concat("0x", vm.parseJsonString(_json, ".hash")));
  }

  /*///////////////////////////////////////////////////////////////
                              Proposals
  //////////////////////////////////////////////////////////////*/

  /// @notice A proposal that calls `upgradeTarget.upgrade()` once.
  function _protocolUpgradeProposal() internal view returns (Proposal memory) {
    return _protocolUpgradeProposal("# Upgrade the protocol");
  }

  /// @notice A proposal that calls `upgradeTarget.upgrade()` once, with `_description`. Proposals with different
  /// descriptions have different IDs.
  function _protocolUpgradeProposal(string memory _description) internal view returns (Proposal memory _proposal) {
    _proposal = _singleCallProposal(address(upgradeTarget), abi.encodeCall(ProtocolUpgradeTarget.upgrade, ()));
    _proposal.description = _description;
  }

  /// @notice The Supermajority Governor proposal that calls `overrideVeto` on the Veto Governor for
  /// `_vetoedProposalId`.
  function _vetoOverrideProposal(uint256 _vetoedProposalId) internal view returns (Proposal memory _proposal) {
    _proposal =
      _singleCallProposal(address(vetoGovernor), abi.encodeCall(vetoGovernor.overrideVeto, (_vetoedProposalId)));
    _proposal.description = string.concat("# Override the veto on proposal ", vm.toString(_vetoedProposalId));
  }

  /// @notice A proposal with no description that makes one call, with no value, to `_target`.
  function _singleCallProposal(address _target, bytes memory _calldata)
    internal
    pure
    returns (Proposal memory _proposal)
  {
    _proposal.targets = new address[](1);
    _proposal.targets[0] = _target;
    _proposal.values = new uint256[](1);
    _proposal.calldatas = new bytes[](1);
    _proposal.calldatas[0] = _calldata;
  }

  function _descriptionHash(Proposal memory _proposal) internal pure returns (bytes32) {
    return keccak256(bytes(_proposal.description));
  }

  /*///////////////////////////////////////////////////////////////
                           ZK token holders
  //////////////////////////////////////////////////////////////*/

  /// @notice Sets `_holder`'s ZK balance to `_amount` and delegates it to `_holder`. The votes count from the next
  /// second, so call this before the snapshot of the proposal they vote on.
  function _dealAndDelegateZk(address _holder, uint256 _amount) internal {
    deal(address(zkToken), _holder, _amount);
    vm.prank(_holder);
    zkToken.delegate(_holder);
    // `deal` writes the balance directly, and delegating to the account already delegated to moves no votes, so a
    // holder that delegated before would keep its old votes.
    require(zkToken.getVotes(_holder) == _amount, "_dealAndDelegateZk: the holder's votes do not match its balance");
  }

  /*///////////////////////////////////////////////////////////////
                           Council Governor
  //////////////////////////////////////////////////////////////*/

  function _proposeToCouncil(address _proposer, Proposal memory _proposal) internal returns (uint256) {
    vm.prank(_proposer);
    return councilGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
  }

  /// @notice `councilMember` proposes `_proposal` to the Council Governor.
  function _proposeToCouncil(Proposal memory _proposal) internal returns (uint256) {
    return _proposeToCouncil(councilMember, _proposal);
  }

  /// @notice Warps to the first second council members can vote on `_proposalId`.
  function _warpToCouncilVoting(uint256 _proposalId) internal {
    vm.warp(councilGovernor.proposalSnapshot(_proposalId) + 1);
  }

  /// @notice Warps to the first second after the council's voting period on `_proposalId` ends.
  function _warpPastCouncilDeadline(uint256 _proposalId) internal {
    vm.warp(councilGovernor.proposalDeadline(_proposalId) + 1);
  }

  function _castCouncilVote(address _member, uint256 _proposalId, uint8 _support) internal {
    vm.prank(_member);
    councilGovernor.castVote(_proposalId, _support);
  }

  /// @notice Queues `_proposal` on the Council Governor, which forwards it to the Veto Governor.
  function _queueOnCouncil(Proposal memory _proposal) internal {
    councilGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  function _cancelOnCouncil(address _caller, Proposal memory _proposal) internal {
    vm.prank(_caller);
    councilGovernor.cancel(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /// @notice `councilMember` proposes `_proposal`, votes FOR as soon as voting opens, and queues it on the Council
  /// Governor, which forwards it to the Veto Governor. Returns the proposal ID, which both governors share.
  function _passCouncilProposal(Proposal memory _proposal) internal returns (uint256 _proposalId) {
    _proposalId = _proposeToCouncil(_proposal);
    _warpToCouncilVoting(_proposalId);
    _castCouncilVote(councilMember, _proposalId, uint8(GovernorCountingSimple.VoteType.For));
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

  /// @notice Executes `_proposal` through the Council Governor, the only account the Veto Governor lets execute.
  function _executeThroughCouncil(Proposal memory _proposal) internal {
    councilGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /*///////////////////////////////////////////////////////////////
                             Veto Governor
  //////////////////////////////////////////////////////////////*/

  /// @notice Warps to the first second token holders can vote to veto `_proposalId`.
  function _warpToVetoVoting(uint256 _proposalId) internal {
    vm.warp(vetoGovernor.proposalSnapshot(_proposalId) + 1);
  }

  /// @notice Warps to `_proposalId`'s veto deadline, including any extension, the last second it is Active.
  function _warpToVetoDeadline(uint256 _proposalId) internal {
    vm.warp(vetoGovernor.proposalDeadline(_proposalId));
  }

  /// @notice Warps to the first second after `_proposalId`'s veto deadline, including any extension.
  function _warpPastVetoDeadline(uint256 _proposalId) internal {
    vm.warp(vetoGovernor.proposalDeadline(_proposalId) + 1);
  }

  /// @notice `_holder` votes to veto `_proposalId`. The Veto Governor counts only AGAINST votes.
  function _castVeto(address _holder, uint256 _proposalId) internal {
    vm.prank(_holder);
    vetoGovernor.castVote(_proposalId, uint8(GovernorCountingSimple.VoteType.Against));
  }

  /// @notice `_holder` gets `_votes` ZK votes, which count at `_proposalId`'s snapshot, and casts them as a veto once
  /// voting opens. Call it while the proposal is Pending on the Veto Governor; it warps to the start of voting.
  function _dealAndCastVeto(address _holder, uint256 _votes, uint256 _proposalId) internal {
    _dealAndDelegateZk(_holder, _votes);
    _warpToVetoVoting(_proposalId);
    _castVeto(_holder, _proposalId);
  }

  function _vetoByGuardian(uint256 _proposalId) internal {
    _vetoByGuardian(vetoGovernor.vetoGuardian(), _proposalId);
  }

  /// @notice `_guardian` calls `vetoByGuardian` on `_proposalId`. Takes the guardian, rather than reading it, so a test
  /// can expect the call to revert.
  function _vetoByGuardian(address _guardian, uint256 _proposalId) internal {
    vm.prank(_guardian);
    vetoGovernor.vetoByGuardian(_proposalId);
  }

  /// @notice Queues `_proposal` on the Veto Governor, which schedules it on the Protocol Timelock. Anyone can call it.
  function _queueOnProtocolTimelock(Proposal memory _proposal) internal {
    vetoGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /// @notice The salt of `_proposal`'s operation on the Protocol Timelock. OpenZeppelin v5's `GovernorTimelockControl`
  /// salts it with the Veto Governor's address.
  function _protocolTimelockSalt(Proposal memory _proposal) internal view returns (bytes32) {
    return bytes20(address(vetoGovernor)) ^ _descriptionHash(_proposal);
  }

  /// @notice The ID of `_proposal`'s operation on the Protocol Timelock.
  function _protocolTimelockOperationId(Proposal memory _proposal) internal view returns (bytes32) {
    return protocolTimelock.hashOperationBatch(
      _proposal.targets, _proposal.values, _proposal.calldatas, bytes32(0), _protocolTimelockSalt(_proposal)
    );
  }

  /*///////////////////////////////////////////////////////////////
                        Supermajority Governor
  //////////////////////////////////////////////////////////////*/

  /// @notice Calls the override timelock directly, which loads its account into the current transaction. The
  /// Supermajority Governor calls the override timelock from inside EraVM, and foundry-zksync finds the EraVM bytecode
  /// of a contract this project did not compile only on accounts the transaction has loaded. Without this, that call
  /// panics with "Trying to decommit unexisting hash". Each test is one transaction, so one call per test is enough;
  /// the helpers that call the Supermajority Governor make it anyway. That extra call is the first one a helper makes,
  /// so a `vm.expectRevert` placed before `_proposeVetoOverride` or `_queueAndExecuteVetoOverride` is spent on it; to
  /// expect a revert from the Supermajority Governor, call `_loadOverrideTimelock` and then the governor directly.
  function _loadOverrideTimelock() internal view {
    overrideTimelock.getMinDelay();
  }

  /// @notice `supermajorityVoter` proposes to the Supermajority Governor that the veto on `_vetoedProposalId` be
  /// overridden. Returns the Supermajority Governor's proposal ID.
  function _proposeVetoOverride(uint256 _vetoedProposalId) internal returns (uint256) {
    _loadOverrideTimelock();
    Proposal memory _proposal = _vetoOverrideProposal(_vetoedProposalId);
    vm.prank(supermajorityVoter);
    return
      supermajorityGovernor.propose(_proposal.targets, _proposal.values, _proposal.calldatas, _proposal.description);
  }

  /// @notice Warps to the first second token holders can vote on Supermajority Governor proposal
  /// `_supermajorityProposalId`.
  function _warpToSupermajorityVoting(uint256 _supermajorityProposalId) internal {
    vm.warp(supermajorityGovernor.proposalSnapshot(_supermajorityProposalId) + 1);
  }

  /// @notice Warps to the first second after Supermajority Governor proposal `_supermajorityProposalId`'s voting
  /// period, including any late quorum extension.
  function _warpPastSupermajorityDeadline(uint256 _supermajorityProposalId) internal {
    vm.warp(supermajorityGovernor.proposalDeadline(_supermajorityProposalId) + 1);
  }

  function _castSupermajorityVote(address _voter, uint256 _supermajorityProposalId, uint8 _support) internal {
    vm.prank(_voter);
    supermajorityGovernor.castVote(_supermajorityProposalId, _support);
  }

  /// @notice Queues the override of `_vetoedProposalId` on the override timelock, waits out its delay, and executes it,
  /// so the override timelock calls `overrideVeto`.
  function _queueAndExecuteVetoOverride(uint256 _vetoedProposalId) internal {
    _loadOverrideTimelock();
    Proposal memory _proposal = _vetoOverrideProposal(_vetoedProposalId);
    supermajorityGovernor.queue(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
    vm.warp(block.timestamp + overrideTimelock.getMinDelay());
    supermajorityGovernor.execute(_proposal.targets, _proposal.values, _proposal.calldatas, _descriptionHash(_proposal));
  }

  /// @notice Passes an override of the veto on `_vetoedProposalId` through the Supermajority Governor and executes it
  /// through the override timelock: `supermajorityVoter` proposes as soon as this is called, votes FOR with the full
  /// quorum, and the override executes as soon as the voting period and the timelock delay allow.
  function _overrideVetoThroughSupermajority(uint256 _vetoedProposalId) internal {
    uint256 _overrideProposalId = _proposeVetoOverride(_vetoedProposalId);
    _warpToSupermajorityVoting(_overrideProposalId);
    _castSupermajorityVote(supermajorityVoter, _overrideProposalId, uint8(GovernorCountingSimple.VoteType.For));
    _warpPastSupermajorityDeadline(_overrideProposalId);
    require(
      supermajorityGovernor.state(_overrideProposalId) == IGovernor.ProposalState.Succeeded,
      "_overrideVetoThroughSupermajority: the Supermajority Governor did not pass the override"
    );
    _queueAndExecuteVetoOverride(_vetoedProposalId);
  }

  /*///////////////////////////////////////////////////////////////
                              Assertions
  //////////////////////////////////////////////////////////////*/

  /// @notice Asserts the state of `_proposalId` on the Council Governor and on the Veto Governor.
  function _assertStates(
    uint256 _proposalId,
    IGovernor.ProposalState _councilState,
    IGovernor.ProposalState _vetoGovernorState
  ) internal view {
    assertEq(uint8(councilGovernor.state(_proposalId)), uint8(_councilState), "Council Governor state");
    assertEq(uint8(vetoGovernor.state(_proposalId)), uint8(_vetoGovernorState), "Veto Governor state");
  }

  /// @notice Asserts that `_proposal` ran exactly once, from the Protocol Timelock, as a completed timelock operation.
  function _assertUpgradeExecutedByProtocolTimelock(Proposal memory _proposal) internal view {
    assertEq(upgradeTarget.upgradeCount(), 1, "upgrade count");
    assertEq(upgradeTarget.lastCaller(), address(protocolTimelock), "upgrade caller");
    assertTrue(protocolTimelock.isOperationDone(_protocolTimelockOperationId(_proposal)), "timelock operation done");
  }

  /// @notice Asserts that the veto on `_proposal` was overridden, so the Veto Governor reports it Succeeded and the
  /// council Queued, then queues it on the Protocol Timelock, executes it through the council, and asserts that it ran.
  function _assertOverriddenProposalExecutes(Proposal memory _proposal, uint256 _proposalId) internal {
    assertTrue(vetoGovernor.isVetoOverridden(_proposalId), "veto overridden");
    _assertStates(_proposalId, IGovernor.ProposalState.Queued, IGovernor.ProposalState.Succeeded);

    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }

  function _assertUpgradeNotExecuted() internal view {
    assertEq(upgradeTarget.upgradeCount(), 0, "upgrade count");
  }

  /// @notice Expects the next call to revert because `_account` lacks `_role` on one of the OpenZeppelin v4 timelocks,
  /// whose `AccessControl` reverts with a string naming both.
  function _expectRevertMissingTimelockRole(address _account, bytes32 _role) internal {
    vm.expectRevert(
      bytes(
        string.concat(
          "AccessControl: account ", vm.toLowercase(vm.toString(_account)), " is missing role ", vm.toString(_role)
        )
      )
    );
  }

  /// @notice Expects the next call to revert with OpenZeppelin v5's `GovernorUnexpectedProposalState`, for a proposal
  /// in `_currentState` and a call that `_allowedStates` allows.
  function _expectRevertUnexpectedState(
    uint256 _proposalId,
    IGovernor.ProposalState _currentState,
    IGovernor.ProposalState[] memory _allowedStates
  ) internal {
    bytes32 _allowed;
    for (uint256 _i = 0; _i < _allowedStates.length; _i += 1) {
      _allowed |= bytes32(1 << uint8(_allowedStates[_i]));
    }
    vm.expectRevert(
      abi.encodeWithSelector(IGovernor.GovernorUnexpectedProposalState.selector, _proposalId, _currentState, _allowed)
    );
  }

  /// @notice `_expectRevertUnexpectedState` for a call allowed in one state.
  function _expectRevertUnexpectedState(
    uint256 _proposalId,
    IGovernor.ProposalState _currentState,
    IGovernor.ProposalState _allowedState
  ) internal {
    IGovernor.ProposalState[] memory _allowedStates = new IGovernor.ProposalState[](1);
    _allowedStates[0] = _allowedState;
    _expectRevertUnexpectedState(_proposalId, _currentState, _allowedStates);
  }

  /// @notice `_expectRevertUnexpectedState` for a call allowed in two states.
  function _expectRevertUnexpectedState(
    uint256 _proposalId,
    IGovernor.ProposalState _currentState,
    IGovernor.ProposalState _allowedStateA,
    IGovernor.ProposalState _allowedStateB
  ) internal {
    IGovernor.ProposalState[] memory _allowedStates = new IGovernor.ProposalState[](2);
    _allowedStates[0] = _allowedStateA;
    _allowedStates[1] = _allowedStateB;
    _expectRevertUnexpectedState(_proposalId, _currentState, _allowedStates);
  }
}

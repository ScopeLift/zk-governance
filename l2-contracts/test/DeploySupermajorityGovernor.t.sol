// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {ZkProtocolGovernor} from "src/ZkProtocolGovernor.sol";
import {DeploySupermajorityGovernorEraMainnet} from "script/DeploySupermajorityGovernorEraMainnet.s.sol";
import {ZkProtocolUpgradeEraMainnetConfig} from "council/script/configs/ZkProtocolUpgradeEraMainnetConfig.sol";
import {ERC20VotesFake} from "test/fakes/ERC20VotesFake.sol";
import {DeploySupermajorityGovernorEraMainnetHarness} from "test/harnesses/DeploySupermajorityGovernorHarness.sol";
import {Constants} from "test/utils/Constants.sol";

interface IZkCheatcodes {
  function zkVmSkip() external;
}

/// @notice Stands in for the Veto Governor's `overrideVeto`, recording who called it.
contract VetoOverrideTarget {
  address public caller;
  uint256 public overriddenProposalId;

  function overrideVeto(uint256 _proposalId) external {
    caller = msg.sender;
    overriddenProposalId = _proposalId;
  }
}

/// @notice Runs the Era mainnet deployment with a test token in place of the ZK token.
/// @dev The script is deployed behind `zkVmSkip`, so under `--zksync` it lands in the EVM, where its cheatcodes work,
/// as `forge script --zksync` runs it.
contract DeploySupermajorityGovernorTest is Test, ZkProtocolUpgradeEraMainnetConfig {
  uint256 constant QUORUM = 1_260_000_000e18;
  uint256 constant OVERRIDE_TIMELOCK_MIN_DELAY = 1 days;

  // Voting in the end-to-end test needs a token with code, so the mainnet ZK token is replaced by a fake.
  ERC20VotesFake token;

  function setUp() public virtual {
    token = new ERC20VotesFake();
  }

  // The mainnet params with the test token as the ZK token.
  function _deploymentParamsWithTestToken() internal view returns (DeploymentParams memory _params) {
    _params = _deploymentParams();
    _params.zkToken = address(token);
  }

  // Deploys the script in the EVM rather than EraVM, as `forge script --zksync` runs it. Under `--zksync` a plain `new`
  // would deploy the script to EraVM, which has no cheatcodes.
  function _deployScript(DeploymentParams memory _params)
    internal
    returns (DeploySupermajorityGovernorEraMainnetHarness _script)
  {
    IZkCheatcodes(address(vm)).zkVmSkip();
    _script = new DeploySupermajorityGovernorEraMainnetHarness(_params);
    _script.disableLogging();
  }

  // Deploys and runs the script with the mainnet params and the test token.
  function _runScript() internal returns (DeploySupermajorityGovernorEraMainnetHarness _script) {
    _script = _deployScript(_deploymentParamsWithTestToken());
    _script.run();
  }
}

contract Run is DeploySupermajorityGovernorTest {
  function test_DeploysTheGovernorWithTheZipParameters() public {
    DeploySupermajorityGovernorEraMainnetHarness _script = _runScript();
    ZkProtocolGovernor _governor = _script.governor();

    assertEq(_governor.name(), "ZKsync Supermajority Governor");
    assertEq(address(_governor.token()), address(token));
    assertEq(address(_governor.timelock()), address(_script.timelock()));
    assertEq(_governor.votingDelay(), 1 days);
    assertEq(_governor.votingPeriod(), 7 days);
    assertEq(_governor.proposalThreshold(), 21_000_000e18);
    assertEq(_governor.quorum(block.timestamp), QUORUM);
    assertEq(_governor.lateQuorumVoteExtension(), 3 days);
  }

  function test_ConfiguresTheOverrideTimelock() public {
    DeploySupermajorityGovernorEraMainnetHarness _script = _runScript();
    TimelockController _timelock = _script.timelock();
    address _governor = address(_script.governor());

    assertEq(_timelock.getMinDelay(), OVERRIDE_TIMELOCK_MIN_DELAY);
    assertTrue(_timelock.hasRole(_timelock.PROPOSER_ROLE(), _governor));
    assertTrue(_timelock.hasRole(_timelock.CANCELLER_ROLE(), _governor));
    assertTrue(_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0)));
    assertTrue(_timelock.hasRole(_timelock.TIMELOCK_ADMIN_ROLE(), address(_timelock)));
  }

  function test_LeavesTheDeployerNoTimelockRole() public {
    TimelockController _timelock = _runScript().timelock();

    assertFalse(_timelock.hasRole(_timelock.TIMELOCK_ADMIN_ROLE(), DEFAULT_SENDER));
    assertFalse(_timelock.hasRole(_timelock.PROPOSER_ROLE(), DEFAULT_SENDER));
    assertFalse(_timelock.hasRole(_timelock.CANCELLER_ROLE(), DEFAULT_SENDER));
    assertFalse(_timelock.hasRole(_timelock.EXECUTOR_ROLE(), DEFAULT_SENDER));
  }

  function test_PassedProposalCallsOverrideVetoThroughTheOverrideTimelock() public {
    DeploySupermajorityGovernorEraMainnetHarness _script = _runScript();
    ZkProtocolGovernor _governor = _script.governor();
    VetoOverrideTarget _target = new VetoOverrideTarget();
    address _voter = makeAddr("Voter");
    token.mint(_voter, QUORUM);
    vm.prank(_voter);
    token.delegate(_voter);
    vm.warp(block.timestamp + 1);

    address[] memory _targets = new address[](1);
    _targets[0] = address(_target);
    uint256[] memory _values = new uint256[](1);
    bytes[] memory _calldatas = new bytes[](1);
    _calldatas[0] = abi.encodeCall(VetoOverrideTarget.overrideVeto, (42));
    string memory _description = "Override the veto on proposal 42";

    vm.prank(_voter);
    uint256 _proposalId = _governor.propose(_targets, _values, _calldatas, _description);
    vm.warp(_governor.proposalSnapshot(_proposalId) + 1);
    vm.prank(_voter);
    _governor.castVote(_proposalId, 1);
    vm.warp(_governor.proposalDeadline(_proposalId) + 1);
    assertEq(uint8(_governor.state(_proposalId)), uint8(IGovernor.ProposalState.Succeeded));

    bytes32 _descriptionHash = keccak256(bytes(_description));
    _governor.queue(_targets, _values, _calldatas, _descriptionHash);
    vm.warp(block.timestamp + OVERRIDE_TIMELOCK_MIN_DELAY);
    _governor.execute(_targets, _values, _calldatas, _descriptionHash);

    assertEq(_target.caller(), address(_script.timelock()));
    assertEq(_target.overriddenProposalId(), 42);
  }

  function test_RevertIf_TheZkTokenHasNoCode() public {
    DeploymentParams memory _params = _deploymentParamsWithTestToken();
    _params.zkToken = makeAddr("Account Without Code");
    DeploySupermajorityGovernorEraMainnetHarness _script = _deployScript(_params);

    vm.expectRevert("SupermajorityGovernorChecks: zkToken has no code; set it to the ZK token");
    _script.run();
  }

  function testFuzz_RevertIf_TheVetoOverrideWindowIsShorterThanASupermajorityOverride(uint256 _duration) public {
    DeploymentParams memory _params = _deploymentParamsWithTestToken();
    // The window must be strictly longer than a supermajority override, so its length is already too short.
    uint256 _longestOverride = uint256(_params.supermajorityGovernorVotingDelay)
      + _params.supermajorityGovernorVotingPeriod + _params.supermajorityGovernorLateQuorumVoteExtension
      + _params.overrideTimelockMinDelay;
    _params.vetoGovernorVetoOverrideDuration = uint48(_bound(_duration, 0, _longestOverride));
    DeploySupermajorityGovernorEraMainnetHarness _script = _deployScript(_params);

    vm.expectRevert(
      "SupermajorityGovernorChecks: vetoGovernorVetoOverrideDuration is too short for a supermajority override"
    );
    _script.run();
  }
}

contract Check is DeploySupermajorityGovernorTest {
  function test_PassesForTheDeploymentRunMade() public {
    DeploySupermajorityGovernorEraMainnetHarness _script = _runScript();
    vm.setEnv("SUPERMAJORITY_GOVERNOR", vm.toString(address(_script.governor())));
    vm.setEnv("OVERRIDE_TIMELOCK", vm.toString(address(_script.timelock())));
    vm.setEnv("DEPLOYER", vm.toString(DEFAULT_SENDER));

    _script.check();
  }
}

// EraVM's system contract that stores each deployed contract's code hash.
interface IAccountCodeStorage {
  function getRawCodeHash(address _address) external view returns (bytes32);
}

/// @notice Runs the Era mainnet deployment unchanged on a fork of Era mainnet, against the live ZK token. The council
/// smoke tests cannot run this script, so they deploy the same contracts from this project's `zkout` with the script's
/// calls; these tests show the script itself deploys that bytecode and that the governor it deploys works with the live
/// token.
contract RunOnEraMainnet is Test, Constants, ZkProtocolUpgradeEraMainnetConfig {
  IAccountCodeStorage constant ACCOUNT_CODE_STORAGE = IAccountCodeStorage(0x0000000000000000000000000000000000008002);

  DeploySupermajorityGovernorEraMainnet script;

  function setUp() public {
    vm.createSelectFork(vm.envOr("ZKSYNC_RPC_URL", ZKSYNC_RPC_URL), ERA_MAINNET_FORK_BLOCK);
    // The default sender pays the fees of the EraVM transactions the script broadcasts.
    vm.deal(DEFAULT_SENDER, 1 ether);
    // Deployed in the EVM, as `forge script --zksync` runs it; the contracts it deploys still land in EraVM.
    IZkCheatcodes(address(vm)).zkVmSkip();
    script = new DeploySupermajorityGovernorEraMainnet();
    script.disableLogging();
    script.run();
  }

  // The council smoke tests deploy from these artifacts and check their deployments against the same hashes.
  function test_DeploysTheEraVmBytecodeInThisProjectsBuild() public {
    assertEq(
      ACCOUNT_CODE_STORAGE.getRawCodeHash(address(script.governor())),
      _eraVmBytecodeHash("zkout/ZkProtocolGovernor.sol/ZkProtocolGovernor.json")
    );
    assertEq(
      ACCOUNT_CODE_STORAGE.getRawCodeHash(address(script.timelock())),
      _eraVmBytecodeHash("zkout/TimelockController.sol/TimelockController.json")
    );
  }

  function test_GovernorCountsVotesOfTheLiveZkTokenByTimestamp() public {
    ZkProtocolGovernor _governor = script.governor();

    assertEq(address(_governor.token()), _deploymentParams().zkToken);
    assertEq(_governor.CLOCK_MODE(), "mode=timestamp");
    assertEq(_governor.clock(), block.timestamp);
  }

  function test_PassedProposalWithLiveZkVotesCallsOverrideVetoThroughTheOverrideTimelock() public {
    ZkProtocolGovernor _governor = script.governor();
    VetoOverrideTarget _target = new VetoOverrideTarget();
    address _voter = makeAddr("Voter");
    _dealAndDelegateZk(_voter, SUPERMAJORITY_QUORUM);
    vm.warp(block.timestamp + 1);

    address[] memory _targets = new address[](1);
    _targets[0] = address(_target);
    uint256[] memory _values = new uint256[](1);
    bytes[] memory _calldatas = new bytes[](1);
    _calldatas[0] = abi.encodeCall(VetoOverrideTarget.overrideVeto, (42));
    string memory _description = "Override the veto on proposal 42";

    vm.prank(_voter);
    uint256 _proposalId = _governor.propose(_targets, _values, _calldatas, _description);
    vm.warp(_governor.proposalSnapshot(_proposalId) + 1);
    vm.prank(_voter);
    _governor.castVote(_proposalId, 1);
    vm.warp(_governor.proposalDeadline(_proposalId) + 1);
    bytes32 _descriptionHash = keccak256(bytes(_description));
    _governor.queue(_targets, _values, _calldatas, _descriptionHash);
    vm.warp(block.timestamp + _deploymentParams().overrideTimelockMinDelay);
    _governor.execute(_targets, _values, _calldatas, _descriptionHash);

    assertEq(_target.caller(), address(script.timelock()));
    assertEq(_target.overriddenProposalId(), 42);
  }

  // The EraVM bytecode hash zksolc recorded in an artifact of this project, which is the code hash of every contract
  // deployed from it.
  function _eraVmBytecodeHash(string memory _artifact) internal view returns (bytes32) {
    // zksolc writes the hash without a `0x` prefix.
    return vm.parseBytes32(string.concat("0x", vm.parseJsonString(vm.readFile(_artifact), ".hash")));
  }

  // Sets `_holder`'s ZK balance to `_amount` and delegates it to `_holder`; the votes count from the next second.
  function _dealAndDelegateZk(address _holder, uint256 _amount) internal {
    IVotes _zkToken = IVotes(_deploymentParams().zkToken);
    deal(address(_zkToken), _holder, _amount);
    vm.prank(_holder);
    _zkToken.delegate(_holder);
    // `deal` writes the balance directly, and delegating to the account already delegated to moves no votes, so a
    // holder that delegated before would keep its old votes.
    require(_zkToken.getVotes(_holder) == _amount, "_dealAndDelegateZk: the holder's votes do not match its balance");
  }
}

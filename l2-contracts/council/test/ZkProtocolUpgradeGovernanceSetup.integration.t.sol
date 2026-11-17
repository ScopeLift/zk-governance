// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ZkProtocolUpgradeGovernanceTest} from "test/helpers/ZkProtocolUpgradeGovernanceTest.sol";
import {
  ZkProtocolUpgradeGovernanceEraMainnetScript
} from "test/helpers/ZkProtocolUpgradeGovernanceEraMainnetScript.sol";

// EraVM's system contract that stores each deployed contract's code hash.
interface IAccountCodeStorage {
  function getRawCodeHash(address _address) external view returns (bytes32);
}

/// @notice Checks the system the smoke tests start from: the council governance and the Supermajority Governor deployed
/// on EraVM and wired together, and the Protocol Timelock roles moved from `ZkProtocolGovernor` to the Veto Governor.
abstract contract ZkProtocolUpgradeGovernanceSetupTest is ZkProtocolUpgradeGovernanceTest {
  IAccountCodeStorage constant ACCOUNT_CODE_STORAGE = IAccountCodeStorage(0x0000000000000000000000000000000000008002);

  function test_VetoGovernorHoldsTheProtocolTimelockRolesZkProtocolGovernorGaveUp() public view {
    assertTrue(protocolTimelock.hasRole(PROPOSER_ROLE, address(vetoGovernor)));
    assertTrue(protocolTimelock.hasRole(EXECUTOR_ROLE, address(vetoGovernor)));
    assertTrue(protocolTimelock.hasRole(CANCELLER_ROLE, address(vetoGovernor)));
    assertFalse(protocolTimelock.hasRole(PROPOSER_ROLE, address(protocolGovernor)));
    assertFalse(protocolTimelock.hasRole(EXECUTOR_ROLE, address(protocolGovernor)));
    assertFalse(protocolTimelock.hasRole(CANCELLER_ROLE, address(protocolGovernor)));
  }

  function test_SupermajorityGovernorAndOverrideTimelockRunTheMainProjectsEraVmBytecode() public view {
    assertEq(
      ACCOUNT_CODE_STORAGE.getRawCodeHash(address(supermajorityGovernor)),
      _mainProjectEraVmBytecodeHash(SUPERMAJORITY_GOVERNOR_ARTIFACT)
    );
    assertEq(
      ACCOUNT_CODE_STORAGE.getRawCodeHash(address(overrideTimelock)),
      _mainProjectEraVmBytecodeHash(OVERRIDE_TIMELOCK_ARTIFACT)
    );
  }

  function test_SupermajorityGovernorIsTheOnlyProposerOnTheOverrideTimelockThatHoldsTheVetoOverrideRole() public view {
    assertEq(vetoGovernor.vetoOverrideRole(), address(overrideTimelock));
    assertTrue(overrideTimelock.hasRole(PROPOSER_ROLE, address(supermajorityGovernor)));
    assertTrue(overrideTimelock.hasRole(CANCELLER_ROLE, address(supermajorityGovernor)));
    assertFalse(overrideTimelock.hasRole(PROPOSER_ROLE, DEFAULT_SENDER));
    // The zero address would open the role to every account.
    assertFalse(overrideTimelock.hasRole(PROPOSER_ROLE, address(0)));
    assertFalse(overrideTimelock.hasRole(TIMELOCK_ADMIN_ROLE, DEFAULT_SENDER));
  }

  function test_CouncilProposalPassedWithTheSharedStepsCallsTheTargetFromTheProtocolTimelock() public {
    Proposal memory _proposal = _protocolUpgradeProposal();

    uint256 _proposalId = _passCouncilProposal(_proposal);
    _warpPastVetoDeadline(_proposalId);
    _queueOnProtocolTimelock(_proposal);
    _executeThroughCouncil(_proposal);

    _assertUpgradeExecutedByProtocolTimelock(_proposal);
    _assertStates(_proposalId, IGovernor.ProposalState.Executed, IGovernor.ProposalState.Executed);
  }
}

contract ZkProtocolUpgradeGovernanceSetupEraMainnetScript is
  ZkProtocolUpgradeGovernanceSetupTest,
  ZkProtocolUpgradeGovernanceEraMainnetScript
{}

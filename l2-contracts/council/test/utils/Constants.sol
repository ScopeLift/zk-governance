// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract Constants {
  uint256 constant VOTES_PER_SEAT = 1e18;
  uint256 constant MAX_MEMBER_COUNT = 20;
  uint48 constant VOTING_DELAY = 1 days;
  uint32 constant VOTING_PERIOD = 3 days;
  uint256 constant MAX_VETO_THRESHOLD = 1e30;
  uint48 constant VOTING_PERIOD_EXTENSION = 2 days;
  uint16 constant VOTING_PERIOD_EXTENSION_THRESHOLD_PCT = 50;

  string constant PROPOSAL_DESCRIPTION = "A protocol upgrade";

  /// @notice An Era mainnet block before the Protocol Timelock role migration, while `ZkProtocolGovernor` holds the
  /// Protocol Timelock roles. The smoke tests deploy the council governance and run the migration on a fork of it.
  uint256 constant ERA_MAINNET_FORK_BLOCK = 72_650_000;
  uint256 constant ERA_MAINNET_CHAIN_ID = 324;

  /// @notice The main l2-contracts project's build output, relative to this project. The smoke tests deploy the
  /// OpenZeppelin v4 contracts that project builds, which this project cannot compile, from its artifacts: EVM ones in
  /// `out` and EraVM ones in `zkout`. Run `forge build src/ZkProtocolGovernor.sol` and
  /// `forge build --zksync src/ZkProtocolGovernor.sol` in `l2-contracts` first, since the `--zksync` build writes only
  /// `zkout`.
  string constant MAIN_PROJECT_EVM_ARTIFACTS = "../out/";
  string constant MAIN_PROJECT_ERAVM_ARTIFACTS = "../zkout/";

  /// @notice The main project's artifacts of the contracts `DeploySupermajorityGovernor` deploys, relative to its
  /// artifact directories.
  string constant OVERRIDE_TIMELOCK_ARTIFACT = "TimelockController.sol/TimelockController.json";
  string constant SUPERMAJORITY_GOVERNOR_ARTIFACT = "ZkProtocolGovernor.sol/ZkProtocolGovernor.json";

  /// @notice EraVM's system contract that marks bytecode hashes as known, which a contract's bytecode must be before
  /// EraVM deploys it.
  address constant KNOWN_CODES_STORAGE = 0x0000000000000000000000000000000000008004;
}

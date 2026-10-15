// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ZkProtocolUpgradeDeploymentConfig
/// @author [ScopeLift](https://scopelift.co)
/// @notice ZIP parameters for the ZKsync protocol upgrade council governance contracts on ZKsync Era mainnet. Shared by
/// the deploy script and the post-deploy check script, so both use a single source of truth.
/// @dev All durations are in seconds, since the ZK token and `CouncilERC20` both use a timestamp clock. All token
/// amounts are in ZK base units (18 decimals).
abstract contract ZkProtocolUpgradeDeploymentConfig {
  /*///////////////////////////////////////////////////////////////
                          Existing contracts
  //////////////////////////////////////////////////////////////*/

  /// @notice The ZK token on ZKsync Era.
  address internal constant ZK_TOKEN = 0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E;

  /// @notice The Protocol Timelock on ZKsync Era, which the Veto Governor queues and executes proposals through.
  address internal constant PROTOCOL_TIMELOCK = 0x085b8B6407f150D62adB1EF926F7f304600ec714;

  /// @notice The ProtocolUpgradeHandler on Ethereum mainnet.
  address internal constant L1_PROTOCOL_UPGRADE_HANDLER = 0xE30Dca3047B37dc7d88849dE4A4Dc07937ad5Ab3;

  /// @notice The L1-to-L2 aliased address of the ProtocolUpgradeHandler. It administers the Council Governor, the Veto
  /// Governor and `CouncilERC20`.
  address internal constant GOVERNANCE_ADMIN = 0xF41EcA3047B37dc7d88849de4a4dc07937Ad6bc4;

  /// @notice The offset ZKsync adds to an L1 contract's address when it sends an L1-to-L2 transaction.
  uint160 internal constant L1_TO_L2_ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);

  /*///////////////////////////////////////////////////////////////
                              CouncilERC20
  //////////////////////////////////////////////////////////////*/

  string internal constant COUNCIL_TOKEN_NAME = "ZKsync Protocol Upgrade Council Seat";
  string internal constant COUNCIL_TOKEN_SYMBOL = "ZKPUC";

  /// @notice The seat size. Each member is minted exactly one seat, which is also the per-member maximum.
  uint256 internal constant COUNCIL_SEAT = 1e18;

  /*///////////////////////////////////////////////////////////////
                    ZkProtocolUpgradeCouncilGovernor
  //////////////////////////////////////////////////////////////*/

  string internal constant COUNCIL_GOVERNOR_NAME = "ZKsync Protocol Upgrade Council";
  uint48 internal constant COUNCIL_GOVERNOR_VOTING_DELAY = 1 days;
  uint32 internal constant COUNCIL_GOVERNOR_VOTING_PERIOD = 3 days;
  uint256 internal constant COUNCIL_GOVERNOR_PROPOSAL_THRESHOLD = 1e18;

  /// @notice Quorum and super-quorum as a percentage of seats. 12% of eight seats is less than one seat, so a single
  /// FOR vote meets both.
  uint256 internal constant COUNCIL_GOVERNOR_QUORUM_FRACTION = 12;
  uint256 internal constant COUNCIL_GOVERNOR_SUPER_QUORUM_FRACTION = 12;

  /*///////////////////////////////////////////////////////////////
                      ZkProtocolUpgradeVetoGovernor
  //////////////////////////////////////////////////////////////*/

  string internal constant VETO_GOVERNOR_NAME = "ZKsync Protocol Upgrade Veto Governor";
  uint48 internal constant VETO_GOVERNOR_VOTING_DELAY = 1 days;
  uint32 internal constant VETO_GOVERNOR_VOTING_PERIOD = 7 days;

  /// @notice Zero, since only the Council Governor can propose to the Veto Governor.
  uint256 internal constant VETO_GOVERNOR_PROPOSAL_THRESHOLD = 0;

  uint256 internal constant VETO_GOVERNOR_VETO_THRESHOLD = 630_000_000e18;

  /// @notice The voting period is extended by this much once AGAINST votes reach the extension threshold.
  uint48 internal constant VETO_GOVERNOR_VOTING_PERIOD_EXTENSION = 2 days;

  /// @notice The extension threshold as a percentage of the veto threshold: 50% of 630M is 315M ZK.
  uint16 internal constant VETO_GOVERNOR_EXTENSION_THRESHOLD_PCT = 50;

  address internal constant VETO_GOVERNOR_VETO_GUARDIAN = 0xF197677d63BF6E2841F5108b8dFd2FD6eCEff74B;
  uint48 internal constant VETO_GOVERNOR_VETO_OVERRIDE_DURATION = 14 days;

  /*///////////////////////////////////////////////////////////////
                  ZkSupermajorityGovernor and override timelock
  //////////////////////////////////////////////////////////////*/

  string internal constant SUPERMAJORITY_GOVERNOR_NAME = "ZKsync Supermajority Governor";
  uint48 internal constant SUPERMAJORITY_GOVERNOR_VOTING_DELAY = 1 days;
  uint32 internal constant SUPERMAJORITY_GOVERNOR_VOTING_PERIOD = 7 days;
  uint256 internal constant SUPERMAJORITY_GOVERNOR_PROPOSAL_THRESHOLD = 21_000_000e18;
  uint256 internal constant SUPERMAJORITY_GOVERNOR_QUORUM = 1_260_000_000e18;
  uint48 internal constant SUPERMAJORITY_GOVERNOR_LATE_QUORUM_EXTENSION = 3 days;

  uint256 internal constant OVERRIDE_TIMELOCK_MIN_DELAY = 1 days;

  /*///////////////////////////////////////////////////////////////
                              Functions
  //////////////////////////////////////////////////////////////*/

  /// @notice The eight council members, each minted one seat.
  function _councilMembers() internal pure returns (address[] memory _members) {
    _members = new address[](8);
    _members[0] = 0xe38dc029623f0af56BdC46E5318610E257d6b760; // Matter Labs
    _members[1] = 0x870Ec9631E28ee6C8b304e238E9b6890a99ab8aA; // Nethermind
    _members[2] = 0x305798C076B64Be35Aa6367C6632b79e29D0113A; // OpenZeppelin
    _members[3] = 0x356cF4Ac9fA86F0a9dDdc62e48082FE5Cd14bE7b; // Spearbit
    _members[4] = 0x3043bF9c9A512d20Dda2c2b2C3D69AF6f7Fcd5B1; // Chainlight
    _members[5] = 0x9BC8d216d63b38c390e465D664FEb63B67659c13; // Cyfrin
    _members[6] = 0xdbc2E250cBA867D6619Bed342Ca3Eca7b71e8b82; // Dedaub
    _members[7] = 0x46fc9a8A72456c84F42c5c9e5df46984c0078B15; // Peckshield
  }

  /// @notice Returns the address ZKsync uses as the sender of L1-to-L2 transactions sent by an L1 contract.
  /// @param _l1Address The L1 contract address.
  function _applyL1ToL2Alias(address _l1Address) internal pure returns (address) {
    unchecked {
      return address(uint160(_l1Address) + L1_TO_L2_ALIAS_OFFSET);
    }
  }
}

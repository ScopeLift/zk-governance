// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Stands in for a contract that a protocol upgrade proposal calls, recording every call it receives, so a test
/// can tell whether the proposal ran and from which account.
contract ProtocolUpgradeTarget {
  /// @notice The account that made the most recent call to `upgrade`, or zero if there has been none.
  address public lastCaller;

  /// @notice The number of calls to `upgrade`.
  uint256 public upgradeCount;

  /// @notice Records the call.
  function upgrade() external {
    lastCaller = msg.sender;
    upgradeCount += 1;
  }
}

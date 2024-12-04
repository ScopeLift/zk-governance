// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IMintableAndDelegatable} from "src/interfaces/IMintableAndDelegatable.sol";

/// @title ZkCappedMinterV2
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract to allow a permissioned entity to mint ZK tokens up to a given amount (the cap).
/// @custom:security-contact security@zksync.io
contract ZkCappedMinterV2 is AccessControl, Pausable {
  /// @notice The contract where the tokens will be minted by an authorized minter.
  IMintableAndDelegatable public immutable TOKEN;

  /// @notice The maximum number of tokens that may be minted by the ZkCappedMinter.
  uint256 public immutable CAP;

  /// @notice The cumulative number of tokens that have been minted by the ZkCappedMinter.
  uint256 public minted = 0;

  /// @notice Error for when the cap is exceeded.
  error ZkCappedMinterV2__CapExceeded(address minter, uint256 amount);

  /// @notice Error for when the account is unauthorized.
  error ZkCappedMinterV2__Unauthorized(address account);

  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  /// @notice Constructor for a new ZkCappedMinter contract
  /// @param _token The token contract where tokens will be minted.
  /// @param _admin The address that will be granted the admin role.
  /// @param _cap The maximum number of tokens that may be minted by the ZkCappedMinter.
  constructor(IMintableAndDelegatable _token, address _admin, uint256 _cap) {
    TOKEN = _token;
    CAP = _cap;

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    _grantRole(PAUSER_ROLE, _admin);
  }

  /// @notice Pauses token minting
  function pause() external {
    if (!hasRole(PAUSER_ROLE, msg.sender)) {
      revert ZkCappedMinterV2__Unauthorized(msg.sender);
    }
    _pause();
  }

  /// @notice Unpauses token minting
  function unpause() external {
    if (!hasRole(PAUSER_ROLE, msg.sender)) {
      revert ZkCappedMinterV2__Unauthorized(msg.sender);
    }
    _unpause();
  }

  /// @notice Mints a given amount of tokens to a given address, so long as the cap is not exceeded.
  /// @param _to The address that will receive the new tokens.
  /// @param _amount The quantity of tokens, in raw decimals, that will be created.
  function mint(address _to, uint256 _amount) external {
    _requireNotPaused();
    _revertIfUnauthorized();
    _revertIfCapExceeded(_amount);
    minted += _amount;
    TOKEN.mint(_to, _amount);
  }

  /// @notice Reverts if the account is unauthorized.
  function _revertIfUnauthorized() internal view {
    if (!hasRole(MINTER_ROLE, msg.sender)) {
      revert ZkCappedMinterV2__Unauthorized(msg.sender);
    }
  }

  /// @notice Reverts if the amount of new tokens will increase the minted tokens beyond the mint cap.
  /// @param _amount The quantity of tokens, in raw decimals, that will checked against the cap.
  function _revertIfCapExceeded(uint256 _amount) internal view {
    if (minted + _amount > CAP) {
      revert ZkCappedMinterV2__CapExceeded(msg.sender, _amount);
    }
  }
}

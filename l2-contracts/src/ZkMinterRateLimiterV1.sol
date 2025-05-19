// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMintable} from "src/interfaces/IMintable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/// @title ZkMinterRateLimiterV1
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that implements rate limiting for token minting, allowing authorized minters to collectively mint
/// up to a specified amount within a configurable time period.
/// @custom:security-contact security@matterlabs.dev

contract ZkMinterRateLimiterV1 is IMintable, AccessControl, Pausable {
  /// @notice The contract where the tokens will be minted by an authorized minter.
  IMintable public mintable;

  /// @notice The maximum number of tokens that may be minted by the minter in a single mint rate limit window.
  uint256 public mintRateLimit;

  /// @notice The number of seconds in a mint rate limit window.
  uint48 public mintRateLimitWindow;

  /// @notice The role identifier for addresses that are authorized to mint tokens.
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  /// @notice Initializes the rate limiter with the mintable contract, admin, mint rate limit, and mint rate limit
  /// window.
  /// @param _mintable A contract used as a target when calling mint. Any contract that conforms to the IMintable
  /// interface can be used, but in most cases this will be another `ZKMinter` extension or `ZKCappedMinter`.
  /// @param _admin The address that will have admin privileges.
  /// @param _mintRateLimit The maximum number of tokens that can be minted during the rate limit window.
  /// @param _mintRateLimitWindow The duration of the rate limit window in seconds.
  constructor(IMintable _mintable, address _admin, uint256 _mintRateLimit, uint48 _mintRateLimitWindow) {
    mintable = _mintable;
    mintRateLimit = _mintRateLimit;
    mintRateLimitWindow = _mintRateLimitWindow;

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  /// @notice Mints a given amount of tokens to a given address, so long as the rate limit is not exceeded.
  /// @param _to The address that will receive the new tokens.
  /// @param _amount The quantity of tokens that will be minted.
  function mint(address _to, uint256 _amount) external {
    _checkRole(MINTER_ROLE, msg.sender);
    mintable.mint(_to, _amount);
  }
}

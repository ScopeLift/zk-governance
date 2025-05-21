// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMintable} from "src/interfaces/IMintable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {console2} from "forge-std/console2.sol";
/// @title ZkMinterRateLimiterV1
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that implements rate limiting for token minting, allowing authorized minters to collectively mint
/// up to a specified amount within a configurable time period.
/// @custom:security-contact security@matterlabs.dev

contract ZkMinterRateLimiterV1 is IMintable, AccessControl, Pausable {
  /// @notice The contract where the tokens will be minted by an authorized minter.
  IMintable public mintable;

  /// @notice The number of tokens minted in each mint window.
  mapping(uint48 mintWindowStart => uint256 mintedAmount) public mintedInWindow;

  /// @notice The maximum number of tokens that may be minted by the minter in a single mint rate limit window.
  uint256 public mintRateLimit;

  /// @notice The number of seconds in a mint rate limit window.
  uint48 public mintRateLimitWindow;

  /// @notice The timestamp when minting can begin.
  uint48 public immutable START_TIME;

  /// @notice The unique identifier constant used to represent the minter role. An address that has this role may call
  /// the `mint` method, creating new tokens and assigning them to specified address. This role may be granted or
  /// revoked by the DEFAULT_ADMIN_ROLE.
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  /// @notice Emitted when tokens are minted.
  event Minted(address indexed minter, address indexed to, uint256 amount);

  /// @notice Error for when the rate limit per mint window is exceeded.
  error ZkMinterRateLimiterV1__MintRateLimitExceeded(address minter, uint256 amount);

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
    START_TIME = uint48(block.timestamp);

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  /// @notice Mints a given amount of tokens to a given address, so long as the rate limit is not exceeded.
  /// @param _to The address that will receive the new tokens.
  /// @param _amount The quantity of tokens that will be minted.
  function mint(address _to, uint256 _amount) external {
    _checkRole(MINTER_ROLE, msg.sender);
    uint48 _currentMintWindowStart = currentMintWindowStart();
    _revertIfRateLimitPerMintWindowExceeded(_currentMintWindowStart, _amount);

    mintedInWindow[_currentMintWindowStart] += _amount;
    mintable.mint(_to, _amount);
    emit Minted(msg.sender, _to, _amount);
  }

  /// @notice Calculates the start timestamp of the current mint window.
  /// @return The timestamp marking the start of the current mint window.
  function currentMintWindowStart() public view returns (uint48) {
    return uint48(block.timestamp - (block.timestamp - START_TIME) % mintRateLimitWindow);
  }

  /// @notice Calculates how many tokens are still available to mint in a given window.
  /// @param _windowStart The timestamp marking the start of the window.
  /// @return The number of tokens that can still be minted in the given window.
  function _amountAvailableForMintInWindow(uint48 _windowStart) internal view returns (uint256) {
    return mintRateLimit - mintedInWindow[_windowStart];
  }

  /// @notice Reverts if the rate limit per mint window is exceeded.
  /// @param _windowStart The timestamp marking the start of the window.
  /// @param _amount The amount of tokens that will be minted.
  function _revertIfRateLimitPerMintWindowExceeded(uint48 _windowStart, uint256 _amount) internal view {
    if (_amount > _amountAvailableForMintInWindow(_windowStart)) {
      revert ZkMinterRateLimiterV1__MintRateLimitExceeded(msg.sender, _amount);
    }
  }
}

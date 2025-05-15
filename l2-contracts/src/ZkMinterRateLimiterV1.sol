// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IMintable} from "src/interfaces/IMintable.sol";
import {ZkCappedMinterV2} from "src/ZkCappedMinterV2.sol";

/// @title ZkMinterRateLimiterV1
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that implements rate limiting for token minting, allowing authorized minters to collectively mint
/// up to a specified amount within configurable time periods.
/// @custom:security-contact security@matterlabs.dev
contract ZkMinterRateLimiterV1 is IMintable, AccessControl, Pausable {
  /// @notice The contract where the tokens will be minted by an authorized minter.
  ZkCappedMinterV2 public zkCappedMinter;

  /// @notice The number of tokens minted in each mint period.
  mapping(uint48 mintPeriodStart => uint256 mintedAmount) public mintedInPeriod;

  /// @notice The maximum number of tokens that may be minted by the minter in a single mint period.
  uint256 public capPerMintPeriod;

  /// @notice The number of seconds in a mint period.
  uint48 public mintPeriod;

  /// @notice The timestamp when minting can begin.
  uint48 public immutable START_TIME;

  /// @notice The role that allows minters to mint tokens.
  bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

  /// @notice Emitted when tokens are minted.
  event Minted(address indexed minter, address indexed to, uint256 amount);

  /// @notice Error for when the cap per mint period is exceeded.
  error ZkMinterRateLimiterV1__CapPerMintPeriodExceeded(address minter, uint256 amount);

  /// @notice Constructor for a new ZkMinterRateLimiterV1 contract.
  /// @param _zkCappedMinter The ZkCappedMinterV2 contract that will handle the actual minting.
  /// @param _admin The address that will be granted the admin role.
  /// @param _capPerMintPeriod The maximum number of tokens that may be minted in a single mint period.
  /// @param _mintPeriod The number of seconds in a mint period.
  constructor(ZkCappedMinterV2 _zkCappedMinter, address _admin, uint256 _capPerMintPeriod, uint48 _mintPeriod) {
    zkCappedMinter = _zkCappedMinter;
    capPerMintPeriod = _capPerMintPeriod;
    mintPeriod = _mintPeriod;
    START_TIME = uint48(block.timestamp);

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  /// @notice Mints a given amount of tokens to a given address, so long as the rate limit is not exceeded.
  /// @param _to The address that will receive the new tokens.
  /// @param _amount The quantity of tokens that will be minted.
  function mint(address _to, uint256 _amount) external {
    _checkRole(MINTER_ROLE, msg.sender);
    uint48 _currentPeriodStart = currentMintPeriodStart();
    _revertIfCapPerMintPeriodExceeded(_currentPeriodStart, _amount);

    mintedInPeriod[_currentPeriodStart] += _amount;
    zkCappedMinter.mint(_to, _amount);
    emit Minted(msg.sender, _to, _amount);
  }

  /// @notice Calculates the start timestamp of the current mint period.
  /// @return The timestamp marking the start of the current mint period.
  function currentMintPeriodStart() public view returns (uint48) {
    return uint48(block.timestamp - (block.timestamp - START_TIME) % mintPeriod);
  }

  /// @notice Calculates how many tokens are still available to mint in a given period.
  /// @param _periodStart The timestamp marking the start of the period.
  /// @return The number of tokens that can still be minted in the given period.
  function _amountAvailableForMintInPeriod(uint48 _periodStart) internal view returns (uint256) {
    return capPerMintPeriod - mintedInPeriod[_periodStart];
  }

  /// @notice Reverts if the cap per mint period is exceeded.
  /// @param _periodStart The timestamp marking the start of the period.
  /// @param _amount The amount of tokens that will be minted.
  function _revertIfCapPerMintPeriodExceeded(uint48 _periodStart, uint256 _amount) internal view {
    if (_amount > _amountAvailableForMintInPeriod(_periodStart)) {
      revert ZkMinterRateLimiterV1__CapPerMintPeriodExceeded(msg.sender, _amount);
    }
  }
}

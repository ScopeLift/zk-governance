// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IMintable} from "src/interfaces/IMintable.sol";

/// @title ZkMinterRateLimiterV1
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that implements rate limiting for token minting, allowing authorized minters to collectively mint
/// up to a specified amount within configurable time periods.
/// @custom:security-contact security@matterlabs.dev
contract ZkMinterRateLimiterV1 is IMintable, AccessControl, Pausable {
  /// @notice The contract where the tokens will be minted by an authorized minter.
  IMintable public mintable;

  /// @notice The maximum number of tokens that may be minted by the minter in a single mint period.
  uint256 public capPerMintPeriod;

  /// @notice The number of seconds in a mint period.
  uint48 public mintPeriod;

  constructor(IMintable _mintable, address _admin, uint256 _capPerMintPeriod, uint48 _mintPeriod) {
    mintable = _mintable;
    capPerMintPeriod = _capPerMintPeriod;
    mintPeriod = _mintPeriod;

    _grantRole(DEFAULT_ADMIN_ROLE, _admin);
  }

  function mint(address _to, uint256 _amount) external virtual {}
}

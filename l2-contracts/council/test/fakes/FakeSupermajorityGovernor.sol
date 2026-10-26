// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Stands in for step 1's Supermajority Governor, which is an OpenZeppelin v4 contract this project cannot deploy. The
// deployment checks read only its timelock.
contract FakeSupermajorityGovernor {
  address internal immutable TIMELOCK;

  constructor(address _timelock) {
    TIMELOCK = _timelock;
  }

  function timelock() external view returns (address) {
    return TIMELOCK;
  }
}

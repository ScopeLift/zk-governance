// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkMinterRateLimiterV1} from "src/ZkMinterRateLimiterV1.sol";
import {ZkCappedMinterV2, ZkCappedMinterV2Test} from "test/ZkCappedMinterV2.t.sol";

contract ZkMinterRateLimiterV1Test is ZkCappedMinterV2Test {
  ZkMinterRateLimiterV1 public minterRateLimiter;
  uint256 public constant CAP_PER_MINT_PERIOD = 100_000e18;
  uint48 public constant MINT_PERIOD = 1 days;

  function setUp() public override {
    super.setUp();
    minterRateLimiter = new ZkMinterRateLimiterV1(cappedMinter, admin, CAP_PER_MINT_PERIOD, MINT_PERIOD);
  }

  function test_InitializesMinterRateLimiterCorrectly() public {
    assertTrue(minterRateLimiter.hasRole(minterRateLimiter.DEFAULT_ADMIN_ROLE(), admin));
    assertEq(address(minterRateLimiter.zkCappedMinter()), address(cappedMinter));
    assertEq(minterRateLimiter.capPerMintPeriod(), CAP_PER_MINT_PERIOD);
    assertEq(minterRateLimiter.mintPeriod(), MINT_PERIOD);
  }
}

contract Constructor is ZkMinterRateLimiterV1Test {
  function testFuzz_InitializesMinterRateLimiterCorrectly(
    ZkCappedMinterV2 _zkCappedMinter,
    address _admin,
    uint256 _capPerMintPeriod,
    uint48 _mintPeriod
  ) public {
    ZkMinterRateLimiterV1 _minterRateLimiter =
      new ZkMinterRateLimiterV1(_zkCappedMinter, _admin, _capPerMintPeriod, _mintPeriod);

    assertEq(address(_minterRateLimiter.zkCappedMinter()), address(_zkCappedMinter));
    assertTrue(_minterRateLimiter.hasRole(_minterRateLimiter.DEFAULT_ADMIN_ROLE(), _admin));
    assertEq(_minterRateLimiter.capPerMintPeriod(), _capPerMintPeriod);
    assertEq(_minterRateLimiter.mintPeriod(), _mintPeriod);
  }
}

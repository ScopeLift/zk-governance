// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkTokenTest} from "test/utils/ZkTokenTest.sol";
import {IMintable} from "src/interfaces/IMintable.sol";
import {ZkMinterRateLimiterV1} from "src/ZkMinterRateLimiterV1.sol";

contract ZkMinterRateLimiterV1Test is ZkTokenTest {
  ZkMinterRateLimiterV1 public minterRateLimiter;
  IMintable public mintable = IMintable(makeAddr("mintable"));
  uint256 public constant CAP_PER_MINT_PERIOD = 100_000e18;
  uint48 public constant MINT_PERIOD = 1 days;

  function setUp() public override {
    super.setUp();
    minterRateLimiter = new ZkMinterRateLimiterV1(mintable, admin, CAP_PER_MINT_PERIOD, MINT_PERIOD);
  }

  function test_InitializesMinterRateLimiterCorrectly() public {
    assertTrue(minterRateLimiter.hasRole(minterRateLimiter.DEFAULT_ADMIN_ROLE(), admin));
    assertEq(address(minterRateLimiter.MINTABLE()), address(mintable));
    assertEq(minterRateLimiter.CAP_PER_MINT_PERIOD(), CAP_PER_MINT_PERIOD);
    assertEq(minterRateLimiter.MINT_PERIOD(), MINT_PERIOD);
  }
}

contract Constructor is ZkMinterRateLimiterV1Test {
  function testFuzz_InitializesMinterRateLimiterCorrectly(
    IMintable _mintable,
    address _admin,
    uint256 _capPerMintPeriod,
    uint48 _mintPeriod
  ) public {
    ZkMinterRateLimiterV1 _minterRateLimiter =
      new ZkMinterRateLimiterV1(_mintable, _admin, _capPerMintPeriod, _mintPeriod);

    assertEq(address(_minterRateLimiter.MINTABLE()), address(_mintable));
    assertTrue(_minterRateLimiter.hasRole(_minterRateLimiter.DEFAULT_ADMIN_ROLE(), _admin));
    assertEq(_minterRateLimiter.CAP_PER_MINT_PERIOD(), _capPerMintPeriod);
    assertEq(_minterRateLimiter.MINT_PERIOD(), _mintPeriod);
  }
}

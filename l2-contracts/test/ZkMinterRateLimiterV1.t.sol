// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkMinterRateLimiterV1} from "src/ZkMinterRateLimiterV1.sol";
import {ZkCappedMinterV2Test} from "test/ZkCappedMinterV2.t.sol";
import {IMintable} from "src/interfaces/IMintable.sol";

contract ZkMinterRateLimiterV1Test is ZkCappedMinterV2Test {
  ZkMinterRateLimiterV1 public minterRateLimiter;
  IMintable public mintable;
  uint256 public constant MINT_RATE_LIMIT = 100_000e18;
  uint48 public constant MINT_RATE_LIMIT_WINDOW = 1 days;

  function setUp() public virtual override {
    super.setUp();
    mintable = IMintable(address(cappedMinter));
    minterRateLimiter = new ZkMinterRateLimiterV1(mintable, admin, MINT_RATE_LIMIT, MINT_RATE_LIMIT_WINDOW);
    _grantMinterRole(cappedMinter, cappedMinterAdmin, address(minterRateLimiter));
  }

  function _grantRateLimiterMinterRole(address _minter) internal {
    vm.prank(admin);
    minterRateLimiter.grantRole(MINTER_ROLE, _minter);
  }

  function test_InitializesMinterRateLimiterCorrectly() public {
    assertTrue(minterRateLimiter.hasRole(minterRateLimiter.DEFAULT_ADMIN_ROLE(), admin));
    assertEq(address(minterRateLimiter.mintable()), address(mintable));
    assertEq(minterRateLimiter.mintRateLimit(), MINT_RATE_LIMIT);
    assertEq(minterRateLimiter.mintRateLimitWindow(), MINT_RATE_LIMIT_WINDOW);
  }
}

contract Constructor is ZkMinterRateLimiterV1Test {
  function testFuzz_InitializesMinterRateLimiterCorrectly(
    IMintable _mintable,
    address _admin,
    uint256 _mintRateLimit,
    uint48 _mintRateLimitWindow
  ) public {
    ZkMinterRateLimiterV1 _minterRateLimiter =
      new ZkMinterRateLimiterV1(_mintable, _admin, _mintRateLimit, _mintRateLimitWindow);

    assertEq(address(_minterRateLimiter.mintable()), address(_mintable));
    assertTrue(_minterRateLimiter.hasRole(_minterRateLimiter.DEFAULT_ADMIN_ROLE(), _admin));
    assertEq(_minterRateLimiter.mintRateLimit(), _mintRateLimit);
    assertEq(_minterRateLimiter.mintRateLimitWindow(), _mintRateLimitWindow);
  }
}

contract Mint is ZkMinterRateLimiterV1Test {
  function testFuzz_MintsSuccessfullyAsMinter(address _minter, address _to, uint256 _amount) public {
    _amount = bound(_amount, 1, DEFAULT_CAP);
    vm.assume(_to != address(0));
    _grantRateLimiterMinterRole(_minter);

    vm.prank(_minter);
    minterRateLimiter.mint(_to, _amount);
  }

  function testFuzz_RevertIf_CalledByNonMinter(address _minter, address _nonMinter, address _to, uint256 _amount)
    public
  {
    vm.assume(_nonMinter != _minter);
    _grantRateLimiterMinterRole(_minter);

    vm.prank(_nonMinter);
    vm.expectRevert(_formatAccessControlError(_nonMinter, MINTER_ROLE));
    minterRateLimiter.mint(_to, _amount);
  }
}

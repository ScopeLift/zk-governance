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
  address public minter = makeAddr("minter");

  function setUp() public override {
    super.setUp();
    vm.startPrank(admin);
    minterRateLimiter.grantRole(MINTER_ROLE, minter);
    vm.stopPrank();
  }

  function testFuzz_MintsSuccessfullyAsMinter(address _minter, address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, MINT_RATE_LIMIT);
    _grantRateLimiterMinterRole(_minter);

    vm.prank(_minter);
    minterRateLimiter.mint(_to, _amount);
    assertEq(token.balanceOf(_to), _amount);
    assertEq(minterRateLimiter.mintedInWindow(minterRateLimiter.currentMintWindowStart()), _amount);
  }

  function testFuzz_EmitsMintedEvent(address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, MINT_RATE_LIMIT);

    vm.prank(minter);
    vm.expectEmit();
    emit ZkMinterRateLimiterV1.Minted(minter, _to, _amount);
    minterRateLimiter.mint(_to, _amount);
  }

  function testFuzz_MintRateLimitIsResetAfterWindow(address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, MINT_RATE_LIMIT);

    vm.startPrank(minter);
    // Mint up to 5 times while staying within the IMintable contract's expiration time and mint cap.
    for (
      uint256 i = 0;
      i < 5 && block.timestamp < cappedMinter.EXPIRATION_TIME() && cappedMinter.minted() + _amount < cappedMinter.CAP();
      i++
    ) {
      minterRateLimiter.mint(_to, _amount);
      assertEq(minterRateLimiter.mintedInWindow(minterRateLimiter.currentMintWindowStart()), _amount);
      vm.warp(block.timestamp + MINT_RATE_LIMIT_WINDOW);
    }
    vm.stopPrank();
  }

  function testFuzz_RevertIf_MintRateLimitExceeded(address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, MINT_RATE_LIMIT + 1, type(uint256).max);

    vm.prank(minter);
    vm.expectRevert(
      abi.encodeWithSelector(
        ZkMinterRateLimiterV1.ZkMinterRateLimiterV1__MintRateLimitExceeded.selector, minter, _amount
      )
    );
    minterRateLimiter.mint(_to, _amount);
  }

  function testFuzz_RevertIf_MintRateLimitExceededAfterTwoMintsInTheSameWindow(
    address _to,
    uint256 _amount,
    uint256 _exceedingAmount
  ) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, MINT_RATE_LIMIT);
    _exceedingAmount = bound(_exceedingAmount, 1, type(uint256).max);

    vm.startPrank(minter);
    minterRateLimiter.mint(_to, _amount);
    minterRateLimiter.mint(_to, MINT_RATE_LIMIT - _amount);
    assertEq(minterRateLimiter.mintedInWindow(minterRateLimiter.currentMintWindowStart()), MINT_RATE_LIMIT);
    vm.stopPrank();

    vm.prank(minter);
    vm.expectRevert(
      abi.encodeWithSelector(
        ZkMinterRateLimiterV1.ZkMinterRateLimiterV1__MintRateLimitExceeded.selector, minter, _exceedingAmount
      )
    );
    minterRateLimiter.mint(_to, _exceedingAmount);
  }

  function testFuzz_RevertIf_MintRateLimitExceededAfterTwoMintsInDifferentWindows(
    address _to,
    uint256 _amount,
    uint256 _exceedingAmount
  ) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, MINT_RATE_LIMIT);
    _exceedingAmount = bound(_exceedingAmount, 1, type(uint256).max);

    vm.startPrank(minter);
    minterRateLimiter.mint(_to, _amount);
    minterRateLimiter.mint(_to, MINT_RATE_LIMIT - _amount);

    vm.warp(block.timestamp + MINT_RATE_LIMIT_WINDOW);

    minterRateLimiter.mint(_to, _amount);
    minterRateLimiter.mint(_to, MINT_RATE_LIMIT - _amount);
    vm.stopPrank();

    vm.prank(minter);
    vm.expectRevert(
      abi.encodeWithSelector(
        ZkMinterRateLimiterV1.ZkMinterRateLimiterV1__MintRateLimitExceeded.selector, minter, _exceedingAmount
      )
    );
    minterRateLimiter.mint(_to, _exceedingAmount);
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ZkMinterRateLimiterV1} from "src/ZkMinterRateLimiterV1.sol";
import {ZkCappedMinterV2, ZkCappedMinterV2Test} from "test/ZkCappedMinterV2.t.sol";

contract ZkMinterRateLimiterV1Test is ZkCappedMinterV2Test {
  ZkMinterRateLimiterV1 public minterRateLimiter;
  uint256 public constant CAP_PER_MINT_PERIOD = 100_000e18;
  uint48 public constant MINT_PERIOD = 1 days;

  function setUp() public virtual override {
    super.setUp();
    minterRateLimiter = new ZkMinterRateLimiterV1(cappedMinter, admin, CAP_PER_MINT_PERIOD, MINT_PERIOD);
    _grantMinterRole(cappedMinter, cappedMinterAdmin, address(minterRateLimiter));
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

contract Mint is ZkMinterRateLimiterV1Test {
  address public minter = makeAddr("minter");

  function setUp() public override {
    super.setUp();
    vm.startPrank(admin);
    minterRateLimiter.grantRole(MINTER_ROLE, minter);
    vm.stopPrank();
  }

  function testFuzz_MintsSuccessfullyAsMinter(address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, CAP_PER_MINT_PERIOD);

    vm.prank(minter);
    minterRateLimiter.mint(_to, _amount);
    assertEq(token.balanceOf(_to), _amount);
    assertEq(minterRateLimiter.mintedInPeriod(minterRateLimiter.currentMintPeriodStart()), _amount);
  }

  function testFuzz_EmitsMintedEvent(address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, CAP_PER_MINT_PERIOD);

    vm.prank(minter);
    vm.expectEmit();
    emit ZkMinterRateLimiterV1.Minted(minter, _to, _amount);
    minterRateLimiter.mint(_to, _amount);
  }

  function testFuzz_RevertIf_CapPerMintPeriodExceeded(address _to, uint256 _amount) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, CAP_PER_MINT_PERIOD + 1, DEFAULT_CAP);

    vm.prank(minter);
    vm.expectRevert(
      abi.encodeWithSelector(
        ZkMinterRateLimiterV1.ZkMinterRateLimiterV1__CapPerMintPeriodExceeded.selector, minter, _amount
      )
    );
    minterRateLimiter.mint(_to, _amount);
  }

  function testFuzz_RevertIf_CapPerMintPeriodExceededAfterTwoMintsInTheSamePeriod(
    address _to,
    uint256 _amount,
    uint256 _exceedingAmount
  ) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, CAP_PER_MINT_PERIOD);
    _exceedingAmount = bound(_exceedingAmount, 1, type(uint256).max);

    vm.startPrank(minter);
    minterRateLimiter.mint(_to, _amount);
    minterRateLimiter.mint(_to, CAP_PER_MINT_PERIOD - _amount);
    assertEq(minterRateLimiter.mintedInPeriod(minterRateLimiter.currentMintPeriodStart()), CAP_PER_MINT_PERIOD);
    vm.stopPrank();

    vm.prank(minter);
    vm.expectRevert(
      abi.encodeWithSelector(
        ZkMinterRateLimiterV1.ZkMinterRateLimiterV1__CapPerMintPeriodExceeded.selector, minter, _exceedingAmount
      )
    );
    minterRateLimiter.mint(_to, _exceedingAmount);
  }

  function testFuzz_RevertIf_CapPerMintPeriodExceededAfterTwoMintsInDifferentPeriods(
    address _to,
    uint256 _amount,
    uint256 _exceedingAmount
  ) public {
    vm.assume(_to != address(0));
    _amount = bound(_amount, 1, CAP_PER_MINT_PERIOD);
    _exceedingAmount = bound(_exceedingAmount, 1, type(uint256).max);

    vm.startPrank(minter);
    minterRateLimiter.mint(_to, _amount);
    minterRateLimiter.mint(_to, CAP_PER_MINT_PERIOD - _amount);

    vm.warp(block.timestamp + MINT_PERIOD);

    minterRateLimiter.mint(_to, _amount);
    minterRateLimiter.mint(_to, CAP_PER_MINT_PERIOD - _amount);
    vm.stopPrank();

    vm.prank(minter);
    vm.expectRevert(
      abi.encodeWithSelector(
        ZkMinterRateLimiterV1.ZkMinterRateLimiterV1__CapPerMintPeriodExceeded.selector, minter, _exceedingAmount
      )
    );
    minterRateLimiter.mint(_to, _exceedingAmount);
  }

  function testFuzz_RevertIf_NotMinter(address _nonMinter, address _to, uint256 _amount) public {
    vm.assume(_nonMinter != minter);
    vm.startPrank(_nonMinter);
    vm.expectRevert(_formatAccessControlError(_nonMinter, MINTER_ROLE));
    minterRateLimiter.mint(_to, _amount);
    vm.stopPrank();
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkMinterRateLimiterV1Factory} from "src/ZkMinterRateLimiterV1Factory.sol";
import {ZkMinterRateLimiterV1} from "src/ZkMinterRateLimiterV1.sol";
import {IMintable} from "src/interfaces/IMintable.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract ZkMinterRateLimiterV1FactoryTest is Test {
  bytes32 bytecodeHash;
  ZkMinterRateLimiterV1Factory factory;

  error HashIsNonZero(bytes32 _hash);

  function setUp() public virtual {
    // Read the bytecode hash from the JSON file
    string memory root = vm.projectRoot();
    string memory path = string.concat(root, "/zkout/ZkMinterRateLimiterV1.sol/ZkMinterRateLimiterV1.json");
    string memory json = vm.readFile(path);
    bytecodeHash = bytes32(stdJson.readBytes(json, ".hash"));

    factory = new ZkMinterRateLimiterV1Factory(bytecodeHash);
  }

  function _assumeValidAddress(address _addr) internal view {
    vm.assume(_addr != address(0) && _addr != address(factory));
  }

  function _boundToValidRateLimit(uint256 _rateLimit) internal pure returns (uint256) {
    return bound(_rateLimit, 1, type(uint256).max);
  }

  function _boundToValidTimeWindow(uint48 _timeWindow) internal pure returns (uint48) {
    return uint48(bound(_timeWindow, 1, type(uint48).max));
  }
}

contract CreateMinterRateLimiter is ZkMinterRateLimiterV1FactoryTest {
  function testFuzz_CreatesNewMinterRateLimiter(
    IMintable _mintable,
    address _minterAdmin,
    uint256 _mintRateLimit,
    uint48 _mintRateLimitWindow,
    uint256 _saltNonce
  ) public {
    _assumeValidAddress(address(_mintable));
    _assumeValidAddress(_minterAdmin);
    _mintRateLimit = _boundToValidRateLimit(_mintRateLimit);
    _mintRateLimitWindow = _boundToValidTimeWindow(_mintRateLimitWindow);

    address minterAddress =
      factory.createMinterRateLimiter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);

    ZkMinterRateLimiterV1 minter = ZkMinterRateLimiterV1(minterAddress);
    assertEq(address(minter.mintable()), address(_mintable));
    assertEq(minter.hasRole(minter.DEFAULT_ADMIN_ROLE(), _minterAdmin), true);
    assertEq(minter.mintRateLimit(), _mintRateLimit);
    assertEq(minter.mintRateLimitWindow(), _mintRateLimitWindow);
  }

  function testFuzz_EmitsMinterRateLimiterCreatedEvent(
    IMintable _mintable,
    address _minterAdmin,
    uint256 _mintRateLimit,
    uint48 _mintRateLimitWindow,
    uint256 _saltNonce
  ) public {
    _assumeValidAddress(address(_mintable));
    _assumeValidAddress(_minterAdmin);
    _mintRateLimit = _boundToValidRateLimit(_mintRateLimit);
    _mintRateLimitWindow = _boundToValidTimeWindow(_mintRateLimitWindow);

    vm.expectEmit();
    emit ZkMinterRateLimiterV1Factory.MinterRateLimiterCreated(
      factory.getMinter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce),
      _mintable,
      _minterAdmin,
      _mintRateLimit,
      _mintRateLimitWindow
    );

    factory.createMinterRateLimiter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);
  }

  function testFuzz_RevertIf_CreatingDuplicateMinter(
    IMintable _mintable,
    address _minterAdmin,
    uint256 _mintRateLimit,
    uint48 _mintRateLimitWindow,
    uint256 _saltNonce
  ) public {
    _assumeValidAddress(address(_mintable));
    _assumeValidAddress(_minterAdmin);
    _mintRateLimit = _boundToValidRateLimit(_mintRateLimit);
    _mintRateLimitWindow = _boundToValidTimeWindow(_mintRateLimitWindow);

    factory.createMinterRateLimiter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);

    vm.expectRevert(abi.encodeWithSelector(HashIsNonZero.selector, bytecodeHash));
    factory.createMinterRateLimiter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);
  }
}

contract GetMinter is ZkMinterRateLimiterV1FactoryTest {
  function testFuzz_ReturnsCorrectMinterAddress(
    IMintable _mintable,
    address _minterAdmin,
    uint256 _mintRateLimit,
    uint48 _mintRateLimitWindow,
    uint256 _saltNonce
  ) public {
    _assumeValidAddress(address(_mintable));
    _assumeValidAddress(_minterAdmin);
    _mintRateLimit = _boundToValidRateLimit(_mintRateLimit);
    _mintRateLimitWindow = _boundToValidTimeWindow(_mintRateLimitWindow);

    address expectedMinterAddress =
      factory.getMinter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);

    address minterAddress =
      factory.createMinterRateLimiter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);

    assertEq(minterAddress, expectedMinterAddress);
  }

  function testFuzz_GetMinterWithoutDeployment(
    IMintable _mintable,
    address _minterAdmin,
    uint256 _mintRateLimit,
    uint48 _mintRateLimitWindow,
    uint256 _saltNonce
  ) public {
    _assumeValidAddress(address(_mintable));
    _assumeValidAddress(_minterAdmin);
    _mintRateLimit = _boundToValidRateLimit(_mintRateLimit);
    _mintRateLimitWindow = _boundToValidTimeWindow(_mintRateLimitWindow);

    address expectedMinterAddress =
      factory.getMinter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);

    uint256 codeSize;
    assembly {
      codeSize := extcodesize(expectedMinterAddress)
    }
    assertEq(codeSize, 0);

    address minterAddress =
      factory.createMinterRateLimiter(_mintable, _minterAdmin, _mintRateLimit, _mintRateLimitWindow, _saltNonce);

    assembly {
      codeSize := extcodesize(expectedMinterAddress)
    }
    assertGt(codeSize, 0);
    assertEq(minterAddress, expectedMinterAddress);
  }
}

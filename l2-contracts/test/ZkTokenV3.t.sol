// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkTokenV3} from "src/ZkTokenV3.sol";
import {ZkTokenV2} from "src/ZkTokenV2.sol";
import {ZkTokenV1} from "src/ZkTokenV1.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
  TransparentUpgradeableProxy,
  ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract ZkTokenV3Test is Test {
  ZkTokenV3 tokenV3Implementation;
  address admin = makeAddr("Admin");
  address initMintReceiver = makeAddr("Init Mint Receiver");

  address constant ZK_TOKEN_GOVERNOR = 0xb83FF6501214ddF40C91C9565d095400f3F45746;
  address constant TOKEN_GOVERNOR_TIMELOCK = 0xe5d21A9179CA2E1F0F327d598D464CcF60d89c3d;
  address constant ZK_TOKEN_PROXY_ADDRESS = 0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E;
  uint256 constant INITIAL_MINT_AMOUNT = 1_000_000_000e18;
  uint256 constant MAX_SUPPLY = 21_000_000_000e18;
  bytes32 constant BURNER_ROLE = keccak256("BURNER_ROLE");

  function setUp() public virtual {
    tokenV3Implementation = new ZkTokenV3();
    tokenV3Implementation.initialize(admin, initMintReceiver, INITIAL_MINT_AMOUNT);
    tokenV3Implementation.initializeV2();
  }

  function _mint(address _to, uint256 _amount) internal {
    vm.startPrank(admin);
    tokenV3Implementation.grantRole(tokenV3Implementation.MINTER_ROLE(), admin);
    tokenV3Implementation.mint(_to, _amount);
    vm.stopPrank();
  }

  function _formatAccessControlError(address account, bytes32 role) internal pure returns (bytes memory) {
    return bytes(
      string.concat(
        "AccessControl: account ",
        Strings.toHexString(uint160(account), 20),
        " is missing role ",
        Strings.toHexString(uint256(role), 32)
      )
    );
  }
}

contract Initialize is ZkTokenV3Test {
  function calculateDomainSeparator(address _token) public view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256(bytes("ZKsync")),
        keccak256(bytes("1")),
        block.chainid,
        _token
      )
    );
  }

  function test_InitializesTheTokenWithTheCorrectConfigurationWhenDeployed() public {
    assertEq(tokenV3Implementation.symbol(), "ZK");
    assertEq(tokenV3Implementation.name(), "ZKsync");
    assertEq(tokenV3Implementation.maxSupply(), 21_000_000_000e18);
    assertEq(tokenV3Implementation.DOMAIN_SEPARATOR(), calculateDomainSeparator(address(tokenV3Implementation)));
    assertEq(tokenV3Implementation.totalSupply(), INITIAL_MINT_AMOUNT);
    assertEq(tokenV3Implementation.balanceOf(initMintReceiver), INITIAL_MINT_AMOUNT);
  }

  function testFuzz_RevertIf_TheInitializerV3IsCalledTwice() public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3Implementation.initializeV2();
  }
}

contract MaxSupply is ZkTokenV3Test {
  function test_ReturnsTheCorrectMaxSupply() public {
    assertEq(tokenV3Implementation.maxSupply(), MAX_SUPPLY);
  }
}

contract Clock is ZkTokenV3Test {
  function test_ReturnsTheCorrectClock() public {
    assertEq(tokenV3Implementation.clock(), SafeCastUpgradeable.toUint48(block.timestamp));
  }
}

contract CLOCK_MODE is ZkTokenV3Test {
  function test_ReturnsTheCorrectClockMode() public {
    assertEq(tokenV3Implementation.CLOCK_MODE(), "mode=timestamp");
  }
}

contract Burn is ZkTokenV3Test {
  function testFuzz_CallerCanBurnTokens(uint256 _initialBalance, uint256 _burnAmount, address _caller) public {
    vm.assume(_caller != address(0) && _caller != admin);
    _initialBalance = bound(_initialBalance, 0, MAX_SUPPLY - INITIAL_MINT_AMOUNT);
    _burnAmount = bound(_burnAmount, 0, _initialBalance);
    _mint(_caller, _initialBalance);
    uint256 _initialSupply = tokenV3Implementation.totalSupply();

    vm.prank(_caller);
    tokenV3Implementation.burn(_burnAmount);

    assertEq(tokenV3Implementation.balanceOf(_caller), _initialBalance - _burnAmount);
    assertEq(tokenV3Implementation.totalSupply(), _initialSupply - _burnAmount);
  }

  function testFuzz_RevertIf_CallerDoesNotHaveEnoughBalance(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller
  ) public {
    vm.assume(_caller != address(0));
    _initialBalance = bound(_initialBalance, 0, MAX_SUPPLY - INITIAL_MINT_AMOUNT - 1);
    _burnAmount = bound(_burnAmount, _initialBalance + 1, MAX_SUPPLY - INITIAL_MINT_AMOUNT);
    _mint(_caller, _initialBalance);

    vm.expectRevert("ERC20: burn amount exceeds balance");
    vm.prank(_caller);
    tokenV3Implementation.burn(_burnAmount);
  }
}

contract BurnFrom is ZkTokenV3Test {
  function _grantBurnerRole(address _to) internal {
    vm.prank(admin);
    tokenV3Implementation.grantRole(BURNER_ROLE, _to);
  }

  function testFuzz_CallerWithBurnerRoleCanBurnTokensFromAnotherAddress(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != admin);
    vm.assume(_from != address(0) && _from != admin);
    _grantBurnerRole(_caller);
    _initialBalance = bound(_initialBalance, 0, MAX_SUPPLY - INITIAL_MINT_AMOUNT);
    _burnAmount = bound(_burnAmount, 0, _initialBalance);
    _mint(_from, _initialBalance);
    uint256 _initialSupply = tokenV3Implementation.totalSupply();

    vm.prank(_caller);
    tokenV3Implementation.burnFrom(_from, _burnAmount);

    assertEq(tokenV3Implementation.balanceOf(_from), _initialBalance - _burnAmount);
    assertEq(tokenV3Implementation.totalSupply(), _initialSupply - _burnAmount);
  }

  function testFuzz_RevertIf_CallerDoesNotHaveBurnerRole(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != admin);
    vm.assume(_from != address(0) && _from != admin);
    _initialBalance = bound(_initialBalance, 0, MAX_SUPPLY - INITIAL_MINT_AMOUNT);
    _burnAmount = bound(_burnAmount, 0, _initialBalance);
    _mint(_from, _initialBalance);

    vm.expectRevert(_formatAccessControlError(_caller, BURNER_ROLE));
    vm.prank(_caller);
    tokenV3Implementation.burnFrom(_from, _burnAmount);
  }
}

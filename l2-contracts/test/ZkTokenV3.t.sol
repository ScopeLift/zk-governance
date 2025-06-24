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
  ZkTokenV3 tokenV3;
  ZkTokenV3 tokenV3Implementation;
  address admin = makeAddr("Admin");
  address initMintReceiver = makeAddr("Init Mint Receiver");

  address constant ZK_TOKEN_GOVERNOR = 0xb83FF6501214ddF40C91C9565d095400f3F45746;
  address constant TOKEN_GOVERNOR_TIMELOCK = 0xe5d21A9179CA2E1F0F327d598D464CcF60d89c3d;
  address constant ZK_TOKEN_PROXY_ADDRESS = 0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E;
  address constant PROXY_ADMIN_ADDRESS = 0xdB1E46B448e68a5E35CB693a99D59f784aD115CC;
  address constant ADMIN_ADDRESS = 0xF41EcA3047B37dc7d88849de4a4dc07937Ad6bc4;
  uint256 constant INITIAL_MINT_AMOUNT = 1_000_000_000e18;
  uint256 constant MAX_SUPPLY = 21_000_000_000e18;
  bytes32 constant DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;
  uint256 constant FORK_BLOCK_NUMBER = 62_000_000;

  function setUp() public virtual {
    vm.createSelectFork(vm.envString("ZK_RPC_URL"), FORK_BLOCK_NUMBER);
    tokenV3Implementation = new ZkTokenV3();
    tokenV3Implementation.initialize(admin, initMintReceiver, INITIAL_MINT_AMOUNT);
    tokenV3Implementation.initializeV2();
    _upgradeProxyImplementationToV3();
    tokenV3 = ZkTokenV3(payable(ZK_TOKEN_PROXY_ADDRESS));
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

  function _upgradeProxyImplementationToV3() internal {
    ProxyAdmin _proxy = ProxyAdmin(payable(PROXY_ADMIN_ADDRESS));
    vm.prank(_proxy.owner());
    _proxy.upgrade(ITransparentUpgradeableProxy(ZK_TOKEN_PROXY_ADDRESS), address(tokenV3Implementation));
  }

  function _grantProxyBurnerRole(address _to) internal {
    vm.startPrank(ADMIN_ADDRESS);
    tokenV3.grantRole(tokenV3.BURNER_ADMIN_ROLE(), ADMIN_ADDRESS);
    tokenV3.grantRole(tokenV3.BURNER_ROLE(), _to);
    vm.stopPrank();
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

  function test_UpgradeTransparentUpgradeableProxyFromTokenV2ToTokenV3() public {
    ProxyAdmin _proxy = ProxyAdmin(payable(PROXY_ADMIN_ADDRESS));
    ZkTokenV2 _tokenV2 = ZkTokenV2(payable(ZK_TOKEN_PROXY_ADDRESS));
    uint256 _tokenSupply = _tokenV2.totalSupply();

    ZkTokenV3 _tokenV3Implementation = new ZkTokenV3();
    _tokenV3Implementation.initializeV2();

    vm.prank(_proxy.owner());
    _proxy.upgrade(ITransparentUpgradeableProxy(ZK_TOKEN_PROXY_ADDRESS), address(_tokenV3Implementation));

    assertEq(
      _proxy.getProxyImplementation(ITransparentUpgradeableProxy(ZK_TOKEN_PROXY_ADDRESS)),
      address(_tokenV3Implementation)
    );
    assertEq(tokenV3.symbol(), "ZK");
    assertEq(tokenV3.name(), "ZKsync");
    assertEq(tokenV3.totalSupply(), _tokenSupply);
  }

  function testFuzz_RevertIf_TheInitializerV3IsCalledTwice() public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3Implementation.initializeV2();
  }

  function testFuzz_RevertIf_TheInitializerIsCalledAfterUpgrade(
    address _admin,
    address _initMintReceiver,
    uint256 _initialMintAmount
  ) public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3Implementation.initialize(_admin, _initMintReceiver, _initialMintAmount);
  }

  function test_RevertIf_TheInitializerV2IsCalledTwiceAfterUpgrade() public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3Implementation.initializeV2();
  }
}

contract MaxSupply is ZkTokenV3Test {
  function test_ReturnsTheCorrectMaxSupply() public {
    assertEq(tokenV3Implementation.maxSupply(), MAX_SUPPLY);
  }

  function test_ReturnsTheCorrectMaxSupplyAfterUpgrade() public {
    assertEq(tokenV3.maxSupply(), MAX_SUPPLY);
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

contract Mint is ZkTokenV3Test {
  function testFuzz_GovernorCanMintTokensAfterUpgrade(uint256 _mintAmount, address _to) public {
    vm.assume(_to != address(0) && _to != admin);
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_to, _mintAmount);
    uint256 _initialSupply = tokenV3.totalSupply();

    assertEq(tokenV3.balanceOf(_to), _mintAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + _mintAmount);
  }

  function testFuzz_RevertIf_CallerDoesNotHaveMinterRole(uint256 _mintAmount, address _caller) public {
    vm.assume(_caller != address(0) && _caller != admin);
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());

    vm.expectRevert(_formatAccessControlError(_caller, tokenV3.MINTER_ROLE()));
    vm.prank(_caller);
    tokenV3.mint(_caller, _mintAmount);
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

  function testFuzz_CallerCanBurnTokensAfterUpgrade(uint256 _initialBalance, uint256 _burnAmount, address _caller)
    public
  {
    vm.assume(_caller != address(0) && _caller != admin);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _burnAmount = bound(_burnAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);
    uint256 _initialSupply = tokenV3.totalSupply();

    vm.prank(_caller);
    tokenV3.burn(_burnAmount);

    assertEq(tokenV3.balanceOf(_caller), _initialBalance - _burnAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply - _burnAmount);
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

  function testFuzz_RevertIf_CallerDoesNotHaveEnoughBalanceAfterUpgrade(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller
  ) public {
    vm.assume(_caller != address(0));
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply() - 1);
    _burnAmount = bound(_burnAmount, _initialBalance + 1, tokenV3.maxSupply() - tokenV3.totalSupply());
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    vm.expectRevert("ERC20: burn amount exceeds balance");
    tokenV3.burn(_burnAmount);
  }
}

contract BurnFrom is ZkTokenV3Test {
  bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

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

  function testFuzz_CallerWithBurnerRoleCanBurnTokensFromAnotherAddressAfterUpgrade(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    _grantProxyBurnerRole(_caller);
    uint256 _initialSupply = tokenV3.totalSupply();
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - _initialSupply);
    _burnAmount = bound(_burnAmount, 0, _initialBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _initialBalance);

    vm.prank(_caller);
    tokenV3.burnFrom(_from, _burnAmount);

    assertEq(tokenV3.balanceOf(_from), _initialBalance - _burnAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + (_initialBalance - _burnAmount));
  }

  function testFuzz_CallerWithBurnerRoleCanBurnTokensUsingOldMethodFromAnotherAddress(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    _grantProxyBurnerRole(_caller);
    uint256 _initialSupply = tokenV3.totalSupply();
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - _initialSupply);
    _burnAmount = bound(_burnAmount, 0, _initialBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _initialBalance);

    vm.prank(_caller);
    tokenV3.burn(_from, _burnAmount);

    assertEq(tokenV3.balanceOf(_from), _initialBalance - _burnAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + (_initialBalance - _burnAmount));
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

  function testFuzz_RevertIf_CallerDoesNotHaveBurnerRoleAfterUpgrade(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _burnAmount = bound(_burnAmount, 0, _initialBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _initialBalance);

    vm.prank(_caller);
    vm.expectRevert(_formatAccessControlError(_caller, BURNER_ROLE));
    tokenV3.burnFrom(_from, _burnAmount);
  }

  function testFuzz_RevertIf_CallerDoesNotHaveBurnerRoleAfterUpgradeUsingOldMethod(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _burnAmount = bound(_burnAmount, 0, _initialBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _initialBalance);

    vm.prank(_caller);
    vm.expectRevert(_formatAccessControlError(_caller, BURNER_ROLE));
    tokenV3.burn(_from, _burnAmount);
  }
}

contract DelegateOnBehalf is ZkTokenV3Test {
  /// @notice Type hash used when encoding data for `delegateOnBehalf` calls.
  bytes32 public constant DELEGATION_TYPEHASH =
    keccak256("Delegation(address owner,address delegatee,uint256 nonce,uint256 expiry)");

  function testFuzz_PerformsDelegationByCallingDelegateOnBehalfECDSA(
    uint256 _signerPrivateKey,
    uint256 _amount,
    address _delegatee,
    uint256 _expiry
  ) public {
    vm.assume(_delegatee != address(0));
    _expiry = bound(_expiry, block.timestamp, type(uint256).max);
    _signerPrivateKey = bound(_signerPrivateKey, 1, 100e18);
    address _signer = vm.addr(_signerPrivateKey);
    _amount = bound(_amount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_signer, _amount);

    // verify the owner has the expected balance
    assertEq(tokenV3.balanceOf(_signer), _amount);

    bytes32 _message = keccak256(abi.encode(DELEGATION_TYPEHASH, _signer, _delegatee, tokenV3.nonces(_signer), _expiry));

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", tokenV3.DOMAIN_SEPARATOR(), _message));
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_signerPrivateKey, _messageHash);

    // verify the signer has no delegate
    assertEq(tokenV3.delegates(_signer), address(0));

    tokenV3.delegateOnBehalf(_signer, _delegatee, _expiry, abi.encodePacked(_r, _s, _v));

    // verify the signer has delegate
    assertEq(tokenV3.delegates(_signer), _delegatee);
  }

  function testFuzz_PerformsDelegationByCallingDelegateOnBehalfEIP1271(
    uint256 _signerPrivateKey,
    uint256 _amount,
    address _delegatee,
    uint256 _expiry
  ) public {
    vm.assume(_delegatee != address(0));
    _expiry = bound(_expiry, block.timestamp, type(uint256).max);
    _signerPrivateKey = bound(_signerPrivateKey, 1, 100e18);
    address _signer = vm.addr(_signerPrivateKey);
    _amount = bound(_amount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_signer, _amount);

    // verify the owner has the expected balance
    assertEq(tokenV3.balanceOf(_signer), _amount);

    bytes32 _message = keccak256(abi.encode(DELEGATION_TYPEHASH, _signer, _delegatee, tokenV3.nonces(_signer), _expiry));

    bytes32 _messageHash = keccak256(abi.encodePacked("\x19\x01", tokenV3.DOMAIN_SEPARATOR(), _message));

    // verify the signer has no delegate
    assertEq(tokenV3.delegates(_signer), address(0));

    vm.mockCall(
      _signer,
      abi.encodeWithSelector(IERC1271.isValidSignature.selector, _messageHash),
      abi.encode(IERC1271.isValidSignature.selector)
    );

    tokenV3.delegateOnBehalf(_signer, _delegatee, _expiry, "");

    // verify the signer has delegate
    assertEq(tokenV3.delegates(_signer), _delegatee);
  }

  function testFuzz_RevertIf_ExpiredSignatureDelegateOnBehalf(
    uint256 _signerPrivateKey,
    uint256 _amount,
    address _delegatee,
    uint256 _expiry
  ) public {
    vm.assume(_delegatee != address(0));
    _expiry = bound(_expiry, 0, block.timestamp - 1);
    _signerPrivateKey = bound(_signerPrivateKey, 1, 100e18);
    address _signer = vm.addr(_signerPrivateKey);
    _amount = bound(_amount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_signer, _amount);

    // verify the owner has the expected balance
    assertEq(tokenV3.balanceOf(_signer), _amount);

    // verify the signer has no delegate
    assertEq(tokenV3.delegates(_signer), address(0));

    vm.expectRevert(abi.encodeWithSelector(ZkTokenV1.DelegateSignatureExpired.selector, _expiry));
    tokenV3.delegateOnBehalf(_signer, _delegatee, _expiry, "");
  }
}

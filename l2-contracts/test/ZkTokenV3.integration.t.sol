// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test, console2} from "forge-std/Test.sol";
import {ZkTokenV3} from "src/ZkTokenV3.sol";
import {ZkTokenV2} from "src/ZkTokenV2.sol";
import {ZkTokenV1} from "src/ZkTokenV1.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ZkTokenV3Test} from "./ZkTokenV3.t.sol";
import {
  TransparentUpgradeableProxy,
  ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract ZkTokenV3ForkTest is ZkTokenV3Test {
  ZkTokenV3 tokenV3;
  uint256 constant FORK_BLOCK_NUMBER = 62_000_000;
  address constant PROXY_ADMIN_ADDRESS = 0xdB1E46B448e68a5E35CB693a99D59f784aD115CC;
  address constant ADMIN_ADDRESS = 0xF41EcA3047B37dc7d88849de4a4dc07937Ad6bc4;

  function setUp() public virtual override {
    super.setUp();
    vm.createSelectFork(vm.envString("ZK_RPC_URL"), FORK_BLOCK_NUMBER);
    _upgradeProxyImplementationToV3(tokenV3Implementation);
    tokenV3 = ZkTokenV3(payable(ZK_TOKEN_PROXY_ADDRESS));
    vm.startPrank(ADMIN_ADDRESS);
    tokenV3.grantRole(tokenV3.BURNER_ADMIN_ROLE(), ADMIN_ADDRESS);
    vm.stopPrank();
  }

  function _upgradeProxyImplementationToV3(ZkTokenV3 _tokenV3Implementation) internal {
    ProxyAdmin _proxy = ProxyAdmin(payable(PROXY_ADMIN_ADDRESS));
    vm.prank(_proxy.owner());
    _proxy.upgrade(ITransparentUpgradeableProxy(ZK_TOKEN_PROXY_ADDRESS), address(_tokenV3Implementation));
  }

  function _grantBurnerRole(address _to) internal {
    vm.startPrank(ADMIN_ADDRESS);
    tokenV3.grantRole(tokenV3.BURNER_ROLE(), _to);
    vm.stopPrank();
  }
}

contract Initialize is ZkTokenV3ForkTest {
  function test_UpgradeTransparentUpgradeableProxyFromTokenV2ToTokenV3() public {
    ProxyAdmin _proxy = ProxyAdmin(payable(PROXY_ADMIN_ADDRESS));
    ZkTokenV2 _tokenV2 = ZkTokenV2(payable(ZK_TOKEN_PROXY_ADDRESS));
    uint256 _tokenSupply = _tokenV2.totalSupply();
    ZkTokenV3 _tokenV3Implementation = new ZkTokenV3();

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

  function testForkFuzz_RevertIf_TheInitializerIsCalled(
    address _admin,
    address _initMintReceiver,
    uint256 _initialMintAmount
  ) public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3.initialize(_admin, _initMintReceiver, _initialMintAmount);
  }

  function test_RevertIf_TheInitializerV2IsCalledTwice() public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3.initializeV2();
  }
}

contract Transfer is ZkTokenV3ForkTest {
  function testForkFuzz_CallerCanTransferTokens(
    uint256 _initialBalance,
    uint256 _transferAmount,
    address _caller,
    address _to
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_to != address(0));
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _transferAmount = bound(_transferAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    tokenV3.transfer(_to, _transferAmount);

    assertEq(tokenV3.balanceOf(_caller), _initialBalance - _transferAmount);
    assertEq(tokenV3.balanceOf(_to), _transferAmount);
  }
}

contract TransferFrom is ZkTokenV3ForkTest {
  function testForkFuzz_CallerCanTransferTokensFromAnotherAddress(
    uint256 _initialBalance,
    uint256 _transferAmount,
    address _caller,
    address _from,
    address _to
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    vm.assume(_to != address(0));
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _transferAmount = bound(_transferAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _initialBalance);

    vm.prank(_from);
    tokenV3.approve(_caller, _transferAmount);

    vm.prank(_caller);
    tokenV3.transferFrom(_from, _to, _transferAmount);
  }
}

contract Delegate is ZkTokenV3ForkTest {
  function testForkFuzz_CallerCanDelegateTokens(
    uint256 _initialBalance,
    uint256 _delegateAmount,
    address _caller,
    address _delegatee
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _delegateAmount = bound(_delegateAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    tokenV3.delegate(_delegatee);

    assertEq(tokenV3.delegates(_caller), _delegatee);
  }

  function testForkFuzz_HolderAbleToDelegateAfterReceivingTokens(
    address _caller,
    address _to,
    uint256 _initialBalance,
    uint256 _amount
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _amount = bound(_amount, 0, _initialBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    // Transfer
    vm.prank(_caller);
    tokenV3.transfer(_to, _amount);
    assertEq(tokenV3.balanceOf(_caller), _initialBalance - _amount);
    assertEq(tokenV3.balanceOf(_to), _amount);

    // Approve
    vm.prank(_caller);
    tokenV3.approve(_to, _initialBalance - _amount);
    assertEq(tokenV3.allowance(_caller, _to), _initialBalance - _amount);

    // TransferFrom
    vm.prank(_to);
    tokenV3.transferFrom(_caller, _to, _initialBalance - _amount);
    assertEq(tokenV3.balanceOf(_caller), 0);
    assertEq(tokenV3.balanceOf(_to), _initialBalance);

    // Delegate
    vm.prank(_to);
    tokenV3.delegate(_caller);
    assertEq(tokenV3.delegates(_to), _caller);
  }
}

contract MaxSupply is ZkTokenV3ForkTest {
  function test_ReturnsTheCorrectMaxSupply() public {
    assertEq(tokenV3.maxSupply(), MAX_SUPPLY);
  }
}

contract Mint is ZkTokenV3ForkTest {
  function testForkFuzz_GovernorCanMintTokens(uint256 _mintAmount, address _to) public {
    vm.assume(_to != address(0));
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    uint256 _initialBalance = tokenV3.balanceOf(_to);
    uint256 _initialSupply = tokenV3.totalSupply();
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_to, _mintAmount);

    assertEq(tokenV3.balanceOf(_to), _initialBalance + _mintAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + _mintAmount);
  }

  function testForkFuzz_RevertIf_MintsAboveMaxSupply(uint256 _mintAmount, address _to) public {
    vm.assume(_to != address(0));
    _mintAmount = bound(_mintAmount, tokenV3.maxSupply(), type(uint256).max);

    vm.expectRevert();
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_to, _mintAmount);
  }

  function testForkFuzz_RevertIf_CallerDoesNotHaveMinterRole(uint256 _mintAmount, address _caller) public {
    vm.assume(_caller != address(0) && _caller != admin);
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());

    vm.expectRevert(_formatAccessControlError(_caller, tokenV3.MINTER_ROLE()));
    vm.prank(_caller);
    tokenV3.mint(_caller, _mintAmount);
  }
}

contract Burn is ZkTokenV3ForkTest {
  function testForkFuzz_CallerCanBurnTokens(uint256 _initialBalance, uint256 _burnAmount, address _caller) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
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

  function testForkFuzz_RevertIf_CallerDoesNotHaveEnoughBalance(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply() - 1);
    _burnAmount = bound(_burnAmount, _initialBalance + 1, tokenV3.maxSupply() - tokenV3.totalSupply());
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    vm.expectRevert("ERC20: burn amount exceeds balance");
    tokenV3.burn(_burnAmount);
  }
}

contract BurnFrom is ZkTokenV3ForkTest {
  function testForkFuzz_CallerWithBurnerRoleCanBurnTokensFromAnotherAddress(
    uint256 _mintBalance,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    _grantBurnerRole(_caller);
    uint256 _initialSupply = tokenV3.totalSupply();
    _mintBalance = bound(_mintBalance, 0, tokenV3.maxSupply() - _initialSupply);
    _burnAmount = bound(_burnAmount, 0, _mintBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _mintBalance);
    uint256 _initialBalance = tokenV3.balanceOf(_from);

    vm.prank(_caller);
    tokenV3.burnFrom(_from, _burnAmount);

    assertEq(tokenV3.balanceOf(_from), _initialBalance - _burnAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + (_mintBalance - _burnAmount));
  }

  function testForkFuzz_CallerWithBurnerRoleCanBurnTokensUsingOldMethodFromAnotherAddress(
    uint256 _mintAmount,
    uint256 _burnAmount,
    address _caller,
    address _from
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    _grantBurnerRole(_caller);
    uint256 _initialSupply = tokenV3.totalSupply();
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - _initialSupply);
    _burnAmount = bound(_burnAmount, 0, _mintAmount);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _mintAmount);
    uint256 _initialBalance = tokenV3.balanceOf(_from);

    vm.prank(_caller);
    tokenV3.burn(_from, _burnAmount);

    assertEq(tokenV3.balanceOf(_from), _initialBalance - _burnAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + (_mintAmount - _burnAmount));
  }

  function testForkFuzz_RevertIf_CallerDoesNotHaveBurnerRole(
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

  function testForkFuzz_RevertIf_CallerDoesNotHaveBurnerRoleUsingOldMethod(
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

contract DelegateOnBehalf is ZkTokenV3ForkTest {
  /// @notice Type hash used when encoding data for `delegateOnBehalf` calls.
  bytes32 public constant DELEGATION_TYPEHASH =
    keccak256("Delegation(address owner,address delegatee,uint256 nonce,uint256 expiry)");

  function testForkFuzz_PerformsDelegationByCallingDelegateOnBehalfECDSA(
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

  function testForkFuzz_PerformsDelegationByCallingDelegateOnBehalfEIP1271(
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

  function testForkFuzz_RevertIf_ExpiredSignatureDelegateOnBehalf(
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

contract L2CalldataUpgradeCall is Test {
  ZkTokenV3 tokenV3;
  address constant PROXY_ADMIN_ADDRESS = 0xdB1E46B448e68a5E35CB693a99D59f784aD115CC;
  address constant TOKEN_GOVERNOR_TIMELOCK = 0xe5d21A9179CA2E1F0F327d598D464CcF60d89c3d;
  bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
  bytes32 constant BURNER_ROLE = keccak256("BURNER_ROLE");

  function setUp() public virtual {
    vm.createSelectFork("https://mainnet.era.zksync.io/", 65_979_062);
    vm.prank(0xF41EcA3047B37dc7d88849de4a4dc07937Ad6bc4);
    Address.functionCallWithValue(
      0xdB1E46B448e68a5E35CB693a99D59f784aD115CC,
      hex"99a88ec40000000000000000000000005a7d6b2f92c77fad6ccabd7ee0624e64907eaf3e0000000000000000000000004fcd824d304e9b1584cdbb582c104bdcbfb11274",
      0,
      "low-level call failed"
    );
    tokenV3 = ZkTokenV3(payable(0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E));
  }

  function test_UpgradeTransparentUpgradeableProxyFromTokenV2ToTokenV3() public {
    assertEq(tokenV3.symbol(), "ZK");
    assertEq(tokenV3.name(), "ZKsync");
    assertEq(tokenV3.totalSupply(), 21_000_000_000e18);
  }

  function testForkFuzz_RevertIf_TheInitializerIsCalled(
    address _admin,
    address _initMintReceiver,
    uint256 _initialMintAmount
  ) public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3.initialize(_admin, _initMintReceiver, _initialMintAmount);
  }

  function test_RevertIf_TheInitializerV2IsCalledTwice() public {
    vm.expectRevert("Initializable: contract is already initialized");
    tokenV3.initializeV2();
  }

  function testForkFuzz_CallerCanTransferTokens(
    uint256 _initialBalance,
    uint256 _transferAmount,
    address _caller,
    address _to
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_to != address(0));
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _transferAmount = bound(_transferAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    tokenV3.transfer(_to, _transferAmount);

    assertEq(tokenV3.balanceOf(_caller), _initialBalance - _transferAmount);
    assertEq(tokenV3.balanceOf(_to), _transferAmount);
  }

  function testForkFuzz_CallerCanTransferTokensFromAnotherAddress(
    uint256 _initialBalance,
    uint256 _transferAmount,
    address _caller,
    address _from,
    address _to
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    vm.assume(_from != address(0) && _from != PROXY_ADMIN_ADDRESS);
    vm.assume(_to != address(0));
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _transferAmount = bound(_transferAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_from, _initialBalance);

    vm.prank(_from);
    tokenV3.approve(_caller, _transferAmount);

    vm.prank(_caller);
    tokenV3.transferFrom(_from, _to, _transferAmount);
  }

  function testForkFuzz_CallerCanDelegateTokens(
    uint256 _initialBalance,
    uint256 _delegateAmount,
    address _caller,
    address _delegatee
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _delegateAmount = bound(_delegateAmount, 0, _initialBalance);
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    tokenV3.delegate(_delegatee);

    assertEq(tokenV3.delegates(_caller), _delegatee);
  }

  function testForkFuzz_HolderAbleToDelegateAfterReceivingTokens(
    address _caller,
    address _to,
    uint256 _initialBalance,
    uint256 _amount
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    _amount = bound(_amount, 0, _initialBalance);

    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    // Transfer
    vm.prank(_caller);
    tokenV3.transfer(_to, _amount);
    assertEq(tokenV3.balanceOf(_caller), _initialBalance - _amount);
    assertEq(tokenV3.balanceOf(_to), _amount);

    // Approve
    vm.prank(_caller);
    tokenV3.approve(_to, _initialBalance - _amount);
    assertEq(tokenV3.allowance(_caller, _to), _initialBalance - _amount);

    // TransferFrom
    vm.prank(_to);
    tokenV3.transferFrom(_caller, _to, _initialBalance - _amount);
    assertEq(tokenV3.balanceOf(_caller), 0);
    assertEq(tokenV3.balanceOf(_to), _initialBalance);

    // Delegate
    vm.prank(_to);
    tokenV3.delegate(_caller);
    assertEq(tokenV3.delegates(_to), _caller);
  }

  function testForkFuzz_GovernorCanMintTokens(uint256 _mintAmount, address _to) public {
    vm.assume(_to != address(0));
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());
    uint256 _initialBalance = tokenV3.balanceOf(_to);
    uint256 _initialSupply = tokenV3.totalSupply();
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_to, _mintAmount);

    assertEq(tokenV3.balanceOf(_to), _initialBalance + _mintAmount);
    assertEq(tokenV3.totalSupply(), _initialSupply + _mintAmount);
  }

  function testForkFuzz_RevertIf_MintsAboveMaxSupply(uint256 _mintAmount, address _to) public {
    vm.assume(_to != address(0));
    _mintAmount = bound(_mintAmount, tokenV3.maxSupply(), type(uint256).max);

    vm.expectRevert();
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_to, _mintAmount);
  }

  function testForkFuzz_RevertIf_CallerDoesNotHaveMinterRole(uint256 _mintAmount, address _caller) public {
    vm.assume(tokenV3.hasRole(MINTER_ROLE, _caller) != true);
    _mintAmount = bound(_mintAmount, 0, tokenV3.maxSupply() - tokenV3.totalSupply());

    vm.expectRevert(_formatAccessControlError(_caller, tokenV3.MINTER_ROLE()));
    vm.prank(_caller);
    tokenV3.mint(_caller, _mintAmount);
  }

  function testForkFuzz_CallerCanBurnTokens(uint256 _initialBalance, uint256 _burnAmount, address _caller) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
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

  function testForkFuzz_RevertIf_CallerDoesNotHaveEnoughBalance(
    uint256 _initialBalance,
    uint256 _burnAmount,
    address _caller
  ) public {
    vm.assume(_caller != address(0) && _caller != PROXY_ADMIN_ADDRESS);
    _initialBalance = bound(_initialBalance, 0, tokenV3.maxSupply() - tokenV3.totalSupply() - 1);
    _burnAmount = bound(_burnAmount, _initialBalance + 1, tokenV3.maxSupply() - tokenV3.totalSupply());
    vm.prank(TOKEN_GOVERNOR_TIMELOCK);
    tokenV3.mint(_caller, _initialBalance);

    vm.prank(_caller);
    vm.expectRevert("ERC20: burn amount exceeds balance");
    tokenV3.burn(_burnAmount);
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

interface Send {
  function sendToL1(bytes memory) external;
}

contract L2ProposalCalldataCall is Test {
  function setUp() public virtual {
    vm.createSelectFork("https://mainnet.era.zksync.io/", 65_979_062);
  }

  function test_Proposal() public {
    Send(0x0000000000000000000000000000000000008008)
      .sendToL1(
        hex"62f84b2400000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000303a465b659cbb0ab36ee643ea362c509eeb521300000000000000000000000000000000000000000000000000ca8132b0328000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e4d52471c10000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000014400000000000000000000000000000000000000000000000000ca8132b0328000000000000000000000000000db1e46b448e68a5e35cb693a99d59f784ad115cc000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000989680000000000000000000000000000000000000000000000000000000000000032000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000f378708b88841abb63e2316e4fc8f29469bee885000000000000000000000000000000000000000000000000000000000000004499a88ec40000000000000000000000005a7d6b2f92c77fad6ccabd7ee0624e64907eaf3e0000000000000000000000004fcd824d304e9b1584cdbb582c104bdcbfb1127400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
      );
  }
}

interface BridgeHub {
  function requestL2TransactionDirect(L2TransactionRequestDirect memory) external;
}

struct L2TransactionRequestDirect {
  uint256 chainId;
  uint256 mintValue;
  address l2Contract;
  uint256 l2Value;
  bytes l2Calldata;
  uint256 l2GasLimit;
  uint256 l2GasPerPubdataByteLimit;
  bytes[] factoryDeps;
  address refundRecipient;
}

contract L1CrossChainCall is Test {
  function setUp() public virtual {
    vm.createSelectFork("", 65_979_062);
  }

  function test_Proposal() public {
    bytes memory _l2Calldata = hex"99a88ec40000000000000000000000005a7d6b2f92c77fad6ccabd7ee0624e64907eaf3e0000000000000000000000004fcd824d304e9b1584cdbb582c104bdcbfb11274";
    BridgeHub(0x303a465B659cBB0ab36eE643eA362c509EEb5213)
      .requestL2TransactionDirect(
        L2TransactionRequestDirect({
          chainId: 324,
          mintValue: 57_000_000_000_000_000,
          l2Contract: 0xdB1E46B448e68a5E35CB693a99D59f784aD115CC,
          l2Value: 0,
          l2Calldata: _l2Calldata,
          l2GasLimit: 10_000_000,
          l2GasPerPubdataByteLimit: 800,
          factoryDeps: new bytes[](0),
          refundRecipient: 0xF378708B88841Abb63e2316E4Fc8f29469beE885
        })
      );
  }
}

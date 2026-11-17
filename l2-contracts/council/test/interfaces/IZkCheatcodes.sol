// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The foundry-zksync cheatcodes the tests use, which forge-std does not declare. Call them on the cheatcode
/// address, as `IZkCheatcodes(address(vm))`.
interface IZkCheatcodes {
  /// @notice Runs the next CREATE or CALL in the EVM instead of EraVM.
  function zkVmSkip() external;

  /// @notice Pairs a contract's EVM bytecode with its EraVM bytecode, so that a CREATE with the EVM init code deploys
  /// the EraVM bytecode instead. Needed for contracts this project does not compile itself.
  function zkRegisterContract(
    string calldata _name,
    bytes32 _evmBytecodeHash,
    bytes calldata _evmDeployedBytecode,
    bytes calldata _evmBytecode,
    bytes32 _zkBytecodeHash,
    bytes calldata _zkDeployedBytecode
  ) external;
}

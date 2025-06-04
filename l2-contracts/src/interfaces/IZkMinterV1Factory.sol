// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IMintable} from "src/interfaces/IMintable.sol";

interface IZkMinterV1Factory {
  function createMinter(IMintable _mintable, bytes memory _args) external returns (address);
}

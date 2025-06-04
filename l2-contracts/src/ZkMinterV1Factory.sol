// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L2ContractHelper} from "src/lib/L2ContractHelper.sol";
import {ZkMinterRateLimiterV1} from "src/ZkMinterRateLimiterV1.sol";
import {IMintable} from "src/interfaces/IMintable.sol";

/// @title ZkMinterV1Factory
/// @author [ScopeLift](https://scopelift.co)
/// @notice Factory contract to deploy `ZkMinterRateLimiterV1` contracts using CREATE2.
/// @custom:security-contact security@matterlabs.dev
contract ZkMinterV1Factory {}

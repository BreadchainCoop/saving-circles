// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';

import {MockERC20} from 'test/mocks/MockERC20.sol';

/// @notice Minimal ERC-4626 vault for tests. Yield is simulated by minting assets into the vault
///         and losses by burning them, so share price moves like an Aave-style wrapper.
contract MockERC4626 is ERC4626 {
  constructor(IERC20 _asset) ERC20('Mock Vault', 'mVLT') ERC4626(_asset) {}

  function simulateYield(uint256 _amount) external {
    MockERC20(asset()).mint(address(this), _amount);
  }

  function simulateLoss(uint256 _amount) external {
    MockERC20(asset()).burn(address(this), _amount);
  }

  function _decimalsOffset() internal pure override returns (uint8) {
    return 6;
  }
}

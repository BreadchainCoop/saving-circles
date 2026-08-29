// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

/// @dev Mock ERC20 that takes a fee on every transfer, simulating deflationary tokens
contract MockFeeOnTransferERC20 is ERC20 {
  uint256 public feeBps; // fee in basis points (e.g. 100 = 1%)

  constructor(string memory name, string memory symbol, uint256 _feeBps) ERC20(name, symbol) {
    feeBps = _feeBps;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    uint256 fee = (amount * feeBps) / 10_000;
    uint256 net = amount - fee;
    // Burn the fee (simulates deflationary mechanic)
    _burn(msg.sender, fee);
    return super.transfer(to, net);
  }

  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    uint256 fee = (amount * feeBps) / 10_000;
    uint256 net = amount - fee;
    // Burn the fee
    _burn(from, fee);
    // Spend allowance on full amount, transfer net
    _spendAllowance(from, msg.sender, amount);
    _transfer(from, to, net);
    return true;
  }
}

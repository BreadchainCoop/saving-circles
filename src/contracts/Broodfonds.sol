// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from '@openzeppelin-upgradeable/access/OwnableUpgradeable.sol';
import {IERC20} from '@openzeppelin/token/ERC20/IERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/utils/ReentrancyGuard.sol';

import {IBroodfonds} from '../interfaces/IBroodfonds.sol';

/**
 * @title Broodfonds
 * @notice Simple implementation of a Broodfond for ERC20 tokens
 * @author Breadchain Collective
 * @author @exo404
 * @author @valeriooconte
 */
contract Broodfonds is IBroodfonds, ReentrancyGuard, OwnableUpgradeable {
  uint256 public constant MINIMUM_MEMBERS = 25;
  uint256 public constant MAXIMUM_MEMBERS = 50;
  uint256 public nextId;

  mapping(uint256 id => Fond circle) public fonds;
  mapping(uint256 id => mapping(address token => uint256 balance)) public balances;
  mapping(uint256 id => mapping(address member => bool status)) public isMember;
  mapping(address member => uint256[] ids) public memberFonds;
  mapping(address member => uint256[] withdraws) public memberWithdrawals;
  mapping(address token => bool status) public allowedTokens;
  
}
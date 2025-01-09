// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';

contract Deploy is Common {
  function run(address _admin) public {
    vm.startBroadcast();

    _deployContracts(_admin);

    vm.stopBroadcast();
  }
}

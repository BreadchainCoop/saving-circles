// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';

contract Deploy is Common {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    vm.startBroadcast();

    Deployment memory deployment = _deployAll(admin);
    _allowlistToken(deployment, _tokenToAllowlist());

    vm.stopBroadcast();
  }
}

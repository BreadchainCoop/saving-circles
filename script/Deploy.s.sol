// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Common} from 'script/Common.sol';

contract Deploy is Common {
  // Hard-coded Sepolia admin for testnet deploys
  // TODO: For mainnet, parameterize this instead of hardcoding.
  address constant ADMIN = 0xB11865e35A9dAaD8050AA67A6808776EC0Ad2E34;

  function run() public {
    vm.startBroadcast();

    _deployContracts(ADMIN);

    vm.stopBroadcast();
  }
}

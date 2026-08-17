// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IYieldModule
 * @notice Minimal surface of a crowdstake.fun yield module / stake pool that the
 *         saving-circles integration consumes.
 * @dev Mirrors `BreadchainCoop/crowdstake.fun` `contracts/src/interfaces/IYieldModule.sol`.
 *      The concrete Gnosis implementation is `PoolNativeYield` / `SexyDaiYield`
 *      (WXDAI/xDAI -> sDAI ERC-4626), deployed per `contracts/deployments/gnosis.json`.
 *
 *      Deposit model: `mint(amount, receiver)` pulls `amount` of the module's
 *      UNDERLYING asset from the caller and credits `receiver` with principal.
 *      `burn(amount, receiver)` redeems `amount` of principal and sends the
 *      underlying to `receiver`. Yield accrues on top of principal and is read
 *      via `yieldAccrued()` and pulled via `claimYield(amount, receiver)`.
 */
interface IYieldModule {
  /// @notice Stake `amount` of the underlying (pulled from caller) crediting `receiver`.
  function mint(uint256 amount, address receiver) external;

  /// @notice Redeem `amount` of principal, sending the underlying asset to `receiver`.
  function burn(uint256 amount, address receiver) external;

  /// @notice Claim `amount` of accrued yield, sending the underlying asset to `receiver`.
  function claimYield(uint256 amount, address receiver) external;

  /// @notice Total yield currently accrued to this holder and available to claim.
  function yieldAccrued() external view returns (uint256);
}

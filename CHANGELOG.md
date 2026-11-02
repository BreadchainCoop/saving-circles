# Changelog

## [1.2.0](https://github.com/BreadchainCoop/saving-circles/compare/v1.1.0...v1.2.0) (2026-11-02)


### Features

* a reclaim closes the grant and writes off the rest ([6967cf0](https://github.com/BreadchainCoop/saving-circles/commit/6967cf0ee2217e21901a027dc78bb1ac650aa2f8))
* add conditional grants (advance + grant on pay-back) with escrow yield ([cac8338](https://github.com/BreadchainCoop/saving-circles/commit/cac8338f216b4b497e805e1beb9bc0126174120e))
* add Polygon and Amoy deploy script ([a4b4b1e](https://github.com/BreadchainCoop/saving-circles/commit/a4b4b1e3bc7b979d144dabe2c30510637efbfe93))
* add reclaim grace period and unreleased-grant fallback ([e11912b](https://github.com/BreadchainCoop/saving-circles/commit/e11912b2913b9a15c287089b4eda6f614c98ea5b))
* add step-up microloans with escrow yield ([e211e0a](https://github.com/BreadchainCoop/saving-circles/commit/e211e0a72330b25c9faad32d7eb8bb28ded21a3b))
* allow open-ended conditional grants with a notice period for setting a deadline ([a1a2208](https://github.com/BreadchainCoop/saving-circles/commit/a1a22086cdee949a9fd88546947ee60278affb9f))
* let the mainnet deploy use a single-wallet admin ([c315549](https://github.com/BreadchainCoop/saving-circles/commit/c315549e85f35fa0cbb2dfdbd116363e35043646))
* optional fee on conditional grants, paid in cash or from the grant ([b63e97e](https://github.com/BreadchainCoop/saving-circles/commit/b63e97ed498025d87198dca3c7f8f095ad5599dc))
* store the agreement with the grant; accept no longer takes a terms hash ([fae91aa](https://github.com/BreadchainCoop/saving-circles/commit/fae91aa5f6c9b0fc103adc0f90f2e28884b47347))


### Bug Fixes

* bound fees and deadlines, harden the deploy script, add an invariant suite ([e28c0b1](https://github.com/BreadchainCoop/saving-circles/commit/e28c0b16ae1cc7990edce65c5cb66a2ebd52f0bf))
* keep the deployed storage layout so existing proxies can upgrade ([183fc78](https://github.com/BreadchainCoop/saving-circles/commit/183fc78df737f02c2a5796d9c0111919353fca84))

## [1.1.0](https://github.com/BreadchainCoop/saving-circles/compare/v1.0.0...v1.1.0) (2026-10-05)


### Features

* add goal saving circles ([eb8955c](https://github.com/BreadchainCoop/saving-circles/commit/eb8955c68469ea72328cfc85f94f1a7678f16ba1))
* add goal saving circles for target-based group savings ([da582ca](https://github.com/BreadchainCoop/saving-circles/commit/da582ca4aa62bf9e1e503ff901e8af0a4497b2cc))
* add owner-only addMembers to goal saving circles ([6f6daa9](https://github.com/BreadchainCoop/saving-circles/commit/6f6daa91f3094ffeab9caec85a861cf3c520ca35))


### Bug Fixes

* reject goal contract and token as beneficiary at create ([f3a9edc](https://github.com/BreadchainCoop/saving-circles/commit/f3a9edc793f8f8e22c58b9ee2728ae22cbde5ca2))

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {InviteGenerator} from 'script/InviteGenerator.sol';

contract InviteGeneratorUnit is Test {
  InviteGenerator internal _inviteGenerator;
  bytes32 internal constant _INVITE_SIGNING_DOMAIN_HASH =
    0xf50d3e48fa87e894899f86eba14c57c836bc6ffddd68251a158269ffdadc0cb1;
  bytes32 internal constant _INVITE_SIGNATURE_VERSION_HASH =
    0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;
  uint256 internal constant _STRUCT_ID = 1;
  uint256 internal constant _NONCE = 1;
  uint256 internal constant _CHAIN_ID = 1;
  address internal _VERIFYING_CONTRACT;
  uint256 internal _OWNER_PRIVATE_KEY;
  address internal _OWNER_ADDRESS;

  function setUp() public {
    _inviteGenerator = new InviteGenerator(_INVITE_SIGNING_DOMAIN_HASH, _INVITE_SIGNATURE_VERSION_HASH);
    _VERIFYING_CONTRACT = address(_inviteGenerator);
    (_OWNER_ADDRESS, _OWNER_PRIVATE_KEY) = makeAddrAndKey('owner');
  }

  function test_shouldReturnsHashInvite() public {
    bytes32 expectedHash =
      keccak256(abi.encodePacked(keccak256('Invite(uint256 id,uint256 nonce)'), _STRUCT_ID, _NONCE));
    bytes32 actualHash = _inviteGenerator.hashInvite(_STRUCT_ID, _NONCE);
    assertEq(expectedHash, actualHash);
  }

  function test_shouldReturnsDomainSeparator() public {
    bytes32 expectedDomainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        _INVITE_SIGNING_DOMAIN_HASH,
        _INVITE_SIGNATURE_VERSION_HASH,
        _CHAIN_ID,
        _VERIFYING_CONTRACT
      )
    );
    bytes32 actualDomainSeparator = _inviteGenerator.domainSeparator(_CHAIN_ID, _VERIFYING_CONTRACT);
    assertEq(expectedDomainSeparator, actualDomainSeparator);
  }

  function test_shouldReturnsInviteDigest() public {
    bytes32 structHash = _inviteGenerator.hashInvite(_STRUCT_ID, _NONCE);
    bytes32 domainSeparator = _inviteGenerator.domainSeparator(_CHAIN_ID, _VERIFYING_CONTRACT);
    bytes32 expectedDigest = keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
    bytes32 actualDigest = _inviteGenerator.inviteDigest(_STRUCT_ID, _NONCE, _CHAIN_ID, _VERIFYING_CONTRACT);
    assertEq(expectedDigest, actualDigest);
  }

  function test_shouldGeneratesOneInvite() public {
    vm.chainId(_CHAIN_ID);

    bytes memory signature =
      _inviteGenerator.generateInvite(_OWNER_PRIVATE_KEY, _STRUCT_ID, _NONCE, _VERIFYING_CONTRACT);

    assertEq(signature.length, 65);

    bytes32 digest = _inviteGenerator.inviteDigest(_STRUCT_ID, _NONCE, _CHAIN_ID, _VERIFYING_CONTRACT);
    address recoveredSigner = _recoverSigner(signature, digest);

    assertEq(recoveredSigner, _OWNER_ADDRESS);
  }

  function test_shouldGeneratesMultipleInvites() public {
    vm.chainId(_CHAIN_ID);
    uint256[] memory nonces = new uint256[](3);
    for (uint256 i = 0; i < nonces.length; i++) {
      nonces[i] = _NONCE + i;
    }

    bytes[] memory signatures =
      _inviteGenerator.generateInvites(_OWNER_PRIVATE_KEY, _STRUCT_ID, nonces, _VERIFYING_CONTRACT);

    assertEq(signatures.length, nonces.length);

    for (uint256 i = 0; i < signatures.length; i++) {
      assertEq(signatures[i].length, 65);

      bytes32 digest = _inviteGenerator.inviteDigest(_STRUCT_ID, nonces[i], _CHAIN_ID, _VERIFYING_CONTRACT);
      address recoveredSigner = _recoverSigner(signatures[i], digest);

      assertEq(recoveredSigner, _OWNER_ADDRESS);

      if (i > 0) {
        assertFalse(keccak256(signatures[i]) == keccak256(signatures[i - 1]));
      }
    }
  }

  function _recoverSigner(bytes memory signature, bytes32 digest) private pure returns (address) {
    (bytes32 r, bytes32 s, uint8 v) = _splitSignature(signature);
    return ecrecover(digest, v, r, s);
  }

  function _splitSignature(bytes memory signature) private pure returns (bytes32 r, bytes32 s, uint8 v) {
    assert(signature.length == 65);

    uint256 rAccumulator;
    uint256 sAccumulator;

    for (uint256 i = 0; i < 32; i++) {
      rAccumulator = (rAccumulator << 8) | uint8(signature[i]);
      sAccumulator = (sAccumulator << 8) | uint8(signature[32 + i]);
    }

    r = bytes32(rAccumulator);
    s = bytes32(sAccumulator);
    v = uint8(signature[64]);

    if (v < 27) {
      v += 27;
    }
  }
}

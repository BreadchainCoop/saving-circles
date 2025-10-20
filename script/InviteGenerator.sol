// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from 'forge-std/Script.sol';

/// @title InviteGenerator
/// @author @exo404
/// @author @RonTuretzky
/// @notice Utility contract that produces EIP712 invite signatures matching the on-chain verification logic
contract InviteGenerator is Script {
  /// @notice Hashed domain name used for EIP-712 signatures
  bytes32 private _inviteDomainNameHash;

  /// @notice Hashed signing version used for EIP-712 signatures
  bytes32 private _inviteDomainVersionHash;

  /// @notice EIP-712 type hash for invite signatures
  bytes32 private _inviteTypeHash;

  /// @notice EIP-712 domain type hash
  bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  /// @notice Error for empty invite signing domain
  error InvalidSigningDomain();

  /// @notice Error for empty invite signature version
  error InvalidSignatureVersion();

  constructor(string memory inviteSigningDomain, string memory inviteSignatureVersion, string memory structName) {
    if (bytes(inviteSigningDomain).length == 0) revert InvalidSigningDomain();
    if (bytes(inviteSignatureVersion).length == 0) revert InvalidSignatureVersion();
    _inviteDomainNameHash = keccak256(bytes(inviteSigningDomain));
    _inviteDomainVersionHash = keccak256(bytes(inviteSignatureVersion));
    string memory inviteTypeString = string(abi.encodePacked('Invite(uint256 ', structName, 'Id,uint256 nonce)'));
    _inviteTypeHash = keccak256(bytes(inviteTypeString));
  }

  /// @notice Returns the struct hash of an invite
  function hashInvite(uint256 _structId, uint256 _nonce) public view returns (bytes32) {
    return keccak256(abi.encode(_inviteTypeHash, _structId, _nonce));
  }

  /// @notice Returns the domain separator for a struct contract on a given chain
  function domainSeparator(uint256 _chainId, address _verifyingContract) public view returns (bytes32) {
    return keccak256(
      abi.encode(_EIP712_DOMAIN_TYPEHASH, _inviteDomainNameHash, _inviteDomainVersionHash, _chainId, _verifyingContract)
    );
  }

  /// @notice Computes the full EIP-712 digest for a struct invite
  function inviteDigest(
    uint256 _structId,
    uint256 _nonce,
    uint256 _chainId,
    address _verifyingContract
  ) public view returns (bytes32) {
    return keccak256(
      abi.encodePacked('\x19\x01', domainSeparator(_chainId, _verifyingContract), hashInvite(_structId, _nonce))
    );
  }

  /// @notice Generates a single invite signature using the configured chain id
  /// @param _privateKey Private key of the struct owner
  /// @param _structId Struct identifier
  /// @param _nonce Unique nonce for the invite
  /// @param _verifyingContract Address of the struct contract instance
  function generateInvite(
    uint256 _privateKey,
    uint256 _structId,
    uint256 _nonce,
    address _verifyingContract
  ) external view returns (bytes memory) {
    return _generateInvite(_privateKey, _structId, _nonce, block.chainid, _verifyingContract);
  }

  /// @notice Generates multiple invite signatures using the configured chain id
  function generateInvites(
    uint256 _privateKey,
    uint256 _structId,
    uint256[] calldata _nonces,
    address _verifyingContract
  ) external view returns (bytes[] memory _signatures) {
    _signatures = new bytes[](_nonces.length);
    for (uint256 i = 0; i < _nonces.length; i++) {
      _signatures[i] = _generateInvite(_privateKey, _structId, _nonces[i], block.chainid, _verifyingContract);
    }
    return _signatures;
  }

  function _generateInvite(
    uint256 _privateKey,
    uint256 _structId,
    uint256 _nonce,
    uint256 _chainId,
    address _verifyingContract
  ) private view returns (bytes memory) {
    bytes32 _digest = inviteDigest(_structId, _nonce, _chainId, _verifyingContract);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, _digest);
    return abi.encodePacked(r, s, v);
  }
}

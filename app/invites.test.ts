import { describe, expect, it } from 'vitest';
import { TypedDataEncoder, Wallet, id, verifyTypedData } from 'ethers';
import { buildInviteTypedData, buildInviteUrl, INVITE_TYPEHASH } from './invites';

describe('invite helper utilities', () => {
  it('matches the contract Invite typehash', () => {
    expect(id('Invite(uint256 id,uint256 nonce)')).toBe(INVITE_TYPEHASH);
  });

  it('signs and verifies an invite payload', async () => {
    const wallet = Wallet.createRandom();
    const typed = buildInviteTypedData(1n, 42n, 1337n, '0x000000000000000000000000000000000000dEaD');
    const signature = await wallet.signTypedData(typed.domain, typed.types, typed.message);
    const recovered = verifyTypedData(typed.domain, typed.types, typed.message, signature);

    expect(recovered).toBe(wallet.address);

    const digest = TypedDataEncoder.hash(typed.domain, typed.types, typed.message);
    expect(digest.startsWith('0x')).toBe(true);
  });

  it('builds a shareable URL with all invite params', () => {
    const url = buildInviteUrl('https://app.test/invite', '0xabc', 5n, 9n, '0xsig');
    expect(url).toContain('circleId=5');
    expect(url).toContain('nonce=9');
    expect(url).toContain('signature=0xsig');
    expect(url).toContain('contract=0xabc');
  });
});

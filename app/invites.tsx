import { useCallback, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import type { TypedDataDomain, TypedDataField } from 'ethers';
import { BrowserProvider, Contract } from 'ethers';

const PRIVY_APP_ID = (import.meta as any).env?.VITE_PRIVY_APP_ID ?? 'privy-app-id';
const DEFAULT_SAVING_CIRCLES_ADDRESS =
  (import.meta as any).env?.VITE_SAVING_CIRCLES_ADDRESS ?? '0x0000000000000000000000000000000000000000';

export const INVITE_TYPEHASH = '0xd86e498a74dbfe863d870d4811dddab9c7f3922d6c0d6656504984bd9a8607a3';
export const INVITE_DOMAIN_NAME = 'StacksInvite';
export const INVITE_DOMAIN_VERSION = '1';

const savingCirclesAbi = [
  'function usedNonces(uint256 id, uint256 nonce) view returns (bool)',
  'function redeemInvite(uint256 id, uint256 nonce, bytes signature)',
  'function isMember(uint256 id, address member) view returns (bool)',
  'function owner() view returns (address)'
] as const;

type InviteTypes = { Invite: TypedDataField[] };
type InviteMessage = { id: bigint; nonce: bigint };
export type InviteTypedData = {
  domain: TypedDataDomain;
  types: InviteTypes;
  message: InviteMessage;
};

type PrivyWallet = {
  address?: string;
  chainId?: number;
  walletClientType?: string;
  getEthersProvider?: () => Promise<any>;
  getEthereumProvider?: () => Promise<any>;
};

type InviteLink = {
  nonce: bigint;
  signature: string;
  url: string;
  used?: boolean;
};

type PrivyHooks = {
  PrivyProvider: (props: { appId: string; children?: ReactNode }) => JSX.Element | null;
  usePrivy: () => { ready: boolean; authenticated: boolean; user?: any; login: () => void; logout: () => void };
  useWallets: () => { ready: boolean; wallets: PrivyWallet[] };
};

let PrivyProvider: PrivyHooks['PrivyProvider'];
let usePrivy: PrivyHooks['usePrivy'];
let useWallets: PrivyHooks['useWallets'];

await import('@privy-io/react-auth')
  .then((sdk: PrivyHooks) => {
    PrivyProvider = sdk.PrivyProvider;
    usePrivy = sdk.usePrivy;
    useWallets = sdk.useWallets;
  })
  .catch(() => {
    const fallback: PrivyHooks = {
      PrivyProvider: ({ children }) => <>{children}</>,
      usePrivy: () => ({ ready: true, authenticated: false, user: undefined, login: () => {}, logout: () => {} }),
      useWallets: () => ({ ready: true, wallets: [] })
    };
    PrivyProvider = fallback.PrivyProvider;
    usePrivy = fallback.usePrivy;
    useWallets = fallback.useWallets;
  });

export function buildInviteTypedData(
  circleId: bigint,
  nonce: bigint,
  chainId: bigint | number,
  contractAddress: string
): InviteTypedData {
  return {
    domain: {
      name: INVITE_DOMAIN_NAME,
      version: INVITE_DOMAIN_VERSION,
      chainId,
      verifyingContract: contractAddress
    },
    types: {
      Invite: [
        { name: 'id', type: 'uint256' },
        { name: 'nonce', type: 'uint256' }
      ]
    },
    message: { id: circleId, nonce }
  };
}

export function buildInviteUrl(
  baseUrl: string,
  contractAddress: string,
  circleId: bigint,
  nonce: bigint,
  signature: string
): string {
  const url = new URL(baseUrl);
  url.searchParams.set('contract', contractAddress);
  url.searchParams.set('circleId', circleId.toString());
  url.searchParams.set('nonce', nonce.toString());
  url.searchParams.set('signature', signature);
  return url.toString();
}

function formatError(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  return 'Unknown error';
}

async function getSignerFromPrivyWallet(wallet: PrivyWallet) {
  if (wallet.getEthersProvider) {
    const provider = await wallet.getEthersProvider();
    if (provider?.getSigner) return provider.getSigner();
  }
  if (wallet.getEthereumProvider) {
    const browserProvider = new BrowserProvider(await wallet.getEthereumProvider());
    return browserProvider.getSigner();
  }
  throw new Error('Privy wallet cannot provide a signer');
}

async function signInvite(signer: any, typedData: InviteTypedData): Promise<string> {
  if (typeof signer?.signTypedData === 'function') {
    return signer.signTypedData(typedData.domain, typedData.types, typedData.message);
  }
  if (typeof signer?._signTypedData === 'function') {
    const { name, version, chainId, verifyingContract } = typedData.domain;
    return signer._signTypedData(
      { name, version, chainId, verifyingContract },
      typedData.types,
      typedData.message
    );
  }
  const provider = signer?.provider as BrowserProvider | undefined;
  if (provider?.send) {
    const from = await signer.getAddress();
    return provider.send('eth_signTypedData_v4', [
      from,
      {
        domain: typedData.domain,
        types: { ...typedData.types, EIP712Domain: [] },
        primaryType: 'Invite',
        message: typedData.message
      }
    ]);
  }
  throw new Error('Signer does not support EIP-712');
}

async function refreshInviteStatuses(contract: Contract, circleId: bigint, invites: InviteLink[]) {
  const statuses = await Promise.all(
    invites.map(async (invite) => ({
      ...invite,
      used: await contract.usedNonces(circleId, invite.nonce)
    }))
  );
  return statuses;
}

function inviteStatusLabel(invite: InviteLink) {
  if (invite.used === true) return 'claimed';
  if (invite.used === false) return 'open';
  return 'checking...';
}

function SavingCircleInvitesContent() {
  const { ready: privyReady, authenticated, user, login, logout } = usePrivy();
  const { wallets, ready: walletsReady } = useWallets();

  const [contractAddress, setContractAddress] = useState(DEFAULT_SAVING_CIRCLES_ADDRESS);
  const [circleId, setCircleId] = useState('');
  const [inviteCount, setInviteCount] = useState(3);
  const [status, setStatus] = useState('');
  const [invites, setInvites] = useState<InviteLink[]>([]);
  const [isGenerating, setIsGenerating] = useState(false);
  const [isRedeeming, setIsRedeeming] = useState(false);
  const [redeemNonce, setRedeemNonce] = useState('');
  const [redeemSignature, setRedeemSignature] = useState('');

  const activeWallet = useMemo(() => wallets.find((w) => w.walletClientType === 'privy') ?? wallets[0], [wallets]);
  const parsedCircleId = useMemo(() => {
    try {
      return BigInt(circleId);
    } catch (_err) {
      return null;
    }
  }, [circleId]);

  const ready = privyReady && walletsReady;

  const generateInvites = useCallback(async () => {
    if (!authenticated) {
      login();
      return;
    }
    if (!ready) {
      setStatus('Waiting for Privy to finish loading the wallet.');
      return;
    }
    if (!activeWallet) {
      setStatus('Connect a Privy wallet to create invites.');
      return;
    }
    if (!parsedCircleId) {
      setStatus('Circle id must be a number.');
      return;
    }
    if (!contractAddress) {
      setStatus('SavingCircles contract address is required.');
      return;
    }
    const invitesToCreate = Number.isFinite(inviteCount) && inviteCount > 0 ? inviteCount : 1;

    setIsGenerating(true);
    try {
      const signer = await getSignerFromPrivyWallet(activeWallet);
      const network = await signer.provider?.getNetwork();
      const chainId = network?.chainId ?? 0n;
      const contract = new Contract(contractAddress, savingCirclesAbi, signer);
      const baseUrl =
        typeof window === 'undefined' ? 'https://savingcircles.local/invite' : `${window.location.origin}/invite`;

      const generated: InviteLink[] = [];
      let candidate = BigInt(Date.now());
      while (generated.length < invitesToCreate) {
        const alreadyUsed = await contract.usedNonces(parsedCircleId, candidate);
        if (!alreadyUsed) {
          const typedData = buildInviteTypedData(parsedCircleId, candidate, chainId, contractAddress);
          const signature = await signInvite(signer, typedData);
          const url = buildInviteUrl(baseUrl, contractAddress, parsedCircleId, candidate, signature);
          generated.push({ nonce: candidate, signature, url, used: false });
        }
        candidate += 1n;
      }

      setStatus(`Created ${generated.length} invite${generated.length === 1 ? '' : 's'}.`);
      setInvites(await refreshInviteStatuses(contract, parsedCircleId, generated));
    } catch (error) {
      setStatus(`Invite creation failed: ${formatError(error)}`);
    } finally {
      setIsGenerating(false);
    }
  }, [activeWallet, authenticated, contractAddress, inviteCount, login, parsedCircleId, ready]);

  const redeemInvite = useCallback(async () => {
    if (!authenticated) {
      login();
      return;
    }
    if (!ready) {
      setStatus('Waiting for Privy.');
      return;
    }
    if (!activeWallet) {
      setStatus('Connect a Privy wallet to redeem.');
      return;
    }
    if (!parsedCircleId) {
      setStatus('Circle id must be a number.');
      return;
    }
    if (!contractAddress) {
      setStatus('SavingCircles contract address is required.');
      return;
    }
    let nonce: bigint;
    try {
      nonce = BigInt(redeemNonce);
    } catch (_err) {
      setStatus('Nonce must be a number.');
      return;
    }
    if (!redeemSignature) {
      setStatus('Paste the invite signature to redeem.');
      return;
    }

    setIsRedeeming(true);
    try {
      const signer = await getSignerFromPrivyWallet(activeWallet);
      const contract = new Contract(contractAddress, savingCirclesAbi, signer);
      const tx = await contract.redeemInvite(parsedCircleId, nonce, redeemSignature.trim());
      await tx.wait?.();
      setStatus(`Redeemed invite ${nonce.toString()} for circle ${parsedCircleId.toString()}.`);
      setInvites((prev) =>
        prev.map((invite) => (invite.nonce === nonce ? { ...invite, used: true } : invite))
      );
    } catch (error) {
      setStatus(`Redeem failed: ${formatError(error)}`);
    } finally {
      setIsRedeeming(false);
    }
  }, [activeWallet, authenticated, contractAddress, login, parsedCircleId, ready, redeemNonce, redeemSignature]);

  const refreshStatuses = useCallback(async () => {
    if (!activeWallet || !parsedCircleId || invites.length === 0 || !contractAddress) return;
    try {
      const signer = await getSignerFromPrivyWallet(activeWallet);
      const contract = new Contract(contractAddress, savingCirclesAbi, signer);
      setInvites(await refreshInviteStatuses(contract, parsedCircleId, invites));
      setStatus('Invite statuses refreshed from SavingCircles.');
    } catch (error) {
      setStatus(`Refresh failed: ${formatError(error)}`);
    }
  }, [activeWallet, contractAddress, invites, parsedCircleId]);

  return (
    <div
      style={{
        margin: '24px auto',
        maxWidth: 720,
        padding: 24,
        border: '1px solid #e2e8f0',
        borderRadius: 12,
        fontFamily: 'Inter, system-ui, sans-serif',
        background: 'linear-gradient(120deg, #f8fafc 0%, #f1f5f9 100%)'
      }}
    >
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
        <div>
          <h2 style={{ margin: 0 }}>Saving Circle Invites</h2>
          <p style={{ margin: '4px 0 0 0', color: '#475569' }}>
            Generate EIP-712 invite links with your Privy wallet and keep them in sync with the SavingCircles contract.
          </p>
        </div>
        <button
          type="button"
          onClick={() => (authenticated ? logout() : login())}
          style={{
            padding: '8px 14px',
            borderRadius: 10,
            border: '1px solid #0f172a',
            background: authenticated ? '#0f172a' : 'white',
            color: authenticated ? 'white' : '#0f172a',
            cursor: 'pointer'
          }}
        >
          {authenticated ? 'Sign out of Privy' : 'Connect Privy'}
        </button>
      </header>

      <section style={{ marginBottom: 18 }}>
        <label style={{ display: 'block', marginBottom: 6, fontWeight: 600 }}>
          SavingCircles contract address
        </label>
        <input
          value={contractAddress}
          onChange={(event) => setContractAddress(event.target.value)}
          placeholder="0x..."
          style={{
            width: '100%',
            padding: '10px 12px',
            borderRadius: 10,
            border: '1px solid #cbd5e1',
            fontSize: 14
          }}
        />
      </section>

      <section
        style={{
          display: 'grid',
          gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
          gap: 12,
          marginBottom: 18
        }}
      >
        <div>
          <label style={{ display: 'block', marginBottom: 6, fontWeight: 600 }}>Circle id</label>
          <input
            value={circleId}
            onChange={(event) => setCircleId(event.target.value)}
            placeholder="e.g. 0"
            style={{
              width: '100%',
              padding: '10px 12px',
              borderRadius: 10,
              border: '1px solid #cbd5e1',
              fontSize: 14
            }}
          />
        </div>
        <div>
          <label style={{ display: 'block', marginBottom: 6, fontWeight: 600 }}>Number of invites</label>
          <input
            type="number"
            min={1}
            value={inviteCount}
            onChange={(event) => setInviteCount(Number(event.target.value))}
            style={{
              width: '100%',
              padding: '10px 12px',
              borderRadius: 10,
              border: '1px solid #cbd5e1',
              fontSize: 14
            }}
          />
        </div>
      </section>

      <div style={{ display: 'flex', gap: 10, marginBottom: 22, flexWrap: 'wrap' }}>
        <button
          type="button"
          onClick={generateInvites}
          disabled={isGenerating}
          style={{
            padding: '10px 16px',
            borderRadius: 10,
            border: 'none',
            background: '#0f172a',
            color: 'white',
            cursor: 'pointer',
            minWidth: 180
          }}
        >
          {isGenerating ? 'Signing invites...' : 'Generate invite links'}
        </button>
        <button
          type="button"
          onClick={refreshStatuses}
          style={{
            padding: '10px 16px',
            borderRadius: 10,
            border: '1px solid #0f172a',
            background: 'white',
            color: '#0f172a',
            cursor: 'pointer'
          }}
        >
          Refresh invite status
        </button>
      </div>

      <section style={{ marginBottom: 22 }}>
        <h3 style={{ margin: '0 0 8px 0' }}>Redeem an invite</h3>
        <p style={{ margin: '0 0 10px 0', color: '#475569' }}>
          Paste a signed invite to redeem it for the connected Privy wallet. This calls SavingCircles.redeemInvite.
        </p>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))',
            gap: 10,
            marginBottom: 10
          }}
        >
          <input
            value={redeemNonce}
            onChange={(event) => setRedeemNonce(event.target.value)}
            placeholder="Nonce"
            style={{
              width: '100%',
              padding: '10px 12px',
              borderRadius: 10,
              border: '1px solid #cbd5e1',
              fontSize: 14
            }}
          />
          <input
            value={redeemSignature}
            onChange={(event) => setRedeemSignature(event.target.value)}
            placeholder="Invite signature (0x...)"
            style={{
              width: '100%',
              padding: '10px 12px',
              borderRadius: 10,
              border: '1px solid #cbd5e1',
              fontSize: 14
            }}
          />
        </div>
        <button
          type="button"
          onClick={redeemInvite}
          disabled={isRedeeming}
          style={{
            padding: '10px 16px',
            borderRadius: 10,
            border: 'none',
            background: '#22c55e',
            color: '#0f172a',
            cursor: 'pointer'
          }}
        >
          {isRedeeming ? 'Redeeming invite...' : 'Redeem invite with Privy'}
        </button>
      </section>

      <section style={{ marginBottom: 14 }}>
        <h3 style={{ margin: '0 0 8px 0' }}>Invite links</h3>
        {invites.length === 0 ? (
          <p style={{ margin: 0, color: '#475569' }}>No invites generated yet.</p>
        ) : (
          <ul style={{ listStyle: 'none', padding: 0, margin: 0 }}>
            {invites.map((invite) => (
              <li
                key={invite.nonce.toString()}
                style={{
                  padding: '12px 14px',
                  borderRadius: 10,
                  border: '1px solid #cbd5e1',
                  background: 'white',
                  marginBottom: 10
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
                  <div>
                    <strong>Nonce:</strong> {invite.nonce.toString()}
                    <span
                      style={{
                        marginLeft: 10,
                        padding: '2px 8px',
                        background: invite.used ? '#fee2e2' : '#dcfce7',
                        color: '#0f172a',
                        borderRadius: 8,
                        fontSize: 12
                      }}
                    >
                      {inviteStatusLabel(invite)}
                    </span>
                  </div>
                  <div style={{ fontFamily: 'monospace', fontSize: 12, wordBreak: 'break-all' }}>{invite.signature}</div>
                </div>
                <a
                  href={invite.url}
                  style={{ display: 'block', marginTop: 8, color: '#2563eb', wordBreak: 'break-all' }}
                  target="_blank"
                  rel="noreferrer"
                >
                  {invite.url}
                </a>
              </li>
            ))}
          </ul>
        )}
      </section>

      {status && (
        <div
          style={{
            marginTop: 12,
            padding: '10px 12px',
            borderRadius: 10,
            background: '#e0f2fe',
            color: '#0f172a'
          }}
        >
          {status}
        </div>
      )}
      <footer style={{ marginTop: 10, color: '#475569', fontSize: 12 }}>
        Connected as {user?.wallet?.address ?? activeWallet?.address ?? 'not connected'}
      </footer>
    </div>
  );
}

export default function SavingCircleInvitesPage() {
  return (
    <PrivyProvider appId={PRIVY_APP_ID}>
      <SavingCircleInvitesContent />
    </PrivyProvider>
  );
}

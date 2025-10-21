import { useCallback, useState } from 'react';
import type { BrowserProvider } from 'ethers';
import { Contract } from 'ethers';

import savingCirclesArtifact from '../out/SavingCircles.sol/SavingCircles.json';

const savingCirclesAbi = savingCirclesArtifact.abi;

export type InvitePayload = {
  circleId: bigint;
  nonce: bigint;
  signature: string;
};

export type RedeemInviteButtonProps = {
  provider: BrowserProvider;
  contractAddress: string;
  invite: InvitePayload;
  onRedeemed?: (txHash: string) => void;
  className?: string;
};

export function RedeemInviteButton({
  provider,
  contractAddress,
  invite,
  onRedeemed,
  className
}: RedeemInviteButtonProps) {
  const [isRedeeming, setIsRedeeming] = useState(false);
  const [txHash, setTxHash] = useState<string | undefined>();
  const [error, setError] = useState<string | undefined>();

  const redeemInvite = useCallback(async () => {
    setIsRedeeming(true);
    setError(undefined);
    setTxHash(undefined);

    try {
      const signer = await provider.getSigner();
      const contract = new Contract(contractAddress, savingCirclesAbi, signer);

      const tx = await contract.redeemInvite(invite.circleId, invite.nonce, invite.signature);
      const receipt = await tx.wait();
      const finalHash = receipt?.hash ?? receipt?.transactionHash ?? tx.hash;

      setTxHash(finalHash);
      onRedeemed?.(finalHash);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setIsRedeeming(false);
    }
  }, [provider, contractAddress, invite.circleId, invite.nonce, invite.signature, onRedeemed]);

  return (
    <div className={className}>
      <button type="button" disabled={isRedeeming} onClick={redeemInvite} data-testid="redeem-button">
        {isRedeeming ? 'Redeeming...' : 'Redeem Invite'}
      </button>

      {txHash ? (
        <p data-testid="redeem-success">Invite redeemed in transaction {txHash}</p>
      ) : null}
      {error ? <p data-testid="redeem-error">Invite failed: {error}</p> : null}
    </div>
  );
}

export default RedeemInviteButton;

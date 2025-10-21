import { FormEvent, useCallback, useMemo, useState } from 'react';
import type { BrowserProvider } from 'ethers';
import { Contract } from 'ethers';

import inviteGeneratorArtifact from '../out/InviteGenerator.sol/InviteGenerator.json';

const inviteGeneratorAbi = inviteGeneratorArtifact.abi;

type GeneratedInvite = {
  circleId: bigint;
  nonce: bigint;
  verifyingContract: string;
  signature: string;
  digest: string;
};

export type GenerateInviteFormProps = {
  provider: BrowserProvider;
  inviteGeneratorAddress: string;
  className?: string;
  defaultCircleId?: string;
  defaultVerifyingContract?: string;
  defaultNonce?: string;
  onGenerated?: (invite: GeneratedInvite) => void;
};

export function GenerateInviteForm({
  provider,
  inviteGeneratorAddress,
  className,
  defaultCircleId = '0',
  defaultVerifyingContract = '',
  defaultNonce = '0',
  onGenerated
}: GenerateInviteFormProps) {
  const [circleIdInput, setCircleIdInput] = useState(defaultCircleId);
  const [verifyingContractInput, setVerifyingContractInput] = useState(defaultVerifyingContract);
  const [nonceInput, setNonceInput] = useState(defaultNonce);
  const [privateKeyInput, setPrivateKeyInput] = useState('');

  const [isGenerating, setIsGenerating] = useState(false);
  const [error, setError] = useState<string | undefined>();
  const [signature, setSignature] = useState<string | undefined>();
  const [digest, setDigest] = useState<string | undefined>();

  const isActionDisabled = useMemo(() => {
    return isGenerating || !circleIdInput || !verifyingContractInput || !nonceInput || !privateKeyInput;
  }, [isGenerating, circleIdInput, verifyingContractInput, nonceInput, privateKeyInput]);

  const handleGenerate = useCallback(
    async (event: FormEvent) => {
      event.preventDefault();
      if (isActionDisabled) return;

      setIsGenerating(true);
      setError(undefined);
      setSignature(undefined);
      setDigest(undefined);

      try {
        const circleId = BigInt(circleIdInput);
        const nonce = BigInt(nonceInput);
        const verifyingContract = verifyingContractInput.trim();
        const privateKey = privateKeyInput.trim();
        const normalizedKey = privateKey.startsWith('0x') ? privateKey : `0x${privateKey}`;
        const privateKeyBigInt = BigInt(normalizedKey);

        const contract = new Contract(inviteGeneratorAddress, inviteGeneratorAbi, provider);
        const network = await provider.getNetwork();

        const digestResult: string = await contract.inviteDigest(
          circleId,
          nonce,
          network.chainId,
          verifyingContract
        );

        const signatureResult: string = await contract.generateInvite(
          privateKeyBigInt,
          circleId,
          nonce,
          verifyingContract
        );

        setDigest(digestResult);
        setSignature(signatureResult);
        onGenerated?.({
          circleId,
          nonce,
          verifyingContract,
          signature: signatureResult,
          digest: digestResult
        });
      } catch (err) {
        setError((err as Error).message);
      } finally {
        setIsGenerating(false);
      }
    },
    [
      inviteGeneratorAddress,
      provider,
      isActionDisabled,
      circleIdInput,
      nonceInput,
      verifyingContractInput,
      privateKeyInput,
      onGenerated
    ]
  );

  return (
    <form className={className} onSubmit={handleGenerate}>
      <fieldset disabled={isGenerating}>
        <label>
          Circle ID
          <input
            data-testid="circle-id-input"
            type="number"
            value={circleIdInput}
            onChange={(event) => setCircleIdInput(event.target.value)}
          />
        </label>

        <label>
          Verifying Contract
          <input
            data-testid="verifying-contract-input"
            type="text"
            value={verifyingContractInput}
            onChange={(event) => setVerifyingContractInput(event.target.value)}
          />
        </label>

        <label>
          Nonce
          <input
            data-testid="nonce-input"
            type="number"
            value={nonceInput}
            onChange={(event) => setNonceInput(event.target.value)}
          />
        </label>

        <label>
          Owner Private Key
          <input
            data-testid="private-key-input"
            type="password"
            value={privateKeyInput}
            onChange={(event) => setPrivateKeyInput(event.target.value)}
          />
        </label>
      </fieldset>

      <button data-testid="generate-button" type="submit" disabled={isActionDisabled}>
        {isGenerating ? 'Generating...' : 'Generate Invite'}
      </button>

      {signature ? (
        <p data-testid="invite-signature">Signature: {signature}</p>
      ) : null}
      {digest ? (
        <p data-testid="invite-digest">Digest: {digest}</p>
      ) : null}
      {error ? (
        <p data-testid="invite-error">Failed to generate invite: {error}</p>
      ) : null}
    </form>
  );
}

export default GenerateInviteForm;

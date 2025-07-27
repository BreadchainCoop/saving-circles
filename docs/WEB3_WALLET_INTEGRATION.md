# Web3 Wallet Integration Examples

This document provides examples of how to integrate the off-chain to on-chain circle creation flow with popular web3 wallet providers that support email/social login.

## Magic (magic.link) Integration

Magic allows users to create accounts using just their email address. Here's how to integrate it:

### Frontend JavaScript Example

```javascript
import { Magic } from 'magic-sdk';
import { ethers } from 'ethers';

// Initialize Magic
const magic = new Magic('your-magic-publishable-key');

// User signs up/logs in with email
async function loginWithEmail(email) {
    const didToken = await magic.auth.loginWithMagicLink({ email });
    const userMetadata = await magic.user.getMetadata();
    return userMetadata.publicAddress;
}

// Create pending circle and map email to address
async function createCircleWithEmail(ownerEmail, memberEmails, circleData) {
    // Step 1: Create pending circle on-chain
    const pendingCircle = {
        ownerEmail,
        memberEmails,
        depositAmount: circleData.depositAmount,
        token: circleData.token,
        depositInterval: circleData.depositInterval,
        maxDeposits: circleData.maxDeposits,
        isActive: false
    };
    
    const pendingId = await savingCirclesContract.createPendingCircle(pendingCircle);
    
    // Step 2: For each member that creates an account, map their email
    for (const email of memberEmails) {
        // When user logs in with Magic, get their address
        const userAddress = await loginWithEmail(email);
        
        // Map email to address on-chain
        await savingCirclesContract.mapEmailToAddress(email, userAddress);
    }
    
    return pendingId;
}

// Migrate to on-chain once all members are onboarded
async function migrateCircle(pendingId, circleStart) {
    const circleId = await savingCirclesContract.migratePendingCircle(pendingId, circleStart);
    return circleId;
}
```

## Web3Auth Integration

Web3Auth supports multiple social providers (Google, Facebook, Twitter, etc.):

### Frontend Integration

```javascript
import { Web3Auth } from "@web3auth/modal";
import { CHAIN_NAMESPACES } from "@web3auth/base";

// Initialize Web3Auth
const web3auth = new Web3Auth({
    clientId: "your-web3auth-client-id",
    chainConfig: {
        chainNamespace: CHAIN_NAMESPACES.EIP155,
        chainId: "0x1", // Ethereum mainnet
        rpcTarget: "https://rpc.ankr.com/eth",
    },
});

// User authentication with social providers
async function authenticateUser(email, provider = 'google') {
    const web3authProvider = await web3auth.connectTo('openlogin', {
        loginProvider: provider,
        extraLoginOptions: {
            login_hint: email
        }
    });
    
    const ethersProvider = new ethers.providers.Web3Provider(web3authProvider);
    const signer = ethersProvider.getSigner();
    const address = await signer.getAddress();
    
    return { address, signer };
}

// Circle creation flow with Web3Auth
class CircleManager {
    constructor(contractAddress, contractABI) {
        this.contractAddress = contractAddress;
        this.contractABI = contractABI;
    }
    
    async createPendingCircle(ownerEmail, memberEmails, circleData) {
        // Authenticate owner to create the pending circle
        const { address: ownerAddress, signer } = await authenticateUser(ownerEmail);
        
        const contract = new ethers.Contract(
            this.contractAddress, 
            this.contractABI, 
            signer
        );
        
        // Create pending circle
        const pendingCircle = {
            ownerEmail,
            memberEmails,
            ...circleData,
            isActive: false
        };
        
        const tx = await contract.createPendingCircle(pendingCircle);
        const receipt = await tx.wait();
        
        // Map owner email immediately
        await contract.mapEmailToAddress(ownerEmail, ownerAddress);
        
        return receipt.events.find(e => e.event === 'PendingCircleCreated').args.id;
    }
    
    async onboardMember(email, provider = 'google') {
        const { address, signer } = await authenticateUser(email, provider);
        
        const contract = new ethers.Contract(
            this.contractAddress, 
            this.contractABI, 
            signer
        );
        
        // Map email to address
        await contract.mapEmailToAddress(email, address);
        
        return address;
    }
    
    async checkReadyForMigration(pendingId) {
        const contract = new ethers.Contract(
            this.contractAddress, 
            this.contractABI, 
            ethers.getDefaultProvider()
        );
        
        const pendingCircle = await contract.getPendingCircle(pendingId);
        
        // Check if all emails are mapped
        for (const email of pendingCircle.memberEmails) {
            const address = await contract.getAddressFromEmail(email);
            if (address === ethers.constants.AddressZero) {
                return false;
            }
        }
        
        return true;
    }
}
```

## Account Abstraction Integration

For even smoother UX, integrate with Account Abstraction providers:

### Example with Alchemy's Account Kit

```javascript
import { AlchemyProvider } from "@alchemy/aa-alchemy";
import { LightSmartContractAccount } from "@alchemy/aa-accounts";

async function createAccountFromEmail(email) {
    // Use email-based authentication (Magic, Web3Auth, etc.)
    const emailAuth = await authenticateWithEmail(email);
    
    // Create smart contract account
    const smartAccount = new LightSmartContractAccount({
        chain: mainnet,
        owner: emailAuth.address,
        factoryAddress: "0x...", // Light Account factory
    });
    
    const provider = new AlchemyProvider({
        apiKey: "your-alchemy-key",
        chain: mainnet,
    }).connect(smartAccount);
    
    const accountAddress = await provider.getAddress();
    
    return { address: accountAddress, provider };
}

// Map email to smart contract account address
async function mapEmailToSmartAccount(email) {
    const { address, provider } = await createAccountFromEmail(email);
    
    // Map to the smart contract account address
    await savingCirclesContract.mapEmailToAddress(email, address);
    
    return address;
}
```

## Backend Service Integration

For enterprise use cases, you might want a backend service to manage email mappings:

### Node.js Backend Example

```javascript
const express = require('express');
const { ethers } = require('ethers');

class CircleBackendService {
    constructor(contractAddress, contractABI, privateKey) {
        this.provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
        this.wallet = new ethers.Wallet(privateKey, this.provider);
        this.contract = new ethers.Contract(contractAddress, contractABI, this.wallet);
        this.emailToAddress = new Map(); // In production, use a database
    }
    
    async registerUser(email, walletAddress) {
        // Validate email and address
        if (!this.isValidEmail(email) || !ethers.utils.isAddress(walletAddress)) {
            throw new Error('Invalid email or address');
        }
        
        // Store mapping (in production, use database)
        this.emailToAddress.set(email, walletAddress);
        
        // Map on-chain
        const tx = await this.contract.mapEmailToAddress(email, walletAddress);
        await tx.wait();
        
        return { email, address: walletAddress, txHash: tx.hash };
    }
    
    async createPendingCircleForUser(userEmail, circleData) {
        const pendingCircle = {
            ownerEmail: userEmail,
            memberEmails: circleData.memberEmails,
            depositAmount: circleData.depositAmount,
            token: circleData.token,
            depositInterval: circleData.depositInterval,
            maxDeposits: circleData.maxDeposits,
            isActive: false
        };
        
        const tx = await this.contract.createPendingCircle(pendingCircle);
        const receipt = await tx.wait();
        
        return receipt.events.find(e => e.event === 'PendingCircleCreated').args.id;
    }
    
    async autoMigrateWhenReady(pendingId) {
        const pendingCircle = await this.contract.getPendingCircle(pendingId);
        
        // Check if all members are registered
        const allMapped = pendingCircle.memberEmails.every(email => 
            this.emailToAddress.has(email)
        );
        
        if (allMapped) {
            const circleStart = Math.floor(Date.now() / 1000) + (24 * 60 * 60); // Start in 24 hours
            const tx = await this.contract.migratePendingCircle(pendingId, circleStart);
            const receipt = await tx.wait();
            
            return receipt.events.find(e => e.event === 'CircleMigrated').args.circleId;
        }
        
        return null;
    }
    
    isValidEmail(email) {
        const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
        return emailRegex.test(email);
    }
}

// Express routes
const app = express();
app.use(express.json());

const circleService = new CircleBackendService(
    process.env.CONTRACT_ADDRESS,
    contractABI,
    process.env.PRIVATE_KEY
);

app.post('/register', async (req, res) => {
    try {
        const { email, walletAddress } = req.body;
        const result = await circleService.registerUser(email, walletAddress);
        res.json(result);
    } catch (error) {
        res.status(400).json({ error: error.message });
    }
});

app.post('/create-circle', async (req, res) => {
    try {
        const { userEmail, circleData } = req.body;
        const pendingId = await circleService.createPendingCircleForUser(userEmail, circleData);
        res.json({ pendingId });
    } catch (error) {
        res.status(400).json({ error: error.message });
    }
});
```

## Security Considerations

When integrating with web3 wallet providers:

1. **Email Verification**: Always verify email ownership before mapping to addresses
2. **Access Control**: Ensure only authorized parties can map emails to addresses
3. **Rate Limiting**: Implement rate limiting to prevent spam
4. **Address Validation**: Validate that addresses are properly formatted
5. **Audit Trail**: Log all email-to-address mappings for security audits

## Best Practices

1. **User Experience**: Provide clear onboarding flows explaining the transition from email to wallet
2. **Progressive Enhancement**: Allow users to interact with basic features before full web3 onboarding
3. **Fallback Options**: Provide alternative onboarding methods if social login fails
4. **Mobile Optimization**: Ensure wallet integrations work well on mobile devices
5. **Clear Communication**: Explain to users when they're transitioning from off-chain to on-chain interactions
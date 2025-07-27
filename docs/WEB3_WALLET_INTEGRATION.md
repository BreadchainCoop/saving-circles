# Web3 Wallet Integration Examples

This document provides examples of how to integrate the off-chain to on-chain circle creation flow with Privy, a modern web3 authentication provider that supports email/social login.

## Privy Integration

Privy provides seamless web3 authentication with email, social logins, and embedded wallets. Here's how to integrate it with the saving circles system:

### Frontend JavaScript Example

```javascript
import { PrivyProvider, usePrivy, useWallets } from '@privy-io/react-auth';
import { ethers } from 'ethers';

// Initialize Privy Provider at the app root
function App() {
    return (
        <PrivyProvider
            appId="your-privy-app-id"
            config={{
                loginMethods: ['email', 'google', 'twitter', 'discord'],
                appearance: {
                    theme: 'light',
                    accentColor: '#676FFF',
                },
                embeddedWallets: {
                    createOnLogin: 'users-without-wallets',
                },
            }}
        >
            <SavingCirclesApp />
        </PrivyProvider>
    );
}

// User authentication with Privy
function usePrivyAuth() {
    const { login, logout, authenticated, user } = usePrivy();
    const { wallets } = useWallets();

    const loginWithEmail = async (email) => {
        await login();
        return user?.wallet?.address;
    };

    const getWalletProvider = () => {
        if (wallets.length > 0) {
            return wallets[0].getEthersProvider();
        }
        return null;
    };

    return {
        loginWithEmail,
        getWalletProvider,
        authenticated,
        user,
        userEmail: user?.email?.address,
        userAddress: user?.wallet?.address,
        login,
        logout
    };
}

// Create pending circle and map email to address
async function createCircleWithEmail(ownerEmail, memberEmails, circleData, privyAuth) {
    // Step 1: Ensure owner is authenticated
    if (!privyAuth.authenticated) {
        await privyAuth.login();
    }

    const provider = privyAuth.getWalletProvider();
    const signer = provider.getSigner();
    
    // Step 2: Create pending circle on-chain
    const pendingCircle = {
        ownerEmail,
        memberEmails,
        depositAmount: circleData.depositAmount,
        token: circleData.token,
        depositInterval: circleData.depositInterval,
        maxDeposits: circleData.maxDeposits,
        isActive: false
    };
    
    const contract = new ethers.Contract(
        savingCirclesAddress, 
        savingCirclesABI, 
        signer
    );
    
    const tx = await contract.createPendingCircle(pendingCircle);
    const receipt = await tx.wait();
    const pendingId = receipt.events.find(e => e.event === 'PendingCircleCreated').args.id;
    
    // Step 3: Map owner email immediately
    await contract.mapEmailToAddress(ownerEmail, privyAuth.userAddress);
    
    return pendingId;
}

// Migrate to on-chain once all members are onboarded
async function migrateCircle(pendingId, circleStart, privyAuth) {
    const provider = privyAuth.getWalletProvider();
    const signer = provider.getSigner();
    
    const contract = new ethers.Contract(
        savingCirclesAddress, 
        savingCirclesABI, 
        signer
    );
    
    const tx = await contract.migratePendingCircle(pendingId, circleStart);
    const receipt = await tx.wait();
    const circleId = receipt.events.find(e => e.event === 'CircleMigrated').args.circleId;
    
    return circleId;
}
```

## React Component Example

Here's a complete React component using Privy for the saving circles flow:

```javascript
import React, { useState, useEffect } from 'react';
import { usePrivy, useWallets } from '@privy-io/react-auth';
import { ethers } from 'ethers';

function SavingCirclesComponent() {
    const { login, logout, authenticated, user } = usePrivy();
    const { wallets } = useWallets();
    const [pendingId, setPendingId] = useState(null);
    const [migrationStatus, setMigrationStatus] = useState({});

    // Circle creation flow with Privy
    const createPendingCircle = async (ownerEmail, memberEmails, circleData) => {
        if (!authenticated) {
            await login();
            return;
        }

        try {
            const provider = wallets[0]?.getEthersProvider();
            const signer = provider.getSigner();
            
            const contract = new ethers.Contract(
                contractAddress, 
                contractABI, 
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
            
            const newPendingId = receipt.events.find(e => e.event === 'PendingCircleCreated').args.id;
            setPendingId(newPendingId);
            
            // Map owner email immediately
            await contract.mapEmailToAddress(ownerEmail, user.wallet.address);
            
            return newPendingId;
        } catch (error) {
            console.error('Error creating pending circle:', error);
            throw error;
        }
    };
    
    const onboardMember = async (email) => {
        if (!authenticated) {
            await login();
            return;
        }

        try {
            const provider = wallets[0]?.getEthersProvider();
            const signer = provider.getSigner();
            
            const contract = new ethers.Contract(
                contractAddress, 
                contractABI, 
                signer
            );
            
            // Map email to current user's address
            await contract.mapEmailToAddress(email, user.wallet.address);
            
            // Update migration status
            if (pendingId) {
                await checkReadyForMigration(pendingId);
            }
            
            return user.wallet.address;
        } catch (error) {
            console.error('Error onboarding member:', error);
            throw error;
        }
    };
    
    const checkReadyForMigration = async (id) => {
        try {
            const provider = wallets[0]?.getEthersProvider();
            const contract = new ethers.Contract(
                contractAddress, 
                contractABI, 
                provider
            );
            
            const pendingCircle = await contract.getPendingCircle(id);
            const unmappedEmails = [];
            
            // Check if all emails are mapped
            for (const email of pendingCircle.memberEmails) {
                const address = await contract.getAddressFromEmail(email);
                if (address === ethers.constants.AddressZero) {
                    unmappedEmails.push(email);
                }
            }
            
            const status = {
                ready: unmappedEmails.length === 0,
                unmappedEmails: unmappedEmails,
                totalMembers: pendingCircle.memberEmails.length,
                mappedMembers: pendingCircle.memberEmails.length - unmappedEmails.length
            };
            
            setMigrationStatus(status);
            return status;
        } catch (error) {
            console.error('Error checking migration readiness:', error);
            throw error;
        }
    };

    const migrateToOnChain = async () => {
        if (!pendingId || !migrationStatus.ready) return;

        try {
            const provider = wallets[0]?.getEthersProvider();
            const signer = provider.getSigner();
            
            const contract = new ethers.Contract(
                contractAddress, 
                contractABI, 
                signer
            );
            
            // Set circle start time (e.g., 1 day from now)
            const circleStart = Math.floor(Date.now() / 1000) + (24 * 60 * 60);
            
            const tx = await contract.migratePendingCircle(pendingId, circleStart);
            const receipt = await tx.wait();
            
            const circleId = receipt.events.find(e => e.event === 'CircleMigrated').args.circleId;
            
            alert(`Circle migrated successfully! New circle ID: ${circleId}`);
            return circleId;
        } catch (error) {
            console.error('Error migrating circle:', error);
            throw error;
        }
    };

    return (
        <div>
            {!authenticated ? (
                <div>
                    <h2>Connect Your Wallet</h2>
                    <button onClick={login}>Login with Privy</button>
                </div>
            ) : (
                <div>
                    <h2>Welcome, {user.email?.address || user.wallet?.address}</h2>
                    <p>Connected via: {user.linkedAccounts.map(acc => acc.type).join(', ')}</p>
                    
                    {/* Your circle creation UI here */}
                    
                    <button onClick={logout}>Logout</button>
                </div>
            )}
        </div>
    );
}
```

## Advanced Privy Features

Privy also supports advanced features for enhanced user experience:

### Smart Wallets with Privy

```javascript
import { usePrivy, useWallets } from '@privy-io/react-auth';
import { createSmartAccountClient } from '@privy-io/react-auth/smart-wallets';

function useSmartWallet() {
    const { authenticated, user } = usePrivy();
    const { wallets } = useWallets();

    const createSmartWallet = async () => {
        if (!authenticated || wallets.length === 0) return null;

        // Create smart wallet client
        const smartWallet = await createSmartAccountClient({
            wallet: wallets[0],
        });

        return smartWallet;
    };

    return { createSmartWallet };
}

// Map email to smart wallet address
async function mapEmailToSmartWallet(email, smartWallet) {
    const smartWalletAddress = await smartWallet.getAddress();
    
    // Map to the smart wallet address
    const contract = new ethers.Contract(
        savingCirclesAddress, 
        savingCirclesABI, 
        smartWallet
    );
    
    await contract.mapEmailToAddress(email, smartWalletAddress);
    
    return smartWalletAddress;
}
```

### Cross-App Authentication

Privy enables users to authenticate across multiple applications:

```javascript
// Configure Privy for cross-app authentication
const privyConfig = {
    loginMethods: ['email', 'google', 'twitter', 'discord', 'wallet'],
    appearance: {
        theme: 'light',
        accentColor: '#676FFF',
    },
    embeddedWallets: {
        createOnLogin: 'users-without-wallets',
        requireUserPasswordOnCreate: true,
    },
    // Enable cross-app authentication
    crossAppAuth: {
        enabled: true,
    }
};

// Users can authenticate once and access multiple dApps
async function authenticateForSavingCircles() {
    const { login, authenticated, user } = usePrivy();
    
    if (!authenticated) {
        await login();
    }
    
    // User is now authenticated across all Privy-enabled apps
    return {
        email: user.email?.address,
        address: user.wallet?.address,
        isAuthenticated: authenticated
    };
}
```

## Backend Service Integration

For enterprise use cases, you can integrate Privy with backend services to manage user authentication and email mappings:

### Node.js Backend Example with Privy

```javascript
const express = require('express');
const { ethers } = require('ethers');
const { PrivyApi } = require('@privy-io/server-auth');

class CircleBackendService {
    constructor(contractAddress, contractABI, privateKey, privyAppId, privyAppSecret) {
        this.provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
        this.wallet = new ethers.Wallet(privateKey, this.provider);
        this.contract = new ethers.Contract(contractAddress, contractABI, this.wallet);
        
        // Initialize Privy API client
        this.privy = new PrivyApi(privyAppId, privyAppSecret);
        this.emailToAddress = new Map(); // In production, use a database
    }
    
    async verifyUserToken(accessToken) {
        try {
            // Verify the Privy access token
            const verifiedClaims = await this.privy.verifyAuthToken(accessToken);
            return verifiedClaims;
        } catch (error) {
            throw new Error('Invalid or expired token');
        }
    }
    
    async registerUser(accessToken) {
        // Verify user authentication with Privy
        const userClaims = await this.verifyUserToken(accessToken);
        const email = userClaims.email;
        const walletAddress = userClaims.wallet?.address;
        
        if (!email || !walletAddress) {
            throw new Error('User must have email and wallet address');
        }
        
        // Validate address
        if (!ethers.utils.isAddress(walletAddress)) {
            throw new Error('Invalid wallet address');
        }
        
        // Store mapping (in production, use database)
        this.emailToAddress.set(email, walletAddress);
        
        // Map on-chain
        const tx = await this.contract.mapEmailToAddress(email, walletAddress);
        await tx.wait();
        
        return { email, address: walletAddress, txHash: tx.hash };
    }
    
    async createPendingCircleForUser(accessToken, circleData) {
        const userClaims = await this.verifyUserToken(accessToken);
        const userEmail = userClaims.email;
        
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
        
        // Check if all members are registered with Privy
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
    
    // Get user information from Privy
    async getUserInfo(userId) {
        try {
            const user = await this.privy.getUser(userId);
            return {
                id: user.id,
                email: user.email?.address,
                walletAddress: user.wallet?.address,
                linkedAccounts: user.linkedAccounts
            };
        } catch (error) {
            throw new Error('User not found');
        }
    }
}

// Express routes with Privy authentication
const app = express();
app.use(express.json());

const circleService = new CircleBackendService(
    process.env.CONTRACT_ADDRESS,
    contractABI,
    process.env.PRIVATE_KEY,
    process.env.PRIVY_APP_ID,
    process.env.PRIVY_APP_SECRET
);

// Middleware to verify Privy token
async function authenticatePrivyToken(req, res, next) {
    try {
        const token = req.headers.authorization?.replace('Bearer ', '');
        if (!token) {
            return res.status(401).json({ error: 'No access token provided' });
        }
        
        const userClaims = await circleService.verifyUserToken(token);
        req.user = userClaims;
        next();
    } catch (error) {
        res.status(401).json({ error: 'Invalid token' });
    }
}

app.post('/register', authenticatePrivyToken, async (req, res) => {
    try {
        const token = req.headers.authorization.replace('Bearer ', '');
        const result = await circleService.registerUser(token);
        res.json(result);
    } catch (error) {
        res.status(400).json({ error: error.message });
    }
});

app.post('/create-circle', authenticatePrivyToken, async (req, res) => {
    try {
        const token = req.headers.authorization.replace('Bearer ', '');
        const { circleData } = req.body;
        const pendingId = await circleService.createPendingCircleForUser(token, circleData);
        res.json({ pendingId });
    } catch (error) {
        res.status(400).json({ error: error.message });
    }
});

app.get('/user/:userId', authenticatePrivyToken, async (req, res) => {
    try {
        const { userId } = req.params;
        const userInfo = await circleService.getUserInfo(userId);
        res.json(userInfo);
    } catch (error) {
        res.status(404).json({ error: error.message });
    }
});
```

## Security Considerations

When integrating with Privy for web3 authentication:

1. **Token Verification**: Always verify Privy access tokens on the backend using the Privy API
2. **Email Verification**: Privy handles email verification, but ensure you trust verified emails
3. **Access Control**: Ensure only authenticated users can map emails to addresses
4. **Rate Limiting**: Implement rate limiting to prevent spam and abuse
5. **Address Validation**: Validate that addresses are properly formatted and owned by the user
6. **Audit Trail**: Log all email-to-address mappings for security audits
7. **App Security**: Secure your Privy app credentials and use environment variables

## Best Practices

1. **User Experience**: 
   - Use Privy's customizable login modal to match your app's branding
   - Provide clear onboarding flows explaining the transition from email to wallet
   - Enable multiple login methods (email, social, wallet) for user flexibility

2. **Progressive Enhancement**: 
   - Allow users to interact with basic features before full web3 onboarding
   - Use Privy's embedded wallets for users who don't have external wallets
   - Implement graceful fallbacks when wallet operations fail

3. **Cross-Platform Support**: 
   - Ensure Privy integrations work well on mobile devices
   - Test with different browsers and wallet configurations
   - Use Privy's mobile-optimized login flows

4. **Error Handling**: 
   - Handle Privy authentication errors gracefully
   - Provide clear error messages when wallet operations fail
   - Implement retry mechanisms for failed transactions

5. **Performance**: 
   - Cache user authentication state appropriately
   - Use Privy's built-in session management
   - Optimize for fast login and wallet connection experiences

## Privy Configuration Examples

### Production Configuration

```javascript
const privyConfig = {
    appId: process.env.NEXT_PUBLIC_PRIVY_APP_ID,
    config: {
        loginMethods: ['email', 'google', 'twitter', 'discord'],
        appearance: {
            theme: 'light',
            accentColor: '#676FFF',
            logo: 'https://your-app.com/logo.png',
        },
        embeddedWallets: {
            createOnLogin: 'users-without-wallets',
            requireUserPasswordOnCreate: true,
        },
        legal: {
            termsAndConditionsUrl: 'https://your-app.com/terms',
            privacyPolicyUrl: 'https://your-app.com/privacy',
        },
        // Additional security settings
        mfa: {
            noPromptOnMfaRequired: false,
        }
    }
};
```

### Development Configuration

```javascript
const privyConfig = {
    appId: process.env.NEXT_PUBLIC_PRIVY_APP_ID,
    config: {
        loginMethods: ['email', 'wallet'], // Simpler for development
        appearance: {
            theme: 'light',
            accentColor: '#676FFF',
        },
        embeddedWallets: {
            createOnLogin: 'all-users', // Create wallets for all users in dev
        },
        // Development-specific settings
        supportedChains: [
            { id: 1337, name: 'Local Hardhat' }, // Local blockchain
            { id: 5, name: 'Goerli' }, // Testnet
        ]
    }
};
```
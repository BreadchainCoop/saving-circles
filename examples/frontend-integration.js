/**
 * Simple frontend example demonstrating the off-chain to on-chain circle creation flow
 * This example uses ethers.js and assumes a basic HTML page structure
 */

class SavingCirclesManager {
    constructor(contractAddress, contractABI, provider) {
        this.contractAddress = contractAddress;
        this.contractABI = contractABI;
        this.provider = provider;
        this.contract = new ethers.Contract(contractAddress, contractABI, provider);
    }

    /**
     * Step 1: Create a pending circle with email addresses
     */
    async createPendingCircle(ownerEmail, memberEmails, circleData) {
        try {
            // Get a signer for the transaction
            const signer = this.provider.getSigner();
            const contractWithSigner = this.contract.connect(signer);

            const pendingCircle = {
                ownerEmail: ownerEmail,
                memberEmails: memberEmails,
                depositAmount: ethers.utils.parseEther(circleData.depositAmount.toString()),
                token: circleData.tokenAddress,
                depositInterval: circleData.depositInterval * 24 * 60 * 60, // Convert days to seconds
                maxDeposits: circleData.maxDeposits,
                isActive: false // Will be set by contract
            };

            console.log('Creating pending circle...', pendingCircle);
            
            const tx = await contractWithSigner.createPendingCircle(pendingCircle);
            const receipt = await tx.wait();
            
            // Extract the pending circle ID from events
            const event = receipt.events.find(e => e.event === 'PendingCircleCreated');
            const pendingId = event.args.id.toNumber();
            
            console.log('Pending circle created with ID:', pendingId);
            return pendingId;
        } catch (error) {
            console.error('Error creating pending circle:', error);
            throw error;
        }
    }

    /**
     * Step 2: Map an email address to a wallet address
     */
    async mapEmailToAddress(email, walletAddress) {
        try {
            const signer = this.provider.getSigner();
            const contractWithSigner = this.contract.connect(signer);

            console.log(`Mapping ${email} to ${walletAddress}...`);
            
            const tx = await contractWithSigner.mapEmailToAddress(email, walletAddress);
            await tx.wait();
            
            console.log('Email mapped successfully');
            return true;
        } catch (error) {
            console.error('Error mapping email:', error);
            throw error;
        }
    }

    /**
     * Step 3: Check if all emails in a pending circle are mapped
     */
    async checkMigrationReadiness(pendingId) {
        try {
            const pendingCircle = await this.contract.getPendingCircle(pendingId);
            const unmappedEmails = [];

            for (const email of pendingCircle.memberEmails) {
                const address = await this.contract.getAddressFromEmail(email);
                if (address === ethers.constants.AddressZero) {
                    unmappedEmails.push(email);
                }
            }

            return {
                ready: unmappedEmails.length === 0,
                unmappedEmails: unmappedEmails,
                totalMembers: pendingCircle.memberEmails.length,
                mappedMembers: pendingCircle.memberEmails.length - unmappedEmails.length
            };
        } catch (error) {
            console.error('Error checking migration readiness:', error);
            throw error;
        }
    }

    /**
     * Step 4: Migrate pending circle to active on-chain circle
     */
    async migratePendingCircle(pendingId, daysFromNow = 1) {
        try {
            const signer = this.provider.getSigner();
            const contractWithSigner = this.contract.connect(signer);

            // Set circle start time (e.g., 1 day from now)
            const circleStart = Math.floor(Date.now() / 1000) + (daysFromNow * 24 * 60 * 60);

            console.log('Migrating pending circle to on-chain...');
            
            const tx = await contractWithSigner.migratePendingCircle(pendingId, circleStart);
            const receipt = await tx.wait();
            
            // Extract the new circle ID from events
            const event = receipt.events.find(e => e.event === 'CircleMigrated');
            const circleId = event.args.circleId.toNumber();
            
            console.log('Circle migrated successfully! New circle ID:', circleId);
            return circleId;
        } catch (error) {
            console.error('Error migrating circle:', error);
            throw error;
        }
    }

    /**
     * Get pending circle details
     */
    async getPendingCircleDetails(pendingId) {
        try {
            const pendingCircle = await this.contract.getPendingCircle(pendingId);
            
            return {
                id: pendingId,
                ownerEmail: pendingCircle.ownerEmail,
                memberEmails: pendingCircle.memberEmails,
                depositAmount: ethers.utils.formatEther(pendingCircle.depositAmount),
                token: pendingCircle.token,
                depositInterval: pendingCircle.depositInterval.toNumber() / (24 * 60 * 60), // Convert to days
                maxDeposits: pendingCircle.maxDeposits.toNumber(),
                isActive: pendingCircle.isActive
            };
        } catch (error) {
            console.error('Error getting pending circle details:', error);
            throw error;
        }
    }

    /**
     * Get active circle details after migration
     */
    async getCircleDetails(circleId) {
        try {
            const circle = await this.contract.getCircle(circleId);
            
            return {
                id: circleId,
                owner: circle.owner,
                members: circle.members,
                currentIndex: circle.currentIndex.toNumber(),
                depositAmount: ethers.utils.formatEther(circle.depositAmount),
                token: circle.token,
                depositInterval: circle.depositInterval.toNumber() / (24 * 60 * 60), // Convert to days
                circleStart: new Date(circle.circleStart.toNumber() * 1000),
                maxDeposits: circle.maxDeposits.toNumber()
            };
        } catch (error) {
            console.error('Error getting circle details:', error);
            throw error;
        }
    }
}

// Example usage with DOM manipulation
class CircleCreationUI {
    constructor(savingCirclesManager) {
        this.manager = savingCirclesManager;
        this.currentPendingId = null;
        this.setupEventListeners();
    }

    setupEventListeners() {
        // Step 1: Create pending circle
        document.getElementById('create-pending-btn').addEventListener('click', async () => {
            const ownerEmail = document.getElementById('owner-email').value;
            const memberEmailsText = document.getElementById('member-emails').value;
            const memberEmails = memberEmailsText.split(',').map(email => email.trim());
            
            const circleData = {
                depositAmount: parseFloat(document.getElementById('deposit-amount').value),
                tokenAddress: document.getElementById('token-address').value,
                depositInterval: parseInt(document.getElementById('deposit-interval').value),
                maxDeposits: parseInt(document.getElementById('max-deposits').value)
            };

            try {
                this.showStatus('Creating pending circle...');
                this.currentPendingId = await this.manager.createPendingCircle(ownerEmail, memberEmails, circleData);
                this.showStatus(`Pending circle created! ID: ${this.currentPendingId}`);
                this.updateMigrationSection();
            } catch (error) {
                this.showStatus(`Error: ${error.message}`, 'error');
            }
        });

        // Step 2: Map email to address
        document.getElementById('map-email-btn').addEventListener('click', async () => {
            const email = document.getElementById('map-email').value;
            const address = document.getElementById('map-address').value;

            try {
                this.showStatus('Mapping email to address...');
                await this.manager.mapEmailToAddress(email, address);
                this.showStatus('Email mapped successfully!');
                
                if (this.currentPendingId) {
                    this.updateMigrationSection();
                }
            } catch (error) {
                this.showStatus(`Error: ${error.message}`, 'error');
            }
        });

        // Step 3: Migrate to on-chain
        document.getElementById('migrate-btn').addEventListener('click', async () => {
            if (!this.currentPendingId) {
                this.showStatus('No pending circle to migrate', 'error');
                return;
            }

            try {
                this.showStatus('Migrating to on-chain...');
                const circleId = await this.manager.migratePendingCircle(this.currentPendingId);
                this.showStatus(`Circle migrated successfully! New circle ID: ${circleId}`);
                
                // Show circle details
                const circleDetails = await this.manager.getCircleDetails(circleId);
                this.displayCircleDetails(circleDetails);
            } catch (error) {
                this.showStatus(`Error: ${error.message}`, 'error');
            }
        });
    }

    async updateMigrationSection() {
        if (!this.currentPendingId) return;

        try {
            const readiness = await this.manager.checkMigrationReadiness(this.currentPendingId);
            const statusEl = document.getElementById('migration-status');
            
            if (readiness.ready) {
                statusEl.innerHTML = `✅ All ${readiness.totalMembers} members mapped. Ready to migrate!`;
                document.getElementById('migrate-btn').disabled = false;
            } else {
                statusEl.innerHTML = `⏳ ${readiness.mappedMembers}/${readiness.totalMembers} members mapped. Still need: ${readiness.unmappedEmails.join(', ')}`;
                document.getElementById('migrate-btn').disabled = true;
            }
        } catch (error) {
            console.error('Error updating migration section:', error);
        }
    }

    showStatus(message, type = 'info') {
        const statusEl = document.getElementById('status');
        statusEl.textContent = message;
        statusEl.className = `status ${type}`;
    }

    displayCircleDetails(details) {
        const detailsEl = document.getElementById('circle-details');
        detailsEl.innerHTML = `
            <h3>Active Circle Created!</h3>
            <p><strong>Circle ID:</strong> ${details.id}</p>
            <p><strong>Owner:</strong> ${details.owner}</p>
            <p><strong>Members:</strong> ${details.members.length}</p>
            <p><strong>Deposit Amount:</strong> ${details.depositAmount} ETH</p>
            <p><strong>Circle Starts:</strong> ${details.circleStart.toLocaleDateString()}</p>
            <p><strong>Deposit Interval:</strong> ${details.depositInterval} days</p>
        `;
    }
}

// Initialize when page loads
window.addEventListener('load', async () => {
    try {
        // Check if MetaMask is available
        if (typeof window.ethereum !== 'undefined') {
            // Request account access
            await window.ethereum.request({ method: 'eth_requestAccounts' });
            
            const provider = new ethers.providers.Web3Provider(window.ethereum);
            
            // Replace with your contract details
            const contractAddress = "0x..."; // Your deployed contract address
            const contractABI = []; // Your contract ABI
            
            const manager = new SavingCirclesManager(contractAddress, contractABI, provider);
            const ui = new CircleCreationUI(manager);
            
            console.log('SavingCircles Manager initialized');
        } else {
            alert('Please install MetaMask to use this application');
        }
    } catch (error) {
        console.error('Error initializing application:', error);
    }
});
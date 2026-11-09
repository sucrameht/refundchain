# RefundChain — Vue dApp + Solidity (local classroom prototype)

RefundChain is a **working educational dApp** for prepaid membership protection. It reuses the exact `RefundChainDemo.sol` Solidity source from your Remix prototype, compiles it locally, and deploys the **MockSGD** and **RefundChain** contracts to a **local Hardhat Ethereum chain**. The Vue website uses **ethers.js v6** to call these deployed contracts.

**No real money or real SGD tokens are involved.** All five demo accounts are deliberately unlocked on the local Hardhat test node. Never expose this node to the internet or deploy its test keys to a public network. The demo clock is classroom-only.

## Requirements

- A Mac or Windows computer with **Node.js 20.19+ or 22.12+** (Node.js 22 LTS is recommended)
- Terminal and a browser (Chrome is fine)
- **No MetaMask required** for the local classroom demo

## Install and start — four commands

Unzip this project, open a Terminal in the extracted `refundchain-vue` folder, and run:

```bash
npm install
```

Open **Terminal 1** (in the same folder), start the simulated blockchain:

```bash
npm run chain
```

Keep Terminal 1 running. Open **Terminal 2** (same folder), deploy and initialise the two smart contracts:

```bash
npm run deploy
```

Now open **Terminal 3** (same folder), start the Vue website:

```bash
npm run dev
```

Open **http://127.0.0.1:5173/** in your browser.

> Important: Your **old Remix VM deployment addresses will not work** here. The `npm run deploy` command redeploys the same Solidity code on a blockchain that the Vue website can access, and writes the new addresses to `public/deployment.json` automatically.

## Live demonstration — S$1,200 → S$300 → S$900

1. In the top **ACTIVE DEMO ACCOUNT** menu choose **Account 3 · Customer**.
2. On the **Customer** page, leave the gym address as prefilled and the amount as `1200`. Click **Approve tokens & create membership**. The page approves the mock token allowance (if needed) and creates membership #1.
3. Change to **Account 0 · Registrar**, open **Consortium**, set `Number of 30-day months` to `3`, then click **Advance simulated time**.
4. Change to **Account 4 · Gym merchant**, open **Merchant**, and click **Withdraw S$300** on membership #1.
5. Change to **Account 0 · Registrar**, open **Consortium**, and click **Vote to close merchant**. Only one of two required votes has been recorded.
6. Change to **Account 1 · Approver 2**, open **Consortium**, and click **Vote to close merchant** again. The gym is now closed; future earnings freeze.
7. Change to **Account 3 · Customer**, open **Customer**, and click **Claim S$900 refund**.
8. Open **Ledger** to see on-chain membership, payout, and refund events.

### Account roles

| Test account | Role | Starting state |
| --- | --- | --- |
| 0 | Registrar + closure approver | Owns initial 995,000 test SGD; can register merchants, advance time, send demo tokens |
| 1 | Second closure approver | Can vote on gym closure |
| 2 | Third closure approver | Can vote on gym closure |
| 3 | Customer | Receives 5,000 demo SGD on deployment |
| 4 | Gym merchant | Approved on deployment; can collect earned instalments |

## What happens behind the scenes?

1. **MockSGD:** ERC-20 token with **0 decimals**. Its balances represent whole fake Singapore dollars; `1200` really means 1,200 demo SGD tokens.
2. **approve:** Before escrow can transfer a user's tokens, the customer allows the RefundChain contract to spend the membership amount.
3. **createMembership:** Solidity calls `transferFrom`, moving the tokens from the customer into the contract's escrow address.
4. **advanceDemoMonths:** Only Account 0 can advance the simulated clock; each demo month is 30 days. This changes the accrued entitlements but does **not** automatically move money.
5. **withdrawEarned:** A merchant transaction checks earned-but-unpaid instalments and transfers that amount to the merchant. The contract rejects an unauthorised caller or premature payment.
6. **voteToCloseMerchant:** Two **different** authorised approvers are required to freeze the merchant's earning clock.
7. **refundUnused:** The customer can claim prepayment that has not been earned by the merchant at closure. A second claim is rejected.
8. **Ledger:** The UI queries Solidity events, not fake hard-coded transaction records.

## Reset or troubleshooting

- If the app says **Cannot reach local Hardhat blockchain**, restart `npm run chain` in Terminal 1.
- If it says **The local blockchain was reset**, rerun `npm run deploy` in Terminal 2 and refresh the website.
- If `localhost:5173` is busy, Vite may select another port; open the exact `Local:` URL shown in Terminal 3.
- To start a brand-new demonstration, stop Terminal 1 with **Ctrl+C**, rerun `npm run chain`, then `npm run deploy`, and refresh the website. This deletes all previous demo state.
- For Solidity changes, edit `contracts/RefundChainDemo.sol` and repeat a fresh chain + deployment.

## Folder structure

```text
refundchain-vue/
├── contracts/
│   └── RefundChainDemo.sol    # Solidity contracts, same as Remix
├── scripts/
│   └── deploy.mjs             # Compiles and deploys to local Hardhat
├── public/
│   └── deployment.json        # Automatically receives deployed addresses
├── src/
│   ├── App.vue                # All four dApp screens + ethers.js logic
│   ├── main.js                # Vue application entry
│   └── style.css              # Responsive design
├── hardhat.config.cjs         # Hardhat chain ID 31337
├── package.json
└── index.html
```

## Academic limitations to document

- The Hardhat test node is **not Hyperledger Besu** and does not simulate QBFT consortium validators.
- Token balances are **not safeguarded SGD bank deposits**; there is no bank, custodian or redemption right.
- A smart contract does **not verify real gym service delivery**. The example assumes 30-day earning periods.
- Closure is represented by two authorised votes; **off-chain legal verification** is out of scope.
- Transfers require a transaction to be triggered; time passing alone does **not automatically initiate a monthly bank payment**.
- This is **unaudited educational code**, unsuitable for managing real funds.

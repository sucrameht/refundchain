<script setup>
import { computed, onMounted, ref } from 'vue';
import { ethers } from 'ethers';

// A deliberately small ABI covering precisely the functions we use.
// The Solidity contract lives in contracts/RefundChainDemo.sol.
const TOKEN_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function transfer(address,uint256) returns (bool)',
  'function symbol() view returns (string)',
];
const ESCROW_ABI = [
  'function nextMembershipId() view returns (uint256)',
  'function memberships(uint256) view returns (address customer,address merchant,uint256 total,uint256 startTime,uint256 paidToMerchant,uint256 refundedToCustomer)',
  'function approvedMerchants(address) view returns (bool)',
  'function merchantClosedAt(address) view returns (uint256)',
  'function closureVotes(address) view returns (uint8)',
  'function hasVotedToClose(address,address) view returns (bool)',
  'function demoMode() view returns (bool)',
  'function currentTime() view returns (uint256)',
  'function totalEarned(uint256) view returns (uint256)',
  'function availableForMerchant(uint256) view returns (uint256)',
  'function refundable(uint256) view returns (uint256)',
  'function escrowBalance(uint256) view returns (uint256)',
  'function approveMerchant(address)',
  'function createMembership(address,uint256) returns (uint256)',
  'function advanceDemoMonths(uint256)',
  'function withdrawEarned(uint256)',
  'function voteToCloseMerchant(address)',
  'function refundUnused(uint256)',
  'event MembershipCreated(uint256 indexed id,address indexed customer,address indexed merchant,uint256 amount)',
  'event MerchantPaid(uint256 indexed id,uint256 amount)',
  'event CustomerRefunded(uint256 indexed id,uint256 amount)',
  'event MerchantApproved(address indexed merchant)',
  'event MerchantClosed(address indexed merchant,uint256 closureTime)',
];

const accountNames = ['Registrar', 'Approver 2', 'Approver 3', 'Customer', 'Gym merchant'];
const navigation = [
  { id: 'customer', label: 'Customer', icon: '◉', description: 'Prepaid memberships' },
  { id: 'merchant', label: 'Merchant', icon: '▣', description: 'Earned payouts' },
  { id: 'consortium', label: 'Consortium', icon: '◈', description: 'Network controls' },
  { id: 'ledger', label: 'Ledger', icon: '≡', description: 'On-chain activity' },
];
const tab = ref('customer');
const loading = ref(true);
const busy = ref(false);
const status = ref('');
const notice = ref('');
const error = ref('');
const config = ref(null);
const connected = ref(false);
const activeAccount = ref(3);
const walletAddresses = ref([]);
const tokenBalance = ref(0);
const membershipRows = ref([]);
const ledgerRows = ref([]);
const clock = ref(0);
const memberCount = ref(0);
const merchantInput = ref('');
const amountInput = ref('1200');
const registrationInput = ref('');
const closureInput = ref('');
const monthsInput = ref('3');
const fundRecipient = ref('');
const fundAmount = ref('1200');
const approved = ref(false);
const closedAt = ref(0);
const votes = ref(0);
const votedByMe = ref(false);

let provider;
let token;
let escrow;
let readNonce = 0;

const addr = computed(() => walletAddresses.value[activeAccount.value] || '');
const activeRole = computed(() => accountNames[activeAccount.value] || 'Local account');
const isRegistrar = computed(() => activeAccount.value === 0);
const isApprover = computed(() => activeAccount.value <= 2);
const balance = computed(() => tokenBalance.value);
const mine = computed(() => membershipRows.value.filter(row => same(row.customer, addr.value)));
const forMerchant = computed(() => membershipRows.value.filter(row => same(row.merchant, addr.value)));
const lockedTotal = computed(() => membershipRows.value.reduce((sum, row) => sum + row.escrow, 0));
const refundedTotal = computed(() => membershipRows.value.reduce((sum, row) => sum + row.refunded, 0));
const merchantEarned = computed(() => forMerchant.value.reduce((sum, row) => sum + row.available, 0));
const membershipTotal = computed(() => mine.value.reduce((sum, row) => sum + row.total, 0));
const merchantDefault = computed(() => config.value?.seededMerchant || '');
const displayDate = secs => secs ? new Date(secs * 1000).toLocaleDateString('en-SG', { day:'numeric', month:'short', year:'numeric' }) : '—';
const cash = value => `S$${Number(value || 0).toLocaleString('en-SG', { maximumFractionDigits: 0 })}`;
const short = a => a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—';
const same = (a, b) => Boolean(a && b && String(a).toLowerCase() === String(b).toLowerCase());
const number = n => Number(n || 0);
const summaryFor = row => row.closed ? 'Closed' : row.earned >= row.total ? 'Completed' : 'Active';
const remainingMonths = row => Math.max(0, 12 - Math.floor(row.earned / (row.total / 12 || 1)));

async function getSignerContract(contract) {
  return contract.connect(await provider.getSigner(activeAccount.value));
}

async function loadConfig() {
  loading.value = true;
  error.value = '';
  try {
    const response = await fetch(`/deployment.json?t=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error('Cannot load deployment.json.');
    const deployment = await response.json();
    if (!ethers.isAddress(deployment.token || '') || !ethers.isAddress(deployment.escrow || '')) {
      throw new Error('Contracts are not deployed yet. Run "npm run chain" in Terminal 1, then "npm run deploy" in Terminal 2.');
    }
    provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545', { chainId: 31337, name: 'Hardhat' }, { staticNetwork: true });
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== 31337) throw new Error('Wrong network. Expected local Hardhat chain 31337.');
    if ((await provider.getCode(deployment.escrow)) === '0x' || (await provider.getCode(deployment.token)) === '0x') {
      throw new Error('The local blockchain was reset. Run "npm run deploy" again.');
    }
    config.value = deployment;
    token = new ethers.Contract(deployment.token, TOKEN_ABI, provider);
    escrow = new ethers.Contract(deployment.escrow, ESCROW_ABI, provider);
    walletAddresses.value = await Promise.all(Array.from({ length: 5 }, async (_, index) => await (await provider.getSigner(index)).getAddress()));
    merchantInput.value = deployment.seededMerchant;
    closureInput.value = deployment.seededMerchant;
    registrationInput.value = deployment.seededMerchant;
    fundRecipient.value = walletAddresses.value[3];
    connected.value = true;
    await refresh();
  } catch (e) {
    connected.value = false;
    error.value = friendlyError(e);
  } finally {
    loading.value = false;
  }
}

function friendlyError(err) {
  const raw = err?.shortMessage || err?.reason || err?.info?.error?.message || err?.message || String(err);
  if (raw.includes('ECONNREFUSED') || raw.includes('Failed to fetch') || raw.includes('could not coalesce error') || raw.includes('SERVER_ERROR')) {
    return 'Cannot reach local Hardhat blockchain. Ensure "npm run chain" is running in its own terminal.';
  }
  if (raw.includes('Already registered')) return 'This merchant is already registered.';
  if (raw.includes('Already voted')) return 'This approver has already voted on that closure.';
  if (raw.includes('Only merchant')) return 'Only the merchant wallet can withdraw its earnings.';
  if (raw.includes('Only customer')) return 'Only the customer wallet can claim the refund.';
  if (raw.includes('No refundable balance')) return 'No refund is available until the merchant closes with unused funds remaining.';
  if (raw.includes('Nothing earned yet')) return 'No new completed months are available for withdrawal.';
  return raw.length > 260 ? `${raw.slice(0, 260)}…` : raw;
}

async function refresh() {
  if (!connected.value) return;
  const currentRead = ++readNonce;
  try {
    const address = addr.value;
    const merchantAddress = closureInput.value || merchantDefault.value;
    const [balanceRaw, latest, time, count, isApproved, closureStamp, totalVotes, alreadyVoted] = await Promise.all([
      token.balanceOf(address), escrow.nextMembershipId(), escrow.currentTime(), escrow.nextMembershipId(),
      escrow.approvedMerchants(merchantAddress), escrow.merchantClosedAt(merchantAddress),
      escrow.closureVotes(merchantAddress), escrow.hasVotedToClose(merchantAddress, address),
    ]);
    const total = number(latest);
    const ids = Array.from({ length: Math.min(total, 100) }, (_, i) => total - i);
    const rows = await Promise.all(ids.map(async id => {
      const [m, earned, available, refundable, locked, closedAtValue] = await Promise.all([
        escrow.memberships(id), escrow.totalEarned(id), escrow.availableForMerchant(id),
        escrow.refundable(id), escrow.escrowBalance(id),
        escrow.memberships(id).then(m => escrow.merchantClosedAt(m.merchant)),
      ]);
      return {
        id, customer:m.customer, merchant:m.merchant, total:number(m.total), earned:number(earned),
        paid:number(m.paidToMerchant), refunded:number(m.refundedToCustomer), available:number(available),
        refundable:number(refundable), escrow:number(locked), start:number(m.startTime), closed:number(closedAtValue),
      };
    }));
    if (currentRead !== readNonce) return;
    tokenBalance.value = number(balanceRaw);
    memberCount.value = number(count);
    membershipRows.value = rows;
    clock.value = number(time);
    approved.value = isApproved;
    closedAt.value = number(closureStamp);
    votes.value = number(totalVotes);
    votedByMe.value = alreadyVoted;
    await loadEvents(currentRead);
    error.value = '';
  } catch (e) {
    if (currentRead === readNonce) error.value = friendlyError(e);
  }
}

async function loadEvents(currentRead) {
  const queryTypes = [
    ['MembershipCreated', 'Membership created', (args) => `#${args[0]} · ${cash(args[3])} prepaid`],
    ['MerchantPaid', 'Merchant paid', (args) => `Membership #${args[0]} · ${cash(args[1])}`],
    ['CustomerRefunded', 'Customer refunded', (args) => `Membership #${args[0]} · ${cash(args[1])}`],
    ['MerchantApproved', 'Merchant approved', (args) => short(args[0])],
    ['MerchantClosed', 'Merchant closed', (args) => short(args[0])],
  ];
  try {
    const groups = await Promise.all(queryTypes.map(async ([eventName, title, describe]) => {
      const entries = await escrow.queryFilter(escrow.filters[eventName](), 0, 'latest');
      return entries.map(event => ({
        title, detail: describe(event.args), block: event.blockNumber,
        index: event.index ?? 0, tx: event.transactionHash,
      }));
    }));
    if (currentRead === readNonce) ledgerRows.value = groups.flat().sort((a,b) => (b.block-a.block) || (b.index-a.index)).slice(0, 25);
  } catch (e) {
    // Event history is supplementary; keep the main dApp usable if RPC log queries fail.
    console.warn('Could not load event log', e);
    if (currentRead === readNonce) ledgerRows.value = [];
  }
}

async function act(label, fn) {
  busy.value = true;
  status.value = label;
  error.value = '';
  notice.value = '';
  try {
    const result = await fn();
    if (result?.wait) await result.wait();
    notice.value = `${label} completed. Blockchain state updated.`;
    await refresh();
  } catch (e) {
    error.value = friendlyError(e);
  } finally {
    status.value = '';
    busy.value = false;
  }
}

function validAddress(value) {
  if (!ethers.isAddress((value || '').trim())) throw new Error('Enter a valid 0x Ethereum address.');
  return value.trim();
}
function positiveWhole(value) {
  const v = Number(value);
  if (!Number.isSafeInteger(v) || v <= 0) throw new Error('Enter a positive whole number of demo SGD tokens.');
  return BigInt(v);
}
async function buyMembership() {
  await act('Purchasing membership', async () => {
    const merchant = validAddress(merchantInput.value);
    const amount = positiveWhole(amountInput.value);
    if (!(await escrow.approvedMerchants(merchant))) throw new Error('Merchant is not registered. Ask the registrar to register it first.');
    if ((await token.balanceOf(addr.value)) < amount) throw new Error('Insufficient demo SGD tokens. Ask the registrar to send you test tokens.');
    const spender = config.value.escrow;
    const signerToken = await getSignerContract(token);
    if ((await token.allowance(addr.value, spender)) < amount) {
      status.value = 'Step 1/2: Approving demo token transfer';
      const approval = await signerToken.approve(spender, amount);
      await approval.wait();
    }
    status.value = 'Step 2/2: Creating membership and locking funds';
    return (await getSignerContract(escrow)).createMembership(merchant, amount);
  });
}
async function withdraw(id) {
  await act(`Withdrawing earned funds for membership #${id}`, async () => (await getSignerContract(escrow)).withdrawEarned(id));
}
async function claimRefund(id) {
  await act(`Refunding unused funds for membership #${id}`, async () => (await getSignerContract(escrow)).refundUnused(id));
}
async function registerMerchant() {
  await act('Approving merchant', async () => (await getSignerContract(escrow)).approveMerchant(validAddress(registrationInput.value)));
}
async function confirmClosure() {
  await act('Recording merchant closure vote', async () => (await getSignerContract(escrow)).voteToCloseMerchant(validAddress(closureInput.value)));
}
async function advanceClock() {
  await act(`Advancing demo clock by ${monthsInput.value} months`, async () => (await getSignerContract(escrow)).advanceDemoMonths(positiveWhole(monthsInput.value)));
}
async function fundWallet() {
  await act('Sending demo SGD tokens', async () => (await getSignerContract(token)).transfer(validAddress(fundRecipient.value), positiveWhole(fundAmount.value)));
}
async function changeAccount(event) {
  activeAccount.value = Number(event.target.value);
  notice.value = '';
  error.value = '';
  await refresh();
}
function goTo(id, accountId = null) {
  tab.value = id;
  if (accountId !== null) {
    activeAccount.value = accountId;
    refresh();
  }
}

onMounted(loadConfig);
</script>

<template>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand"><div class="brand-mark">R<span>↗</span></div><div><strong>RefundChain</strong><small>Prepayments, protected.</small></div></div>
      <div class="side-label">WORKSPACE</div>
      <nav class="nav-list" aria-label="Main navigation">
        <button v-for="item in navigation" :key="item.id" type="button" class="nav-btn" :class="{ selected: tab === item.id }" @click="tab = item.id">
          <span class="nav-symbol">{{ item.icon }}</span><span><strong>{{ item.label }}</strong><small>{{ item.description }}</small></span>
        </button>
      </nav>
      <div class="sidebar-bottom">
        <div class="sidebar-note"><span class="dot green"></span> Local classroom demo <p>Runs on your computer. Demo SGD has no real monetary value.</p></div>
        <div class="sidebar-foot">Built with Vue + Solidity + ethers.js</div>
      </div>
    </aside>

    <main class="main">
      <header class="topbar">
        <div class="breadcrumbs">REFUNDCHAIN <span>/</span> <strong>{{ navigation.find(n=>n.id===tab)?.label }}</strong></div>
        <div class="top-controls">
          <span class="network-pill"><span class="dot" :class="connected ? 'green' : 'red'"></span>{{ connected ? 'Hardhat · Chain 31337' : 'Disconnected' }}</span>
          <button class="refresh-btn" type="button" :disabled="loading || busy" @click="refresh">↻ <span>Refresh</span></button>
        </div>
      </header>

      <div class="content">
        <div v-if="loading" class="panel centered-message"><div class="spinner"></div><h2>Connecting to demo blockchain…</h2><p>Reading local contracts and test accounts.</p></div>
        <div v-else-if="!connected" class="panel setup-state">
          <div class="setup-icon">⌘</div>
          <h1>Connect the local demo</h1>
          <p>{{ error || 'Contracts have not been deployed.' }}</p>
          <div class="setup-steps"><div><b>1</b><code>npm install</code></div><div><b>2</b><code>npm run chain</code></div><div><b>3</b><code>npm run deploy</code></div><div><b>4</b><code>npm run dev</code></div></div>
          <button class="primary" type="button" @click="loadConfig">Retry connection</button>
        </div>
        <template v-else>
          <div class="section-intro">
            <div>
              <div class="eyebrow">REFUNDCHAIN / {{ tab.toUpperCase() }}</div>
              <h1 v-if="tab==='customer'">Your memberships, secured.</h1>
              <h1 v-else-if="tab==='merchant'">Your earnings, on schedule.</h1>
              <h1 v-else-if="tab==='consortium'">Consortium controls.</h1>
              <h1 v-else>Transparent by design.</h1>
              <p v-if="tab==='customer'">Prepaid memberships are escrowed and released only as services are earned.</p>
              <p v-else-if="tab==='merchant'">See earned instalments and withdraw only what you're entitled to receive.</p>
              <p v-else-if="tab==='consortium'">Approve merchants, verify closures and manage the classroom demo clock.</p>
              <p v-else>Track all membership deposits, merchant releases and customer refunds.</p>
            </div>
          </div>

          <div class="account-bar">
            <div class="account-icon">◉</div>
            <div class="account-copy"><span>ACTIVE DEMO ACCOUNT</span><strong>{{ activeRole }} <span class="address">{{ short(addr) }}</span></strong></div>
            <label class="select-wrap"><span class="sr-only">Select demo account</span><select :value="activeAccount" :disabled="busy" @change="changeAccount"><option v-for="(name, index) in accountNames" :key="index" :value="index">Account {{ index }} · {{ name }}</option></select></label>
          </div>
          <div v-if="error" class="toast error" role="alert"><span>!</span> {{ error }} <button @click="error=''" aria-label="Dismiss error">×</button></div>
          <div v-if="notice" class="toast success" role="status"><span>✓</span> {{ notice }} <button @click="notice=''" aria-label="Dismiss notification">×</button></div>
          <div v-if="busy" class="toast busy" role="status"><span class="spinner small"></span> {{ status || 'Confirming transaction…' }}</div>

          <template v-if="tab === 'customer'">
            <div class="stats three">
              <div class="stat panel"><div class="stat-label">My demo SGD balance</div><div class="stat-value">{{ cash(balance) }}</div><div class="stat-hint">Available in this account</div></div>
              <div class="stat panel"><div class="stat-label">My total prepaid</div><div class="stat-value">{{ cash(membershipTotal) }}</div><div class="stat-hint">Across {{ mine.length }} membership(s)</div></div>
              <div class="stat panel"><div class="stat-label">Escrow held network-wide</div><div class="stat-value emerald">{{ cash(lockedTotal) }}</div><div class="stat-hint">Protected mock SGD tokens</div></div>
            </div>
            <div class="columns">
              <div class="panel form-panel">
                <div class="panel-head"><div class="panel-icon teal">+</div><div><h2>Start a membership</h2><p>Lock your prepayment in the RefundChain escrow.</p></div></div>
                <form @submit.prevent="buyMembership">
                  <label>Merchant address<input v-model.trim="merchantInput" placeholder="0x…" required spellcheck="false" /></label>
                  <div class="hint-line"><span class="dot" :class="same(merchantInput, merchantDefault) && approved ? 'green' : 'amber'"></span> {{ same(merchantInput, merchantDefault) && approved ? 'Default gym is approved' : 'Merchant must be approved by registrar' }}</div>
                  <label>Prepayment amount (demo SGD)<div class="input-with-prefix"><span>S$</span><input v-model="amountInput" type="number" min="1" step="1" required /></div></label>
                  <div class="explain-row"><span>Membership duration</span><strong>12 × 30 days</strong></div>
                  <div class="explain-row"><span>Monthly earned amount for S$1,200</span><strong>S$100</strong></div>
                  <button class="primary full" type="submit" :disabled="busy">Approve tokens & create membership <span>→</span></button>
                  <p class="tiny-note">The dApp first grants token allowance, then deposits tokens into escrow. Both are on-chain transactions.</p>
                </form>
              </div>
              <div class="panel info-panel">
                <div class="panel-head"><div class="panel-icon blue">♢</div><div><h2>How your money is protected</h2><p>Designed for prepaid services.</p></div></div>
                <div class="step"><b>01</b><div><strong>Pay into escrow</strong><p>Funds are held by the RefundChain contract, not the gym.</p></div></div>
                <div class="step"><b>02</b><div><strong>Earned as delivered</strong><p>The gym can withdraw only after each complete 30-day period.</p></div></div>
                <div class="step"><b>03</b><div><strong>Automatic refund rules</strong><p>After a verified closure, unused amounts become claimable.</p></div></div>
                <div class="info-banner">ⓘ &nbsp; Educational simulation: this does not safeguard real SGD.</div>
              </div>
            </div>
            <section class="panel list-panel">
              <div class="list-heading"><div><h2>My memberships</h2><p>Membership records belonging to the selected account.</p></div><button class="outline" :disabled="busy" @click="refresh">↻ Refresh</button></div>
              <div v-if="!mine.length" class="empty"><span>▤</span><strong>No memberships yet</strong><p>Switch to Account 3 and create your first S$1,200 gym membership.</p></div>
              <div v-for="row in mine" :key="row.id" class="membership-card">
                <div class="card-top"><div><span class="subtle-label">MEMBERSHIP #{{ row.id }}</span><h3>Gym prepaid membership</h3><div class="mono-small">{{ short(row.merchant) }}</div></div><span class="status-pill" :class="summaryFor(row).toLowerCase()">{{ summaryFor(row) }}</span></div>
                <div class="card-numbers"><div><small>Initial deposit</small><strong>{{ cash(row.total) }}</strong></div><div><small>Earned by gym</small><strong>{{ cash(row.earned) }}</strong></div><div><small>Still in escrow</small><strong>{{ cash(row.escrow) }}</strong></div><div><small>Refund available</small><strong class="emerald">{{ cash(row.refundable) }}</strong></div></div>
                <div class="progress-track"><div :style="{ width: Math.min(100, (row.earned / row.total) * 100) + '%' }"></div></div>
                <div class="card-bottom"><span>Started {{ displayDate(row.start) }} · {{ Math.min(12, 12 - remainingMonths(row)) }}/12 months earned</span><button v-if="row.refundable>0 && same(row.customer,addr)" :disabled="busy" class="primary compact" @click="claimRefund(row.id)">Claim {{ cash(row.refundable) }} refund</button><span v-else-if="row.closed" class="muted-text">No additional refund available</span></div>
              </div>
            </section>
          </template>

          <template v-else-if="tab === 'merchant'">
            <div class="stats three">
              <div class="stat panel"><div class="stat-label">My demo SGD wallet</div><div class="stat-value">{{ cash(balance) }}</div><div class="stat-hint">Already received</div></div>
              <div class="stat panel"><div class="stat-label">Available to withdraw</div><div class="stat-value emerald">{{ cash(merchantEarned) }}</div><div class="stat-hint">Earned but not yet paid</div></div>
              <div class="stat panel"><div class="stat-label">Active customer records</div><div class="stat-value">{{ forMerchant.length }}</div><div class="stat-hint">Linked to this merchant wallet</div></div>
            </div>
            <section class="panel list-panel">
              <div class="list-heading"><div><h2>Membership earnings</h2><p>Payment rights are calculated on-chain from complete 30-day periods.</p></div><button class="outline" :disabled="busy" @click="refresh">↻ Refresh</button></div>
              <div v-if="!forMerchant.length" class="empty"><span>▣</span><strong>No customers for this account</strong><p>Switch to Account 4 to view gym memberships after a customer makes a purchase.</p></div>
              <div v-for="row in forMerchant" :key="row.id" class="membership-card">
                <div class="card-top"><div><span class="subtle-label">MEMBERSHIP #{{ row.id }}</span><h3>Customer {{ short(row.customer) }}</h3><div class="mono-small">Started {{ displayDate(row.start) }}</div></div><span class="status-pill" :class="summaryFor(row).toLowerCase()">{{ summaryFor(row) }}</span></div>
                <div class="card-numbers"><div><small>Total deposit</small><strong>{{ cash(row.total) }}</strong></div><div><small>Earned to date</small><strong>{{ cash(row.earned) }}</strong></div><div><small>Already withdrawn</small><strong>{{ cash(row.paid) }}</strong></div><div><small>Available now</small><strong class="emerald">{{ cash(row.available) }}</strong></div></div>
                <div class="card-bottom"><span>Only completed periods can be collected</span><button class="primary compact" :disabled="busy || row.available<=0" @click="withdraw(row.id)">Withdraw {{ cash(row.available) }}</button></div>
              </div>
            </section>
          </template>

          <template v-else-if="tab === 'consortium'">
            <div class="stats three">
              <div class="stat panel"><div class="stat-label">Total membership records</div><div class="stat-value">{{ memberCount }}</div><div class="stat-hint">Across the local demo chain</div></div>
              <div class="stat panel"><div class="stat-label">Demo blockchain time</div><div class="stat-value date-value">{{ displayDate(clock) }}</div><div class="stat-hint">Current smart contract clock</div></div>
              <div class="stat panel"><div class="stat-label">Default gym status</div><div class="stat-value status-value" :class="closedAt?'danger-text':'emerald'">{{ closedAt ? 'Closed' : 'Approved' }}</div><div class="stat-hint">{{ votes }} of 2 closure votes</div></div>
            </div>
            <div class="columns">
              <div class="panel form-panel">
                <div class="panel-head"><div class="panel-icon teal">✓</div><div><h2>Merchant approval</h2><p>Only the registrar (Account 0) can approve new merchants.</p></div></div>
                <form @submit.prevent="registerMerchant"><label>Merchant address<input v-model.trim="registrationInput" placeholder="0x…" required spellcheck="false" /></label><button class="primary full" :disabled="busy || !isRegistrar">Approve merchant <span>→</span></button><p class="tiny-note" v-if="!isRegistrar">Switch to Account 0 to access this action.</p></form>
              </div>
              <div class="panel form-panel">
                <div class="panel-head"><div class="panel-icon amber">⌁</div><div><h2>Advance demo time</h2><p>Simulate completed service periods instantly.</p></div></div>
                <form @submit.prevent="advanceClock"><label>Number of 30-day months<input v-model="monthsInput" type="number" min="1" step="1" required /></label><button class="primary full" :disabled="busy || !isRegistrar">Advance simulated time <span>→</span></button><p class="tiny-note">Classroom-only. Production systems use real timestamps, not this control.</p></form>
              </div>
              <div class="panel form-panel">
                <div class="panel-head"><div class="panel-icon red">!</div><div><h2>Confirm merchant closure</h2><p>Two separate authorised approvers are required to stop earnings.</p></div></div>
                <form @submit.prevent="confirmClosure"><label>Merchant address<input v-model.trim="closureInput" placeholder="0x…" required spellcheck="false" /></label><div class="voting-status"><span class="dot" :class="closedAt?'red':'amber'"></span>{{ closedAt ? 'Merchant closed' : `${votes}/2 approvals recorded` }}</div><button class="primary full" :disabled="busy || !isApprover || closedAt>0 || votedByMe">{{ votedByMe ? 'You already voted' : 'Vote to close merchant' }} <span>→</span></button><p class="tiny-note">Use Account 0 and then Account 1 for the two separate closure votes. When changing the merchant address, refresh to load its status.</p></form>
              </div>
              <div class="panel form-panel">
                <div class="panel-head"><div class="panel-icon blue">$</div><div><h2>Distribute demo SGD</h2><p>Registrar can send additional mock tokens to a test customer.</p></div></div>
                <form @submit.prevent="fundWallet"><label>Recipient address<input v-model.trim="fundRecipient" placeholder="0x…" required spellcheck="false" /></label><label>Amount (demo SGD)<input v-model="fundAmount" type="number" min="1" step="1" required /></label><button class="primary full" :disabled="busy || !isRegistrar">Transfer demo tokens <span>→</span></button></form>
              </div>
            </div>
          </template>

          <template v-else-if="tab === 'ledger'">
            <div class="stats three">
              <div class="stat panel"><div class="stat-label">Memberships created</div><div class="stat-value">{{ memberCount }}</div><div class="stat-hint">On-chain membership IDs</div></div>
              <div class="stat panel"><div class="stat-label">Funds still locked</div><div class="stat-value emerald">{{ cash(lockedTotal) }}</div><div class="stat-hint">Combined escrow balances</div></div>
              <div class="stat panel"><div class="stat-label">Cumulative refunds</div><div class="stat-value">{{ cash(refundedTotal) }}</div><div class="stat-hint">Returned to customers</div></div>
            </div>
            <section class="panel list-panel">
              <div class="list-heading"><div><h2>Recent blockchain events</h2><p>Smart contracts emit an event when a key business transaction succeeds.</p></div><button class="outline" :disabled="busy" @click="refresh">↻ Refresh</button></div>
              <div v-if="!ledgerRows.length" class="empty"><span>≡</span><strong>No events found</strong><p>Purchase a membership or process a payment, then refresh this page.</p></div>
              <div v-for="(event,index) in ledgerRows" :key="event.tx+event.index+index" class="event-row"><div class="event-icon">{{ event.title.includes('refunded')?'↩':event.title.includes('paid')?'↗':event.title.includes('closed')?'!':'✓' }}</div><div class="event-main"><strong>{{ event.title }}</strong><span>{{ event.detail }}</span></div><div class="event-right"><strong>Block #{{ event.block }}</strong><small>{{ short(event.tx) }}</small></div></div>
            </section>
          </template>

          <div class="tour panel">
            <div><span class="eyebrow">GUIDED DEMONSTRATION</span><h2>Try the full S$1,200 → S$300 → S$900 journey</h2><p>Customer buys → registrar advances 3 months → gym withdraws S$300 → two consortium votes close the gym → customer claims S$900.</p></div>
            <div class="tour-actions"><button type="button" class="outline" @click="goTo('customer',3)">1 · Customer</button><button type="button" class="outline" @click="goTo('consortium',0)">2 · Registrar</button><button type="button" class="outline" @click="goTo('merchant',4)">3 · Gym</button><button type="button" class="outline" @click="goTo('consortium',1)">4 · Second vote</button></div>
          </div>
          <footer class="footer"><span>REFUNDCHAIN · STUDENT PROTOTYPE</span><span>No real SGD · No bank integration · No live reserves</span></footer>
        </template>
      </div>
    </main>
  </div>
</template>

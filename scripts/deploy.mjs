/**
 * Compile the SAME RefundChainDemo.sol used in Remix, then deploy to local
 * Hardhat JSON-RPC without downloading a remote compiler at deployment time.
 * No real tokens, wallets, bank accounts, or funds are involved.
 */
import fs from 'node:fs';
import path from 'node:path';
import solc from 'solc';
import { ethers } from 'ethers';

const root = process.cwd();
const source = fs.readFileSync(path.join(root, 'contracts', 'RefundChainDemo.sol'), 'utf8');
const findImports = (importPath) => {
  for (const candidate of [
    path.join(root, 'node_modules', importPath),
    path.join(root, 'contracts', importPath),
    path.join(root, importPath),
  ]) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
      return { contents: fs.readFileSync(candidate, 'utf8') };
    }
  }
  return { error: `Cannot resolve Solidity import: ${importPath}` };
};
const input = {
  language: 'Solidity',
  sources: { 'contracts/RefundChainDemo.sol': { content: source } },
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: 'shanghai',
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
  },
};
const compiled = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
const errors = (compiled.errors || []).filter(e => e.severity === 'error');
if (errors.length) {
  console.error(errors.map(e => e.formattedMessage).join('\n'));
  process.exit(1);
}
const contracts = compiled.contracts?.['contracts/RefundChainDemo.sol'];
if (!contracts?.MockSGD || !contracts?.RefundChain) {
  throw new Error('Cannot find MockSGD and RefundChain in the Solidity source.');
}

const rpc = new ethers.JsonRpcProvider('http://127.0.0.1:8545', { chainId: 31337, name: 'hardhat' }, { staticNetwork: true });
try { await rpc.getBlockNumber(); } catch {
  console.error('Hardhat is not running. In another Terminal, run: npm run chain');
  process.exit(1);
}
const signers = await Promise.all(Array.from({ length: 5 }, (_, i) => rpc.getSigner(i)));
const addrs = await Promise.all(signers.map(s => s.getAddress()));

async function deploy(name, args = []) {
  const artifact = contracts[name];
  const factory = new ethers.ContractFactory(artifact.abi, `0x${artifact.evm.bytecode.object}`, signers[0]);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  console.log(`  ${name}: ${await contract.getAddress()}`);
  return contract;
}

console.log('Deploying classroom-only smart contracts to Hardhat (chain 31337)...');
const token = await deploy('MockSGD');
const escrow = await deploy('RefundChain', [await token.getAddress(), true, addrs[1], addrs[2]]);
await (await escrow.approveMerchant(addrs[4])).wait();
await (await token.transfer(addrs[3], 5000)).wait();

const deployment = {
  chainId: 31337,
  rpc: 'http://127.0.0.1:8545',
  token: await token.getAddress(),
  escrow: await escrow.getAddress(),
  seededMerchant: addrs[4],
  accounts: addrs,
  deployedAt: new Date().toISOString(),
};
fs.mkdirSync(path.join(root, 'public'), { recursive: true });
fs.writeFileSync(path.join(root, 'public', 'deployment.json'), JSON.stringify(deployment, null, 2));
console.log('\nReady!');
console.log('  Account 0: Registrar / approver 1');
console.log('  Account 1: Approver 2');
console.log('  Account 2: Approver 3');
console.log('  Account 3: Customer (5,000 demo SGD tokens)');
console.log('  Account 4: Gym merchant (pre-approved)');
console.log('\nNext: npm run dev');
console.log('Open http://127.0.0.1:5173');
console.log('\nNote: restarting the Hardhat chain resets all contracts and balances.');
console.log('If you restart it, run npm run deploy again.');

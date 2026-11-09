/** Local classroom blockchain only. Never expose this RPC server to the internet. */
module.exports = {
  solidity: '0.8.30',
  networks: {
    hardhat: { chainId: 31337 },
  },
};

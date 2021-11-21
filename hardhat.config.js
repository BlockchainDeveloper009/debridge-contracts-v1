
/**
 * @type import('hardhat/config').HardhatUserConfig
 */
require("dotenv-flow").config();
require("@nomiclabs/hardhat-truffle5");
require('hardhat-deploy');
require("@nomiclabs/hardhat-waffle");
require('@openzeppelin/hardhat-upgrades');
require('hardhat-contract-sizer');
require("hardhat-gas-reporter");
require("@nomiclabs/hardhat-solhint");
require("prettier-plugin-solidity");
require("solidity-coverage");

module.exports = {
  gasReporter: {
    currency: "USD",
    gasPrice: 100,
  },

  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
    deploy: "./scripts/deploy"
  },
  /**
   * Networks define how you connect to your ethereum client and let you set the
   * defaults web3 uses to send transactions. If you don't specify one truffle
   * will spin up a development blockchain for you on port 9545 when you
   * run `develop` or `test`. You can ask a truffle command to use a specific
   * network from the command line, e.g
   *
   * $ truffle test --network <network-name>
   */
  //61e2db80d80fef89b7a5fa748cf46471cb2fa91f0248ee36675d5e28a84d932b
  solidity: {
    compilers: [
      {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: "0.6.11",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      }
    ]
  },
  external: {
    contracts: [
      {
        artifacts: "./precompiled",
      },
    ],
  },
  namedAccounts: {
    deployer: 0
  },
  networks: {
    hardhat: {
      accounts:{mnemonic:process.env.MNEMONIC},
      chainId: 1
    },
    test: {
      url: "http://127.0.0.1:8545",
      accounts: {mnemonic:process.env.MNEMONIC},
    },
    kovan: {
      url: "https://kovan.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      // gasPrice: 2e9,
      gas: 6.9e6,
      chainId: 42
    },
    bsctest: {
      url: "https://data-seed-prebsc-2-s3.binance.org:8545/",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      chainId: 97
    },
    hecotest: {
      url: "https://http-testnet.hecochain.com/",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      // gasPrice: 1e9,
      chainId: 256
    },
    arethtest: {
      url: "https://rinkeby.arbitrum.io/rpc",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      // gasPrice: 1e9,
      chainId: 421611
    },
    RINKEBY: {
      url: "https://rinkeby.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      gasPrice: 2e9,
      //gas: 6.9e6,
      chainId: 4
    },
    ETH: {
      // url: "http://127.0.0.1:8545",
      // accounts:{mnemonic:process.env.MNEMONIC},
      url: "https://mainnet.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      gasPrice: 75e9,
      // gas: 6.9e6,
      chainId: 1
    },
    BSC: {
      url: "https://bsc-dataseed.binance.org/",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      gasPrice: 5e9,
      //gas: 6e6,
      chainId: 56
    },
    HECO: {
      url: "https://http-mainnet.hecochain.com",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      // gasPrice: 5e9,
      // gas: 6e6,
      chainId: 128
    },
    MATIC: {
      url: "https://polygon-rpc.com/",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      // gasPrice: 5e9,
      // gas: 6e6,
      chainId: 137
    },
    ARBITRUM: {
      url: "https://arb1.arbitrum.io/rpc",
      accounts: [process.env.DEPLOYER_PRIVATE_KEY],
      // gasPrice: 5e9,
      // gas: 6e6,
      chainId: 42161
    },
  },
  mocha: {
    timeout: 100000
  },
}

import { config as dotEnvConfig } from "dotenv";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Wallet } from "zksync-ethers";
import * as hre from "hardhat";
import { verifyContractDeployment } from "./hardhatVerify";

// The ADMIN_ACCOUNT is an EOA selected for the deployment and initialization of the ZkTokenV3 contract on testnet.
const ADMIN_ACCOUNT = "0x506C21058Ec552f2B32A0ED78D3F31E354067A28";
const INITIAL_MINT_ACCOUNT = "0x506C21058Ec552f2B32A0ED78D3F31E354067A28";
const INITIAL_MINT_AMOUNT = 0;

// The SALT_IMPL and SALT_PROXY values are used to derive the contract addresses and are set to arbitrary values for testnet.
const SALT_IMPL = "0x8ceb348f712ba12ccf22e8a2228a74a6f75ea1d2ca4afe04ed7aa430528e4b11";
const SALT_PROXY = "0x8ceb348f712ba12ccf22e8a2228a74a6f75ea1d2ca4afe04ed7aa430528e4b11";

async function main() {
  dotEnvConfig();

  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!deployerPrivateKey) {
    throw "Please set DEPLOYER_PRIVATE_KEY in your .env file";
  }

  const contractName = "ZkTokenV3";
  console.log("Deploying " + contractName + "...");

  const zkWallet = new Wallet(deployerPrivateKey);
  const deployer = new Deployer(hre, zkWallet, "create2");

  const contract = await deployer.loadArtifact(contractName);
  const zkTokenV3 = await hre.zkUpgrades.deployProxy(
    deployer.zkWallet,
    contract,
    [ADMIN_ACCOUNT, INITIAL_MINT_ACCOUNT, INITIAL_MINT_AMOUNT],
    {
      initializer: "initialize",
      unsafeAllow: ["constructor"],
      saltImpl: SALT_IMPL,
      deploymentTypeImpl: "create2",
      saltProxy: SALT_PROXY,
      deploymentTypeProxy: "create2",
    }
  );

  await zkTokenV3.waitForDeployment();
  const proxyAddress = await zkTokenV3.getAddress();
  console.log(contractName + " deployed to:", proxyAddress);

  const initializeV2Tx = await zkTokenV3.initializeV2();
  await initializeV2Tx.wait();
  console.log("ZkTokenV3 initializeV2 complete");

  zkTokenV3.connect(zkWallet);
  const totalSupply = await zkTokenV3.totalSupply();
  console.log("ZkTokenV3 totalSupply: ", totalSupply);

  const maxSupply = await zkTokenV3.maxSupply();
  console.log("ZkTokenV3 maxSupply: ", maxSupply);

  const minterBalance = await zkTokenV3.balanceOf(INITIAL_MINT_ACCOUNT);
  console.log(`Balance of ${INITIAL_MINT_ACCOUNT}: ${minterBalance}`);

  await verifyContractDeployment(hre, proxyAddress, []);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

import { config as dotEnvConfig } from "dotenv";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Wallet } from "zksync-ethers";
import * as hre from "hardhat";
import { verifyContractDeployment } from "./hardhatVerify";
import { getGovernorDeploymentConfig } from "./GovernorDeploymentConfig";

async function main() {
  dotEnvConfig();

  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!deployerPrivateKey) {
    throw "Please set DEPLOYER_PRIVATE_KEY in your .env file";
  }

  const contractName = "ZkTokenV3";
  const deploymentConfig = getGovernorDeploymentConfig(hre.network.name);
  const tokenConfig = deploymentConfig.zkTokenV3;
  console.log(`Using ${contractName} deployment config for network ${hre.network.name}`);
  console.log("Deploying " + contractName + "...");

  const zkWallet = new Wallet(deployerPrivateKey);
  const deployer = new Deployer(hre, zkWallet, "create2");

  const contract = await deployer.loadArtifact(contractName);
  const zkTokenV3 = await hre.zkUpgrades.deployProxy(
    deployer.zkWallet,
    contract,
    [tokenConfig.adminAccount, tokenConfig.initialMintAccount, tokenConfig.initialMintAmount],
    {
      initializer: "initialize",
      unsafeAllow: ["constructor"],
      saltImpl: tokenConfig.saltImpl,
      deploymentTypeImpl: "create2",
      saltProxy: tokenConfig.saltProxy,
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

  const minterBalance = await zkTokenV3.balanceOf(tokenConfig.initialMintAccount);
  console.log(`Balance of ${tokenConfig.initialMintAccount}: ${minterBalance}`);

  await verifyContractDeployment(hre, proxyAddress, []);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

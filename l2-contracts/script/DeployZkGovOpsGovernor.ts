import { config as dotEnvConfig } from "dotenv";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Wallet } from "zksync-ethers";
import * as hre from "hardhat";
import { verifyContractDeployment } from "./hardhatVerify";
import { getGovernorDeploymentConfig } from "./GovernorDeploymentConfig";

// Before executing a real deployment, be sure to set these values as appropriate for the environment being deployed
// to. The values used in the script at the time of deployment can be checked in along with the deployment artifacts
// produced by running the scripts.
const contractName = "ZkGovOpsGovernor";

async function main() {
  dotEnvConfig();

  const deploymentConfig = getGovernorDeploymentConfig(hre.network.name);
  const governorConfig = deploymentConfig.govOpsGovernor;
  console.log(`Using ${contractName} deployment config for network ${hre.network.name}`);

  const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
  if (!deployerPrivateKey) {
    throw "Please set DEPLOYER_PRIVATE_KEY in your .env file";
  }

  const zkWallet = new Wallet(deployerPrivateKey);
  const deployer = new Deployer(hre, zkWallet);

  // deploy timelock controller for the GovOps governor
  console.log(`Deploying ${contractName} TimelockController contract...`);
  const timelockContract = await deployer.loadArtifact("TimelockController");
  const adminAddress = await zkWallet.getAddress();
  const timelockConstructorArgs = [governorConfig.timelockMinDelay, [], [], adminAddress];
  const timelock = await deployer.deploy(timelockContract, timelockConstructorArgs);
  const timeLockAddress = await timelock.getAddress();
  console.log(`${contractName} Governor TimelockController contract was deployed to ${timeLockAddress}`);

  console.log("Deploying " + contractName + "...");

  const contract = await deployer.loadArtifact(contractName);
  const constructorArgs = [{
		name: contractName, 
		token: deploymentConfig.tokenAddress, 
		timelock: timeLockAddress, 
		initialVotingDelay: governorConfig.votingDelay, 
		initialVotingPeriod: governorConfig.votingPeriod, 
		initialProposalThreshold: governorConfig.proposalThreshold, 
		initialQuorum: governorConfig.initialQuorum, 
		initialVoteExtension: governorConfig.initialVoteExtension, 
		vetoGuardian: governorConfig.vetoGuardian
	}];
  const govOpsGovernor = await deployer.deploy(contract, constructorArgs);

  const contractAddress = await govOpsGovernor.getAddress();
  console.log(`${contractName} was deployed to ${contractAddress}`);

  const theToken = await govOpsGovernor.token();
  console.log(`The Token is set to: ${theToken}`);

  (await timelock.grantRole(await timelock.PROPOSER_ROLE(), contractAddress)).wait();
  (await timelock.grantRole(await timelock.CANCELLER_ROLE(), contractAddress)).wait();
  (await timelock.grantRole(await timelock.EXECUTOR_ROLE(), contractAddress)).wait();
  console.log(`Timelock PROPOSER, CANCELLER, and EXECUTOR roles granted to ${contractName} contract`);
  (await timelock.renounceRole(await timelock.TIMELOCK_ADMIN_ROLE(), adminAddress)).wait();
  console.log(`ADMIN Role renounced for ${contractName} TimelockController contract (now self-administered)`);

  await verifyContractDeployment(hre, timeLockAddress, timelockConstructorArgs);
  await verifyContractDeployment(hre, contractAddress, constructorArgs);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });

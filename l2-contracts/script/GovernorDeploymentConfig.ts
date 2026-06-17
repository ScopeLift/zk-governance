export type ZkTokenV3DeploymentConfig = {
  adminAccount: string;
  initialMintAccount: string;
  initialMintAmount: number;
  saltImpl: string;
  saltProxy: string;
};

export type GovernorSettings = {
  timelockMinDelay: number;
  votingDelay: number;
  votingPeriod: number;
  proposalThreshold: number;
  initialQuorum: number;
  initialVoteExtension: number;
};

export type GovernorDeploymentConfig = {
  zkTokenV3: ZkTokenV3DeploymentConfig;
  tokenAddress: string;
  tokenGovernor: GovernorSettings & {
    vetoGuardian: string;
    proposeGuardian: string;
    isProposeGuarded: boolean;
  };
  protocolGovernor: GovernorSettings;
  govOpsGovernor: GovernorSettings & {
    vetoGuardian: string;
  };
};

const testnetGovernorSettings: GovernorSettings = {
  timelockMinDelay: 0,
  votingDelay: 60 * 15,
  votingPeriod: 60 * 15,
  proposalThreshold: 10,
  initialQuorum: 100,
  initialVoteExtension: 60 * 15,
};

export const GOVERNOR_DEPLOYMENT_CONFIGS: Record<
  string,
  GovernorDeploymentConfig
> = {
  zkSyncTestnet: {
    zkTokenV3: {
      adminAccount: "0x506C21058Ec552f2B32A0ED78D3F31E354067A28",
      initialMintAccount: "0x506C21058Ec552f2B32A0ED78D3F31E354067A28",
      initialMintAmount: 0,
      saltImpl:
        "0x8ceb348f712ba12ccf22e8a2228a74a6f75ea1d2ca4afe04ed7aa430528e4b11",
      saltProxy:
        "0x8ceb348f712ba12ccf22e8a2228a74a6f75ea1d2ca4afe04ed7aa430528e4b11",
    },
    tokenAddress: "0xe4eBdD42E083793990ea784589dA800baC291082",
    tokenGovernor: {
      ...testnetGovernorSettings,
      vetoGuardian: "0x506C21058Ec552f2B32A0ED78D3F31E354067A28",
      proposeGuardian: "0x506C21058Ec552f2B32A0ED78D3F31E354067A28",
      isProposeGuarded: false,
    },
    protocolGovernor: {
      ...testnetGovernorSettings,
    },
    govOpsGovernor: {
      ...testnetGovernorSettings,
      vetoGuardian: "0x506C21058Ec552f2B32A0ED78D3F31E354067A28",
    },
  },
};

export function getGovernorDeploymentConfig(
  networkName: string
): GovernorDeploymentConfig {
  const config = GOVERNOR_DEPLOYMENT_CONFIGS[networkName];

  if (!config) {
    throw new Error(
      `No governor deployment config found for Hardhat network "${networkName}"`
    );
  }

  return config;
}

type HardhatVerifyRuntime = {
  run: (taskName: string, taskArgs?: unknown) => Promise<unknown>;
};

export async function verifyContractDeployment(
  hre: HardhatVerifyRuntime,
  address: string,
  constructorArguments: unknown[]
): Promise<void> {
  if (process.env.VERIFY_AFTER_DEPLOY !== "true") {
    return;
  }

  console.log(`Verifying contract deployment at ${address}...`);

  await hre.run("verify:verify", {
    address,
    constructorArguments,
    libraries: {},
    noCompile: true,
  });

  console.log(`Verification submitted for ${address}`);
}

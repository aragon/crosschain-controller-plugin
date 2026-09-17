// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import { Script, console as console } from "forge-std/Script.sol";

import { IPluginSetup } from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";
import { PluginRepo } from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import { PluginRepoFactory } from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";

import { CrossChainControllerSetup } from "@src/CrossChainControllerSetup.sol";
import { CrossChainController } from "@src/CrossChainController.sol";

/// @title CreateRepo
/// @notice Deploys `CrossChainControllerSetup` inside PluginRepoFactory
contract CreateRepo is Script {
    /// @dev Slug this plugin is registered under in artifacts-hub
    ///      (`plugins.<slug>` in `addresses/<chainId>.json`). Must match the
    ///      catalog entry in
    ///      `artifacts-hub/scripts/lib/plugin-catalog.ts`.
    string internal constant PLUGIN_SLUG = "crosschain";

    /// @dev Pinned metadata for the initial build; update whenever a new
    ///      metadata JSON is re-pinned. Sources live in
    ///      `src/{release,build}-metadata.json`; pin them with `just ipfs-pin`.
    ///      Overridable via `RELEASE_METADATA_URI` / `BUILD_METADATA_URI` in `.env`.
    string internal constant DEFAULT_RELEASE_METADATA_URI = "ipfs://QmSfiCe5sCkrbA7gw6xriqCVx8iR1C2eAqL1iWYp9HbDAV";
    string internal constant DEFAULT_BUILD_METADATA_URI = "ipfs://QmZuSnnzNFA9Zw2Vzb1KgaxCqox5uzYBR3UUhbef3FoUzy";

    address deployer;
    string pluginEnsSubdomain;
    address managementDao;
    PluginRepoFactory pluginRepoFactory;
    bytes releaseMetadataUri;
    bytes buildMetadataUri;

    // Artifacts
    PluginRepo myPluginRepo;
    address pluginSetup;

    modifier broadcast() {
        uint256 privKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(privKey);

        deployer = vm.addr(privKey);
        console.log("General:");
        console.log("- Deploying from:   ", deployer);
        console.log("- Chain ID:         ", block.chainid);
        console.log();

        _;

        vm.stopBroadcast();
    }

    function setUp() public {
        // Pick the contract addresses from
        // https://github.com/aragon/osx/blob/main/packages/artifacts/src/addresses.json

        // Prepare the OSx factories for the current network
        pluginRepoFactory = PluginRepoFactory(vm.envAddress("PLUGIN_REPO_FACTORY_ADDRESS"));
        vm.label(address(pluginRepoFactory), "PluginRepoFactory");

        // Optional: an empty subdomain skips ENS registration entirely. The
        // repo is still deployed and registered on the `PluginRepoRegistry`,
        // it just has no ENS name.
        pluginEnsSubdomain = vm.envOr("PLUGIN_ENS_SUBDOMAIN", string(""));

        // The Aragon management DAO becomes the repo maintainer.
        // `MANAGEMENT_DAO_ADDRESS` is supplied by the active just-foundry
        // network config; override in `.env` for a non-standard maintainer.
        managementDao = vm.envAddress("MANAGEMENT_DAO_ADDRESS");
        vm.label(managementDao, "Maintainer");

        releaseMetadataUri = vm.envOr("RELEASE_METADATA_URI", bytes(DEFAULT_RELEASE_METADATA_URI));
        buildMetadataUri = vm.envOr("BUILD_METADATA_URI", bytes(DEFAULT_BUILD_METADATA_URI));
    }

    function run() public broadcast {
        // Deploys the `CrossChainController` implementation in its constructor.
        pluginSetup = address(new CrossChainControllerSetup(address(new CrossChainController())));

        myPluginRepo = pluginRepoFactory.createPluginRepoWithFirstVersion(
            pluginEnsSubdomain, pluginSetup, managementDao, releaseMetadataUri, buildMetadataUri
        );

        console.log("CrossChainController plugin:");
        console.log("- PluginRepo:                   ", address(myPluginRepo));
        console.log("- PluginSetup:                  ", pluginSetup);
        console.log("- Implementation:               ", IPluginSetup(pluginSetup).implementation());
        console.log("- Maintainer (Management DAO):  ", managementDao);
        console.log(
            "- ENS subdomain:                ", bytes(pluginEnsSubdomain).length == 0 ? "(none)" : pluginEnsSubdomain
        );

        // Emit the artifacts-hub envelope for later ingestion. Skipped in
        // simulations (no NETWORK_NAME wired in and no artifact to keep).
        if (!vm.envOr("SIMULATION", false)) {
            writeArtifact();
        }
    }

    /// @notice Writes `artifacts/artifacts-<network>-<timestamp>.json` in the
    ///         shape defined by `PluginArtifact` in
    ///         `artifacts-hub/scripts/schema.ts`. The `plugin` subtree matches
    ///         the AddressBook `Plugin` schema verbatim, so an artifacts-hub
    ///         ingest step can merge it into `addresses/<chainId>.json` under
    ///         `plugins.<slug>` without any per-plugin adapter code.
    function writeArtifact() internal {
        string memory networkName = vm.envString("NETWORK_NAME");
        string memory timestampStr = vm.toString(block.timestamp);
        address implementation = IPluginSetup(pluginSetup).implementation();

        // Skip the `ens` field entirely when the repo was deployed without an
        // ENS subdomain, matching the schema's `optional` treatment.
        string memory ensLine = bytes(pluginEnsSubdomain).length == 0
            ? ""
            : string.concat("    \"ens\": \"", pluginEnsSubdomain, ".plugin.dao.eth\",\n");

        string memory header = string.concat(
            "{\n",
            "  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n",
            "  \"network\": \"",
            networkName,
            "\",\n",
            "  \"timestamp\": ",
            timestampStr,
            ",\n",
            "  \"slug\": \"",
            PLUGIN_SLUG,
            "\",\n"
        );
        string memory pluginBody = string.concat(
            "  \"plugin\": {\n",
            "    \"repo\": \"",
            vm.toString(address(myPluginRepo)),
            "\",\n",
            ensLine,
            "    \"maintainer\": \"",
            vm.toString(managementDao),
            "\",\n"
        );
        string memory versionsBlock = string.concat(
            "    \"versions\": [\n",
            "      {\n",
            "        \"release\": 1,\n",
            "        \"build\": 1,\n",
            "        \"setup\": \"",
            vm.toString(pluginSetup),
            "\",\n",
            "        \"implementation\": \"",
            vm.toString(implementation),
            "\",\n",
            "        \"current\": true\n",
            "      }\n",
            "    ]\n",
            "  }\n",
            "}\n"
        );

        string memory outPath =
            string.concat(vm.projectRoot(), "/artifacts/artifacts-", networkName, "-", timestampStr, ".json");
        vm.writeFile(outPath, string.concat(header, pluginBody, versionsBlock));
        console.log("Artifact written to", outPath);
    }
}

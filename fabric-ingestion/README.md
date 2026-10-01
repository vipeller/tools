# Fabric ingestion

This walkthrough sets up a dataflow to send data to Fabric. The setup requires:
- Onboarded assets that provide telemetry.
- A dataflow that uses a specific WASM module to transform the telemetry into the required format.
- A Fabric setup to receive the data.

## Assets

Onboarded simulators provide most of the asset data for this walkthrough. To make that data available:
- Deploy a simulator pod.
- Run asset discovery to produce `discovered assets`.
- Onboard some or all of the `discovered assets`.

Onboarding the assets:
- Generates WoT TDs for the assets and uploads them to xRegistry.
- Starts the flow of data from the connector to MQ.

## Dataflow

Configure a dataflow to transform the asset data and send it to Fabric. This requires:
- Setting up Fabric and collecting the connection parameters.
- Configuring a graph that references the appropriate WASM module.
- Configuring the WASM module itself.

## Fabric

To set up Fabric:
- Create a Fabric capacity.
- Create a Fabric workspace that uses the capacity.
- Create an Event Stream instance to serve as the dataflow's connection point.
- Create a Kusto table to store the data from the dataflow.
- Configure the Event Stream to route data into the Kusto table.

The following pages describe each part of the setup. Although data flows from `Assets` to
`Dataflow` to `Fabric`, the setup order is `Assets`, `Fabric`, then `Dataflow` because Fabric
must be configured before the dataflow:

## Asset setup

Follow the [asset setup walkthrough](asset-setup.md) to deploy a simulator, register it as a device, and onboard its discovered assets.

## Fabric setup

Follow the [fabric setup walkthrough](fabric-setup.md) to create a capacity and workspace, set up an Eventhouse with a KQL table, configure an Eventstream, and collect its connection details for the dataflow.

## Dataflow setup

Follow the [fabric setup walkthrough](asset-setup.md) to create a dataflow with a wasm module that sends transformed data to Fabric.

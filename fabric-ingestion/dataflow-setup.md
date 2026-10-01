Use the yaml file below as a basis to dataflow setup. Only two parameters need change:
- The `host` under `DataflowEndpoint`. The current value starts with `esehmtcym4x6fbav5nc8a1g6`
  Search this value and change it to the one you saved when created a Fabric Eventstream. It was
  the `Bootstrap server` parameter, when the Custom Endpoint Source is selected and the `Kafka`
  pane is open with Entra ID Authentication (see [fabric setup walkthrough](fabric-setup.md))
- The `dataDestination` under `DataflowGraph`. The current value is `esehmtcym4x6fbav5nc8a1g6_eh`
  Search this value and change it to the one you saved when created a Fabric Eventstream. It was
  the `Topic name` parameter at the same place as the `Bottstrap server`.

After editing the file, save it (e.g. wasm_deploy.yaml). Then:

```
kubectl apply -f wasm_deploy.yaml
```

The template yaml file to modify:

```
apiVersion: connectivity.iotoperations.azure.com/v1
kind: DataflowEndpoint
metadata:
  name: mq
  namespace: azure-iot-operations
spec:
  endpointType: mqtt
  mqttSettings:
    host: "aio-broker.azure-iot-operations:18883"
    tls:
      mode: Enabled
      trustedCaCertificateConfigMapRef: azure-iot-operations-aio-ca-trust-bundle
    maxInflightMessages: 10000
    authentication:
      method: ServiceAccountToken
      serviceAccountTokenSettings:
        audience: aio-internal
---
apiVersion: connectivity.iotoperations.azure.com/v1
kind: DataflowEndpoint
metadata:
  name: wasmtofabric
  namespace: azure-iot-operations
spec:
  endpointType: Kafka
  kafkaSettings:
    authentication:
      method: SystemAssignedManagedIdentity
      systemAssignedManagedIdentitySettings: {}
    batching:
      latencyMs: 5
      maxBytes: 1000000
      maxMessages: 100000
      mode: Enabled
    cloudEventAttributes: Propagate
    compression: None
    consumerGroupId: mqConnector
    copyMqttProperties: Enabled
    host: esehmtcym4x6fbav5nc8a1g6.servicebus.windows.net:9093
    kafkaAcks: All
    partitionStrategy: Default
    tls:
      mode: Enabled
---
apiVersion: connectivity.iotoperations.azure.com/v1
kind: RegistryEndpoint
metadata:
  name: aiostaging
  namespace: azure-iot-operations
spec:
  host: aiostaging.azurecr.io
  authentication:
    method: Anonymous
    anonymousSettings: {}
---
apiVersion: connectivity.iotoperations.azure.com/v1
kind: DataflowGraph
metadata:
  name: mq-testing-enrich-graph
  namespace: azure-iot-operations
spec:
  profileRef: dataflowdeployment

  nodes:
    - nodeType: Source
      name: source
      sourceSettings:
        endpointRef: mq
        dataSources:
          - azure-iot-operations/data/#

    - nodeType: Graph
      name: mq-testing-enrich-transform
      graphSettings:
        registryEndpointRef: aiostaging
        artifact: azureiotoperations/graph-dataflow-wot-enrich:0.1.0
        configuration:
          - key: splitOpcUaDatasets
            value: "true"

    - nodeType: Destination
      name: sink
      destinationSettings:
        endpointRef: wasmtofabric
        dataDestination: esehmtcym4x6fbav5nc8a1g6_eh

  nodeConnections:
    - from:
        name: source
      to:
        name: mq-testing-enrich-transform

    - from:
        name: mq-testing-enrich-transform
      to:
        name: sink
```

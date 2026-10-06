"""Offline bash/jq/Helm tests: python3 -B -m unittest discover -s aio-tools/tests -v."""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUMP = "pump-device-integration-server"
CHART = ROOT / "charts" / PUMP
PACKAGE = ROOT / "charts" / f"{PUMP}-0.1.1.tgz"
NS = "azure-iot-operations"
POLICY = "http://opcfoundation.org/UA/SecurityPolicy#"
ASSET = "nsu=http://opcfoundation.org/UA/Pumps/;i=1052"
BASH, HELM, JQ = (shutil.which(tool) or "" for tool in ("bash", "helm", "jq"))

# Unknown mock calls fail closed, rather than falling through to real tools.
MOCK = r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["PUMP_TEST_DIR"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
state = json.loads((root / "state.json").read_text())
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, args]) + "\n")
def emit(value):
    print(json.dumps(value))
if name == "column":
    sys.stdout.write(sys.stdin.read())
elif name == "helm" and args[0] == "status":
    sys.exit(0 if state.get("installed") else 1)
elif name == "helm" and args[:2] == ["upgrade", "-i"]:
    pass
elif name == "kubectl" and "get" in args and "svc" in args:
    emit({"items": state.get("services", [])})
elif name == "kubectl" and "get" in args and "deploy" in args:
    print("deployment/mock-pump")
elif name == "kubectl" and "rollout" in args:
    pass
elif name == "az" and args[:2] == ["account", "show"]:
    emit({})
elif name == "az" and args[:2] in (["account", "set"], ["config", "set"]):
    pass
elif name == "az" and args[:2] == ["aks", "list"]:
    emit([])
elif name == "az" and args[:3] == ["iot", "ops", "show"]:
    emit({"name": "aio", "extendedLocation": {"name": "/custom/location", "type": "CustomLocation"}})
elif name == "az" and args[0] == "rest":
    url = args[args.index("--url") + 1]
    emit({} if "/devices/" in url and args[args.index("--method") + 1] == "get" else {"id": url})
else:
    sys.exit("Unexpected mock call: " + repr([name, args]))
'''


def service(name, ports=(("opc-tcp", 62542),), labels=None, selector=None, ns=NS):
    return {"metadata": {"name": name, "namespace": ns, "labels": labels or {}},
            "spec": {"selector": selector or {}, "clusterIP": "10.0.0.1",
                     "ports": [{"name": n, "port": p, "targetPort": p + 1} for n, p in ports]}}


@unittest.skipUnless(BASH and JQ, "bash and jq are required")
class ScriptTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        for tool in ("az", "kubectl", "helm", "column"):
            executable = self.tmp / tool
            executable.write_text(f"#!{sys.executable}\n" + MOCK)
            executable.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if k not in (
            "IMAGE", "RELEASE", "NAMESPACE", "CHART_PATH", "VALUES_FILE", "PUMP_COUNT", "TIMEOUT_SECONDS", "API")}
        self.env.update(PATH=str(self.tmp) + os.pathsep + os.environ["PATH"],
                        PUMP_TEST_DIR=str(self.tmp), SUBSCRIPTION_ID="sub", RESOURCE_GROUP="rg",
                        INSTANCE_NAME="aio", LOCATION="westus", ADR_NAMESPACE_NAME="adr")
        self.state: dict[str, object] = {"services": [service(f"pump-{PUMP}", labels={"app.kubernetes.io/name": PUMP})]}

    def run_script(self, script, *args, code=0, env=None):
        (self.tmp / "state.json").write_text(json.dumps(self.state))
        (self.tmp / "calls.jsonl").unlink(missing_ok=True)
        result = subprocess.run([BASH, str(ROOT / script), *map(str, args)], cwd=self.tmp,
                                env=self.env | (env or {}), text=True, capture_output=True, check=False, timeout=20)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def calls(self, tool=None):
        log = self.tmp / "calls.jsonl"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return [args for name, args in calls if name == tool] if tool else calls

    def payload(self):
        puts = [a for a in self.calls("az") if a[:3] == ["rest", "--method", "put"]]
        self.assertEqual(len(puts), 1)
        return json.loads(puts[0][puts[0].index("--body") + 1])

    def rows(self, *args):
        lines = self.run_script("show_simulators.sh", *args).stdout.splitlines()
        self.assertEqual(lines[0].split("\t"), ["NAMESPACE", "NAME", "KIND", "RELEASE", "CLUSTER-IP", "DNS-ADDRESS"])
        rows = {row[1]: row for row in (line.split("\t") for line in lines[1:])}
        self.assertEqual(len(rows), len(lines) - 1, "Duplicate simulator rows")
        return rows

    def test_default_deploy_encrypted_registration(self):
        output = self.run_script("deploy_pump.sh").stderr
        chart = PACKAGE if PACKAGE.exists() else CHART
        self.assertEqual(self.calls("helm"), [["status", "-n", NS, "pump"],
            ["upgrade", "-i", "pump", str(chart), "--namespace", NS, "--create-namespace", "--wait", "--timeout", "300s"]])
        self.assertIn(f"opc.tcp://pump-{PUMP}.{NS}.svc.cluster.local:62542/PumpDeviceIntegrationServer", output)
        hint = shlex.split(output.split("Next step: ", 1)[1].splitlines()[0])
        self.assertEqual(hint, ["./register_device.sh", "--service", f"pump-{PUMP}", "--namespace", NS,
            "--port", "62542", "--endpoint-path", "/PumpDeviceIntegrationServer", "--security-mode", "SignAndEncrypt",
            "--security-policy", POLICY + "Basic256Sha256", "--asset-type", ASSET])
        self.assertIn(["-n", NS, "get", "deploy", "-l", "app.kubernetes.io/instance=pump", "-o", "name"], self.calls("kubectl"))
        self.assertIn(["-n", NS, "rollout", "status", "deployment/mock-pump", "--timeout=300s"], self.calls("kubectl"))

    def test_custom_deploy_forwarding_and_actual_service(self):
        values = self.tmp / "extra values.json"
        values.write_text(json.dumps({"fullnameOverride": "actual-service", "service": {"port": 61234}}))
        self.state["services"] = [service("actual-service", (("http", 80), ("opc-tcp", 61234)), ns="custom")]
        output = self.run_script("deploy_pump.sh", "--release", "other", "--namespace", "custom", "--pumps", "7",
            "--image", "example/pump@sha256:abc", "--values", values, "--chart", CHART, "--timeout", "42",
            env={"RELEASE": "ignored", "NAMESPACE": "ignored", "PUMP_COUNT": "3", "IMAGE": "ignored",
                 "VALUES_FILE": "ignored", "CHART_PATH": "ignored", "TIMEOUT_SECONDS": "5"}).stderr
        self.assertEqual(self.calls("helm"), [["status", "-n", "custom", "other"], ["upgrade", "-i", "other", str(CHART),
            "--namespace", "custom", "--create-namespace", "--wait", "--timeout", "42s", "-f", str(values),
            "--set-string", "image=example/pump@sha256:abc", "--set", "pumps=7"]])
        self.assertIn("opc.tcp://actual-service.custom.svc.cluster.local:61234/PumpDeviceIntegrationServer", output)
        self.assertIn("--service actual-service --namespace custom --port 61234", output)
        self.assertIn(["-n", "custom", "get", "svc", "-l", "app.kubernetes.io/instance=other", "-o", "json"], self.calls("kubectl"))

    def test_values_only_does_not_override_image_or_pumps(self):
        values = self.tmp / "values.json"
        values.write_text(json.dumps({"image": "example/pump:pinned", "pumps": 9}))
        self.run_script("deploy_pump.sh", "--values", values)
        args = self.calls("helm")[-1]
        self.assertEqual(args[-2:], ["-f", str(values)])
        self.assertFalse({"--set", "--set-string"} & set(args))

    def test_existing_release_skips_install(self):
        self.state["installed"] = True
        output = self.run_script("deploy_pump.sh").stderr
        self.assertEqual(self.calls("helm"), [["status", "-n", NS, "pump"]])
        self.assertEqual(self.calls("kubectl"), [["-n", NS, "get", "svc", "-l", "app.kubernetes.io/instance=pump", "-o", "json"]])
        self.assertIn("already exists", output)
        self.assertIn("--security-mode SignAndEncrypt", output)

    def test_deploy_warns_when_no_opc_service_is_found(self):
        self.state["services"] = [service("metrics", (("http", 80),))]
        output = self.run_script("deploy_pump.sh").stderr
        self.assertIn("No Service with an opc-tcp port found", output)
        self.assertNotIn("Next step:", output)

    def test_invalid_deploy_options_rejected_before_external_calls(self):
        cases: list[tuple[str, ...]] = [("--pumps", n) for n in ("0", "101", "-1", "1.5", "abc", "01", "") ]
        cases += [("--timeout", n) for n in ("0", "-1", "1.5", "abc", "")]
        for flag in ("--image", "--release", "--namespace", "--chart", "--values", "--pumps", "--timeout"):
            cases.extend([(flag,), (flag, "--help")])
        for args in cases + [("--unknown",)]:
            with self.subTest(args=args):
                self.run_script("deploy_pump.sh", *args, code=2)
                self.assertEqual(self.calls(), [])

    def test_default_registration_payload_unchanged(self):
        self.run_script("register_device.sh", "--service", "opc-simulator")
        body = self.payload()
        endpoint = body["properties"]["endpoints"]["inbound"]["default"]
        self.assertIsInstance(endpoint["additionalConfiguration"], str)
        endpoint["additionalConfiguration"] = json.loads(endpoint["additionalConfiguration"])
        self.assertEqual(body, {"extendedLocation": {"name": "/custom/location", "type": "CustomLocation"}, "location": "westus",
            "properties": {"enabled": True, "externalDeviceId": "opc-simulator", "attributes": {"deviceType": "LDS"},
            "endpoints": {"inbound": {"default": {"address": f"opc.tcp://opc-simulator.{NS}.svc.cluster.local:4840",
                "endpointType": "Microsoft.OpcUa", "authentication": {"method": "Anonymous"}, "additionalConfiguration": {
                    "security": {"securityMode": "None", "securityPolicy": POLICY + "None", "autoAcceptUntrustedServerCertificates": True},
                    "runAssetDiscovery": True, "assetTypes": []}}}}}})

    def test_pump_registration_normalizes_path_security_and_asset_type(self):
        for path in ("PumpDeviceIntegrationServer", "/PumpDeviceIntegrationServer"):
            with self.subTest(path=path):
                self.run_script("register_device.sh", "--service", "pump", "--namespace", "custom", "--port", "61234",
                    "--device", "device", "--endpoint-name", "pump", "--endpoint-path", path,
                    "--security-mode", "SignAndEncrypt", "--security-policy", POLICY + "Basic256Sha256", "--asset-type", ASSET)
                body = self.payload()
                self.assertEqual(body["properties"]["externalDeviceId"], "device")
                endpoint = body["properties"]["endpoints"]["inbound"]["pump"]
                self.assertEqual(endpoint["address"], "opc.tcp://pump.custom.svc.cluster.local:61234/PumpDeviceIntegrationServer")
                self.assertEqual(json.loads(endpoint["additionalConfiguration"]), {"security": {"securityMode": "SignAndEncrypt",
                    "securityPolicy": POLICY + "Basic256Sha256", "autoAcceptUntrustedServerCertificates": True},
                    "runAssetDiscovery": True, "assetTypes": [ASSET]})

    def test_invalid_security_enum_rejected(self):
        result = self.run_script("register_device.sh", "--service", "pump", "--security-mode", "Encrypt", code=2)
        self.assertIn("Invalid security mode", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_simulator_existing_kinds_and_unknown_preserved(self):
        self.state["services"] = [service(name, (("ua", 4840), ("http", 80)), ns="legacy",
            labels={"app.kubernetes.io/name": app, "app.kubernetes.io/instance": "release"})
            for name, app in (("umati", "umati-sample-server"), ("opc", "opc-simulator"), ("other", "unrecognized"))]
        rows = self.rows("--namespace", "legacy")
        self.assertEqual(rows, {name: ["legacy", name, kind, "release", "10.0.0.1", f"{name}.legacy.svc.cluster.local:4840"]
                               for name, kind in (("umati", "umati"), ("opc", "opc-simulator"), ("other", "unknown"))})
        self.assertEqual(self.calls("kubectl"), [["get", "svc", "-n", "legacy", "-o", "json"]])

    def test_pump_table_ports_labels_selectors_and_all_namespaces(self):
        self.state["services"] = [
            service("label", labels={"app.kubernetes.io/name": PUMP}),
            service("app-label", (("unnamed", 62542),), labels={"app": PUMP}),
            service("selector", (("http", 4840), ("metrics", 62542), ("opc-tcp", 61234)), ns="custom",
                    labels={"app.kubernetes.io/name": "other"}, selector={"app.kubernetes.io/name": PUMP, "app.kubernetes.io/instance": "release"}),
            service("app-selector", (("http", 80), ("ua", 4840)), selector={"app": PUMP}),
            service("unrelated"), service("no-opc", (("http", 80),), labels={"app": PUMP})]
        rows = self.rows("--all-namespaces")
        self.assertEqual(set(rows), {"label", "app-label", "selector", "app-selector"})
        for name, ns, port in (("label", NS, 62542), ("app-label", NS, 62542), ("selector", "custom", 61234), ("app-selector", NS, 4840)):
            self.assertEqual(rows[name], [ns, name, "pump", "release" if name == "selector" else "", "10.0.0.1",
                                         f"{name}.{ns}.svc.cluster.local:{port}/PumpDeviceIntegrationServer"])
        self.assertEqual(self.calls("kubectl"), [["get", "svc", "--all-namespaces", "-o", "json"]])



@unittest.skipUnless(HELM, "Helm is required")
class ChartTests(unittest.TestCase):
    def helm(self, *args, valid=True):
        result = subprocess.run([HELM, *map(str, args)], text=True, capture_output=True, check=False, timeout=20)
        self.assertEqual(result.returncode == 0, valid, result.stdout + result.stderr)
        return result

    def render(self, *flags, release="pump", chart=CHART):
        return self.helm("template", release, chart, "--namespace", NS, *flags).stdout

    def document(self, rendered, kind):
        docs = [doc for doc in rendered.split("---\n") if re.search(rf"^kind: {kind}$", doc, re.MULTILINE)]
        self.assertEqual(len(docs), 1, rendered)
        return docs[0]

    def test_lint_and_defaults_one_server_per_release(self):
        for chart in (CHART, PACKAGE):
            with self.subTest(chart=chart):
                self.helm("lint", chart, "--strict")
                text = self.render(chart=chart)
                dep, svc = self.document(text, "Deployment"), self.document(text, "Service")
                for fragment in ('replicas: 1', 'image: "ghcr.io/opcfoundation/uanetstandard/pumpserver:latest-master"',
                                 'name: pumps\n              value: "2"', 'containerPort: 62542', 'emptyDir: {}', 'mountPath: /app/pki'):
                    self.assertIn(fragment, dep)
                self.assertEqual(dep.count("- name: pump\n"), 1)
                self.assertIn("port: 62542\n      targetPort: opc-tcp", svc)
                self.assertNotIn("kind: PersistentVolumeClaim", text)

    def test_image_pumps_service_and_fullname_overrides(self):
        text = self.render("--set-string", "image=example/pump:pinned", "--set", "pumps=100,service.port=61234,service.type=LoadBalancer,fullnameOverride=custom")
        dep, svc = self.document(text, "Deployment"), self.document(text, "Service")
        for doc in (dep, svc):
            self.assertIn("metadata:\n  name: custom\n", doc)
        self.assertIn('image: "example/pump:pinned"', dep)
        self.assertIn('name: pumps\n              value: "100"', dep)
        self.assertIn("replicas: 1", dep)
        self.assertIn("containerPort: 62542", dep)
        self.assertIn("type: LoadBalancer", svc)
        self.assertIn("port: 61234\n      targetPort: opc-tcp", svc)
        self.assertIn('name: pumps\n              value: "1"', self.render("--set", "pumps=1"))

    def test_persistence_generated_pvc_and_existing_claim(self):
        text = self.render("--set", "persistence.enabled=true,persistence.size=2Gi,persistence.storageClass=fast")
        pvc = self.document(text, "PersistentVolumeClaim")
        for fragment in (f"name: pump-{PUMP}-pki", 'storageClassName: "fast"', 'storage: 2Gi', '- ReadWriteOnce'):
            self.assertIn(fragment, pvc)
        self.assertIn(f"claimName: pump-{PUMP}-pki", self.document(text, "Deployment"))
        self.assertNotIn("emptyDir", text)
        existing = self.render("--set", "persistence.enabled=true,persistence.existingClaim=shared-pki")
        self.assertIn("claimName: shared-pki", existing)
        self.assertNotIn("kind: PersistentVolumeClaim", existing)
        self.assertNotIn("emptyDir", existing)

    def test_aio_connector_trust_projects_only_public_material(self):
        dep = self.document(self.render(), "Deployment")
        for fragment in ('secretName: "aio-opc-ua-gds-ca-cert"',
                         'key: "tls.crt"', 'path: aio-gds-ca.pem',
                         'secretName: "aio-opc-ua-gds-ca-crl"',
                         'key: "aio-opc-ua-gds-ca.crl"', 'path: aio-gds-ca.crl'):
            self.assertIn(fragment, dep)
        for name, path in (("connector-ca", "certs"), ("connector-crl", "crl")):
            self.assertIn(f"- name: {name}\n              mountPath: /app/pki/trusted/{path}\n              readOnly: true", dep)
        self.assertNotIn("tls.key", dep)
        self.assertNotIn("subPath:", dep)
        self.assertNotIn("optional: true", dep)

    def test_aio_connector_trust_can_be_overridden_or_disabled(self):
        dep = self.document(self.render("--set", "connectorTrust.caSecretName=custom-ca,connectorTrust.caCertificateKey=ca.pem,connectorTrust.crlSecretName=custom-crl,connectorTrust.crlKey=current.crl"), "Deployment")
        for fragment in ('secretName: "custom-ca"', 'key: "ca.pem"',
                         'secretName: "custom-crl"', 'key: "current.crl"'):
            self.assertIn(fragment, dep)
        disabled = self.render("--set", "connectorTrust.enabled=false")
        self.assertNotIn("connector-ca", disabled)
        self.assertNotIn("connector-crl", disabled)
        self.assertIn("mountPath: /app/pki", disabled)

    def test_enabled_aio_connector_trust_requires_secret_names_and_keys(self):
        for field in ("caSecretName", "caCertificateKey", "crlSecretName", "crlKey"):
            with self.subTest(field=field):
                result = self.helm("template", "pump", CHART, "--set-string", "connectorTrust." + field + "=", valid=False)
                self.assertIn("connectorTrust." + field + " is required", result.stderr)

    def test_invalid_pump_counts(self):
        for count in ("0", "101", "-1", "1.5", "abc", "true", ""):
            with self.subTest(count=count):
                result = self.helm("template", "pump", CHART, "--set-string", "pumps=" + count, valid=False)
                self.assertIn("pumps must be an integer between 1 and 100", result.stdout + result.stderr)

    def test_release_selectors_are_distinct_and_match_pod_labels(self):
        for release in ("pump-a", "pump-b"):
            text = self.render("--set", "nameOverride=short", release=release)
            for kind in ("Deployment", "Service"):
                doc = self.document(text, kind)
                self.assertIn(f"name: {release}-short", doc)
                selector, = re.findall(r"(?m)^  selector:\n(?:    matchLabels:\n)?((?: +app\.kubernetes\.io/[^\n]+\n)+)", doc)
                self.assertEqual(dict(re.findall(r"(app\.kubernetes\.io/\w+): (\S+)", selector)),
                                 {"app.kubernetes.io/name": PUMP, "app.kubernetes.io/instance": release})
            dep = self.document(text, "Deployment")
            self.assertIn(f"labels:\n        app.kubernetes.io/name: {PUMP}\n        app.kubernetes.io/instance: {release}", dep)

    def test_package_matches_source_rendering(self):
        for flags in ((), ("--set", "image=example/pump:pinned,pumps=7,service.port=61234,fullnameOverride=custom"),
                      ("--set", "persistence.enabled=true"), ("--set", "persistence.enabled=true,persistence.existingClaim=shared"),
                                            ("--set", "connectorTrust.enabled=false"), ("--set", "connectorTrust.caSecretName=custom-ca,connectorTrust.crlSecretName=custom-crl")):
            with self.subTest(flags=flags):
                self.assertEqual(self.render(*flags, chart=PACKAGE), self.render(*flags))


if __name__ == "__main__":
    unittest.main()

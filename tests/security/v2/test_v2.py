"""Offline Remna Security V2 tests. No network and no host firewall."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from security.v2.contracts import (
    DETECTOR_FACT,
    POLICY_EVALUATION,
    QUIC_PROFILE,
    load_schema,
    validate_contract,
)
from security.v2.crypto_aes import aes128_encrypt_block, aes128_gcm_encrypt
from security.v2.decoy import rollback as decoy_rollback
from security.v2.decoy import rotate as decoy_rotate
from security.v2.decoy import status as decoy_status
from security.v2.detector import DetectorQueue
from security.v2.durability import DegradedFsync, PosixFsync, atomic_write
from security.v2.endpoints import parse_endpoint, select_active
from security.v2.flags import evaluate_flags, policy_path, write_flags
from security.v2.generations import Crash, GenerationStore
from security.v2.health import HealthBook, classify_probe, probe_plan
from security.v2.plugin import contract as plugin_contract
from security.v2.plugin import reject_authoritative
from security.v2.policy import apply_recommendation, evaluate
from security.v2.quic_initial import (
    RFC9001_CLIENT_HP,
    RFC9001_CLIENT_INITIAL_SECRET,
    RFC9001_CLIENT_IV,
    RFC9001_CLIENT_KEY,
    RFC9001_INITIAL_SECRET,
    client_hello_invariants,
    generate_initial,
    initial_secrets,
    parse_initial,
    profile_content_hash,
)
from security.v2.scanners import admit, catalog_document
from security.v2.secrets import file_mode, promote_lkg, status as warp_status
from security.v2.warp_register import (
    RegistrationError,
    WarpMaterial,
    ambiguous_cleanup,
    idempotent_may_retry,
    new_identity,
    parse_registration_response,
    register_with_policy,
    registration_may_retry,
)
from security.v2.x25519 import public_key, shared_secret, x25519
from security.v2.xray_contract import activation_plan, activation_result, build_warp_outbounds, preflight_config

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
PROFILE = json.loads((ROOT / "security/v2/profiles/chrome-like-h3-v1.json").read_text(encoding="utf-8"))


class Contracts(unittest.TestCase):
    def test_schema_files_exist(self):
        for name in (
            DETECTOR_FACT,
            POLICY_EVALUATION,
            "remna-security.layer-generation.v1",
            "remna-security.feature-flags.v1",
            "remna-security.warp-status.v1",
            "remna-security.endpoint-health.v1",
            QUIC_PROFILE,
            "remna-security.xray-activation-plan.v1",
            "remna-security.xray-activation-result.v1",
            "remna-security.scanner-catalog.v1",
            "remna-security.decoy-status.v1",
            "remna-security.node-plugin.v1",
        ):
            doc = load_schema(name)
            self.assertEqual(doc["title"], name)

    def test_positive_and_negative_fixtures(self):
        good = json.loads((FIXTURES / "detector-fact-ok.json").read_text(encoding="utf-8"))
        bad = json.loads((FIXTURES / "detector-fact-bad.json").read_text(encoding="utf-8"))
        self.assertEqual(validate_contract(DETECTOR_FACT, good), [])
        self.assertTrue(validate_contract(DETECTOR_FACT, bad))
        good_p = json.loads((FIXTURES / "policy-eval-ok.json").read_text(encoding="utf-8"))
        bad_p = json.loads((FIXTURES / "policy-eval-bad.json").read_text(encoding="utf-8"))
        self.assertEqual(validate_contract(POLICY_EVALUATION, good_p), [])
        self.assertTrue(validate_contract(POLICY_EVALUATION, bad_p))


class Crypto(unittest.TestCase):
    def test_aes_nist(self):
        key = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
        plain = bytes.fromhex("00112233445566778899aabbccddeeff")
        cipher = bytes.fromhex("69c4e0d86a7b0430d8cdb78070b4c55a")
        self.assertEqual(aes128_encrypt_block(key, plain), cipher)

    def test_gcm_nist_empty(self):
        key = bytes(16)
        nonce = bytes(12)
        ciphertext, tag = aes128_gcm_encrypt(key, nonce, b"", b"")
        self.assertEqual(ciphertext, b"")
        self.assertEqual(tag, bytes.fromhex("58e2fccefa7e3061367f1d57a4e7455a"))

    def test_gcm_nist_block(self):
        key = bytes(16)
        nonce = bytes(12)
        ciphertext, tag = aes128_gcm_encrypt(key, nonce, bytes(16), b"")
        self.assertEqual(ciphertext, bytes.fromhex("0388dace60b6a392f328c2b971b2fe78"))
        self.assertEqual(tag, bytes.fromhex("ab6e47d42cec13bdf53a67b21257bddf"))

    def test_x25519_rfc(self):
        scalar = bytes.fromhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        peer = bytes.fromhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        expect = bytes.fromhex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        self.assertEqual(x25519(scalar, peer), expect)

    def test_x25519_dh(self):
        a = bytes(range(32))
        b = bytes(range(32, 64))
        self.assertEqual(shared_secret(a, public_key(b)), shared_secret(b, public_key(a)))

    def test_rfc9001_initial_keys(self):
        secrets = initial_secrets(bytes.fromhex("8394c8f03e515708"))
        self.assertEqual(secrets["initial_secret"], RFC9001_INITIAL_SECRET)
        self.assertEqual(secrets["client_initial_secret"], RFC9001_CLIENT_INITIAL_SECRET)
        self.assertEqual(secrets["key"], RFC9001_CLIENT_KEY)
        self.assertEqual(secrets["iv"], RFC9001_CLIENT_IV)
        self.assertEqual(secrets["hp"], RFC9001_CLIENT_HP)


class Quic(unittest.TestCase):
    def test_hundred_packets(self):
        seen = set()
        hellos = set()
        profile_hash = profile_content_hash(PROFILE)
        self.assertEqual(len(profile_hash), 64)
        doc = {
            "schema": QUIC_PROFILE,
            "profile_id": PROFILE["profile_id"],
            "version": PROFILE["version"],
            "immutable": True,
            "content_hash": profile_hash,
            "packet_size": PROFILE["packet_size"],
        }
        self.assertEqual(validate_contract(QUIC_PROFILE, doc), [])
        invariants = None
        for index in range(100):
            seed = hashlib.sha256(f"gen-{index}".encode()).digest()
            packet = generate_initial(PROFILE, packet_size=PROFILE["packet_size"], seed=seed)
            self.assertEqual(len(packet), PROFILE["packet_size"])
            self.assertNotIn(packet, seen)
            seen.add(packet)
            parsed = parse_initial(packet)
            self.assertNotIn(parsed.client_hello, hellos)
            hellos.add(parsed.client_hello)
            info = client_hello_invariants(parsed.client_hello, PROFILE)
            if invariants is None:
                invariants = info
            self.assertEqual(info["extension_types"], info["expected_extension_types"])
            self.assertEqual(info["extension_types"], invariants["extension_types"])
            self.assertEqual(info["ciphers"], invariants["ciphers"])
            self.assertEqual(info["legacy_version"], b"\x03\x03")
            self.assertIn(b"h3", info["alpn"])
            self.assertEqual(packet[1:5], b"\x00\x00\x00\x01")
        self.assertEqual(len(seen), 100)
        self.assertGreater(len({item[:20] for item in seen}), 90)


class FlagsAndPolicy(unittest.TestCase):
    def test_defaults_and_dependency_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            doc = evaluate_flags(base)
            self.assertEqual(doc["effective"]["FEATURE_EGRESS_WARP"], 0)
            self.assertEqual(doc["effective"]["FEATURE_WARP_QUIC_NOISE"], 0)
            self.assertEqual(doc["effective"]["FEATURE_AUTO_POLICY"], 0)
            self.assertTrue(doc["validation"]["ok"])
            failed = write_flags(base, {"FEATURE_WARP_QUIC_NOISE": 1, "FEATURE_EGRESS_WARP": 0})
            self.assertFalse(failed["validation"]["ok"])
            self.assertIn("quic_noise_requires_warp", failed["validation"]["errors"])
            self.assertEqual(failed["effective"]["FEATURE_WARP_QUIC_NOISE"], 0)
            stored = json.loads(policy_path(base).read_text(encoding="utf-8"))
            self.assertEqual(stored["configured"]["FEATURE_WARP_QUIC_NOISE"], 1)
            self.assertEqual(file_mode(policy_path(base)), 0o600)
            self.assertFalse(failed["live_effect"])

    def test_auto_policy_refuses_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            write_flags(base, {"FEATURE_AUTO_POLICY": 1})
            current = {"transaction_id": "tx", "egress": "direct"}
            fact = json.loads((FIXTURES / "detector-fact-ok.json").read_text(encoding="utf-8"))
            decision = evaluate(current, [fact])
            self.assertTrue(decision["pure"])
            self.assertTrue(decision["approval_required"])
            self.assertEqual(decision["target_layers"], ["inbound"])
            result = apply_recommendation(base, decision)
            self.assertFalse(result["mutated"])
            self.assertNotEqual(result["reason"], "")

    def test_detector_dedup_ttl_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            queue = DetectorQueue(Path(tmp), window_seconds=60, retention_seconds=24 * 3600, limit=2)
            fact = json.loads((FIXTURES / "detector-fact-ok.json").read_text(encoding="utf-8"))
            now = 1_700_000_100
            fact["observed_at"] = now
            first = queue.ingest(fact, now)
            second = queue.ingest(dict(fact), now + 10)
            self.assertTrue(second["deduped"])
            self.assertEqual(second["fact"]["occurrence_count"], 2)
            other = dict(fact)
            other["dedup_key"] = "other"
            queue.ingest(other, now + 11)
            third = dict(fact)
            third["dedup_key"] = "overflow"
            overflow = queue.ingest(third, now + 12)
            self.assertTrue(overflow["overflow"])
            expired = dict(fact)
            expired["dedup_key"] = "short"
            expired["ttl_seconds"] = 30
            expired["observed_at"] = now
            queue.limit = 10
            queue.ingest(expired, now)
            self.assertFalse(any(item["dedup_key"] == "short" for item in queue.facts(now + 31)))
            old = dict(fact)
            old["dedup_key"] = "ancient"
            old["observed_at"] = now - (24 * 3600) - 5
            old["ttl_seconds"] = 10**9
            queue.ingest(old, now)
            self.assertFalse(any(item["dedup_key"] == "ancient" for item in queue.facts(now)))
            self.assertTrue(first["accepted"])


class Planes(unittest.TestCase):
    def test_rollback_isolation_and_retention(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            marker = base / "data" / "tspu.txt"
            marker.parent.mkdir(parents=True)
            marker.write_text("10.1.0.0/24\n", encoding="utf-8")
            secret = base / "v2" / "egress" / "secrets" / "warp.lkg.json"
            secret.parent.mkdir(parents=True)
            secret.write_text("{}\n", encoding="utf-8")
            store = GenerationStore(base)
            with store.transaction(["inbound", "transport", "egress"]):
                for index in range(7):
                    store.commit("egress", f"tx-{index}", {"n": index, "plane": "egress"})
                store.commit("inbound", "tx-in", {"sets": ["REMNA_TSPU"], "plane": "inbound"})
                store.commit("transport", "tx-tr", {"profile": "xhttp", "plane": "transport"})
            kept = list((base / "v2" / "layers" / "egress" / "generations").iterdir())
            self.assertLessEqual(len(kept), 6)
            inbound = store.current("inbound")
            transport = store.current("transport")
            first = store.read_payload("egress", store.current("egress")["generation_id"])
            self.assertEqual(first["n"], 6)
            older = sorted((p.name for p in kept))
            target = None
            for name in older:
                payload = store.read_payload("egress", name)
                if payload["n"] == 4:
                    target = name
            self.assertIsNotNone(target)
            with store.transaction(["egress"]):
                store.rollback("egress", target, "rollback-egress")
            self.assertEqual(store.current("inbound"), inbound)
            self.assertEqual(store.current("transport"), transport)
            self.assertEqual(marker.read_text(encoding="utf-8"), "10.1.0.0/24\n")
            self.assertTrue(secret.exists())
            with store.transaction(["inbound"]):
                store.rollback("inbound", inbound["generation_id"], "rollback-in")
            self.assertTrue(secret.exists())
            self.assertEqual(store.current("egress")["generation_id"], target)

    def test_crash_and_degraded_fsync(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            store = GenerationStore(base)
            with store.transaction(["egress"]):
                with self.assertRaises(Crash):
                    store.commit("egress", "tx", {"n": 1}, crash_after="payload")
            self.assertIsNone(store.current("egress"))
            degraded = GenerationStore(base, DegradedFsync())
            with degraded.transaction(["inbound"]):
                pointer = degraded.commit("inbound", "tx", {"n": 2})
            self.assertEqual(pointer["durability"], "degraded")
            report = atomic_write(base / "plain.bin", b"abc", PosixFsync())
            self.assertEqual(report["durability"], "full")
            report = atomic_write(base / "plain2.bin", b"abc", DegradedFsync())
            self.assertEqual(report["durability"], "degraded")

    def test_lock_order_documented(self):
        text = (ROOT / "security/v2/generations.py").read_text(encoding="utf-8")
        self.assertIn("inbound, then transport, then egress", text)
        store = GenerationStore(Path(tempfile.mkdtemp()))
        with self.assertRaises(RuntimeError):
            store._check_order(["egress", "inbound"])


class Warp(unittest.TestCase):
    def test_retry_rules_and_parser(self):
        timeout = RegistrationError("ambiguous_timeout", "late", retryable=False)
        network = RegistrationError("network", "refused", retryable=True)
        self.assertFalse(registration_may_retry(timeout, 1))
        self.assertTrue(registration_may_retry(network, 1))
        self.assertFalse(registration_may_retry(network, 2))
        self.assertTrue(idempotent_may_retry(timeout, 1))
        self.assertFalse(idempotent_may_retry(timeout, 3))
        calls = {"n": 0}

        def boom(_request):
            calls["n"] += 1
            raise TimeoutError("deadline")

        private, _public = new_identity(b"\x11" * 32)
        with self.assertRaises(RegistrationError) as caught:
            register_with_policy(boom, private, "2026-09-23T00:00:00.000Z")
        self.assertEqual(caught.exception.kind, "ambiguous_timeout")
        self.assertEqual(calls["n"], 1)
        body = json.dumps(
            {
                "id": "account-raw",
                "token": "bearer-secret",
                "config": {
                    "peers": [
                        {
                            "public_key": "peer",
                            "endpoint": {"host": "engage.cloudflareclient.com", "v4": "162.159.192.1", "v6": "2606:4700:d0::a29f:c001"},
                        }
                    ],
                    "interface": {"addresses": {"v4": "172.16.0.2", "v6": "2606:4700:110::1"}},
                },
            }
        ).encode()
        parsed = parse_registration_response(200, body)
        self.assertIsNone(parsed["verified_expiry"])
        with self.assertRaises(RegistrationError) as waf:
            parse_registration_response(200, b"<html>Attention Required</html>")
        self.assertEqual(waf.exception.kind, "waf")
        with self.assertRaises(RegistrationError) as http:
            parse_registration_response(503, b"{}")
        self.assertEqual(http.exception.kind, "http_error")
        with self.assertRaises(RegistrationError) as bad:
            parse_registration_response(200, b"not-json")
        self.assertEqual(bad.exception.kind, "non_json")

    def test_secret_redaction_mode_and_lkg(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            private, public = new_identity(b"\x22" * 32)
            material = WarpMaterial(
                private_key=private,
                public_key=public,
                token="bearer-secret",
                provider_account_id="account-raw",
                peer_public_key="peer",
                addresses_v4="172.16.0.2/32",
                addresses_v6="2606:4700:110::1/128",
                endpoint_host="engage.cloudflareclient.com",
                endpoint_v4="162.159.192.1",
                endpoint_v6=None,
                reserved=None,
                verified_expiry=None,
                created_at=1,
                last_success_at=1,
                rotation_generation=2,
            )
            failed = promote_lkg(base, material, lambda _path: {"ok": False, "reason": "selftest"})
            self.assertFalse(failed["promoted"])
            self.assertFalse((base / "v2/egress/secrets/warp.lkg.json").exists())
            promoted = promote_lkg(base, material, lambda _path: {"ok": True})
            self.assertTrue(promoted["promoted"])
            current = base / "v2/egress/secrets/warp.json"
            self.assertEqual(file_mode(current), 0o600)
            view = warp_status(base)
            blob = json.dumps(view)
            self.assertNotIn("bearer-secret", blob)
            self.assertNotIn("account-raw", blob)
            self.assertNotIn(private.hex(), blob)
            material = ambiguous_cleanup(material, lambda: (_ for _ in ()).throw(RegistrationError("ambiguous_timeout", "maybe")))
            self.assertTrue(material.orphan_risk)
            self.assertFalse(material.deletion_claimed)

    def test_endpoints_and_health(self):
        v4 = parse_endpoint("162.159.192.1:2408", "configured")
        v6 = parse_endpoint("[2606:4700:d0::a29f:c001]:2408", "registration")
        name = parse_endpoint("engage.cloudflareclient.com:2408", "lkg")
        discovered = parse_endpoint("203.0.113.9:2408", "discovered")
        self.assertEqual((v4.family, v6.family, name.family), ("ipv4", "ipv6", "name"))
        with self.assertRaises(ValueError):
            parse_endpoint("2606:4700:d0::1:2408", "configured")
        healthy = {v4.key(), discovered.key(), name.key()}
        chosen = select_active([discovered, v6, name, v4], healthy)
        self.assertEqual(chosen.origin, "configured")
        self.assertIsNone(select_active([discovered], set()))
        self.assertEqual(select_active([discovered], {discovered.key()}).origin, "discovered")
        with tempfile.TemporaryDirectory() as tmp:
            book = HealthBook(Path(tmp), "boot-1", cooldown_seconds=50)
            book.observe(v4.key(), "configured", "ok", 100)
            self.assertNotIn(v4.key(), book.healthy_keys(100))
            book.observe(v4.key(), "configured", "ok", 101)
            self.assertIn(v4.key(), book.healthy_keys(101))
            book.observe(v4.key(), "configured", "probe_target", 102)
            self.assertIn(v4.key(), book.healthy_keys(102))
            book.observe(v4.key(), "configured", "warp_path", 103)
            book.observe(v4.key(), "configured", "warp_path", 104)
            self.assertIn(v4.key(), book.healthy_keys(104))
            book.observe(v4.key(), "configured", "warp_path", 105)
            self.assertNotIn(v4.key(), book.healthy_keys(105))
            rebooted = HealthBook(Path(tmp), "boot-2")
            self.assertEqual(rebooted.state["records"][v4.key()]["status"], "unknown")
        plan_a = probe_plan(["one.example", "two.example", "three.example"], "seed")
        plan_b = probe_plan(["one.example", "two.example", "three.example"], "seed")
        self.assertEqual(plan_a, plan_b)
        self.assertEqual(len(plan_a["targets"]), 2)
        self.assertEqual(classify_probe(False, False), "probe_target")
        self.assertEqual(classify_probe(False, True), "warp_path")


class XrayAndCatalog(unittest.TestCase):
    def test_outbound_shape_and_refusal(self):
        seed = hashlib.sha256(b"shape").digest()
        packet = generate_initial(PROFILE, packet_size=400, seed=seed)
        config = build_warp_outbounds(
            secret_key_b64="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
            peer_public="peer",
            endpoint="162.159.192.1:2408",
            address_v4="172.16.0.2/32",
            address_v6="2606:4700:110::1/128",
            quic_packet=packet,
        )
        checked = preflight_config(config)
        self.assertTrue(checked["ok"], checked)
        self.assertFalse(checked["execute"])
        warp = config["outbounds"][0]
        self.assertEqual(warp["streamSettings"]["sockopt"]["dialerProxy"], "warp-quic-noise")
        noises = config["outbounds"][1]["settings"]["noises"]
        self.assertEqual(noises[0]["type"], "rand")
        self.assertEqual(noises[1]["type"], "base64")
        bad = json.loads(json.dumps(config))
        bad["outbounds"].append({"protocol": "hysteria", "tag": "hy2"})
        self.assertFalse(preflight_config(bad)["ok"])
        unknown = activation_plan(None)
        self.assertTrue(unknown["refused"])
        self.assertFalse(unknown["execute"])
        sighup = activation_plan("SIGHUP")
        self.assertEqual(sighup["reason"], "sighup_refused")
        self.assertNotEqual(sighup["reload_method"], "SIGHUP")
        allowed = activation_plan("verified_restart")
        self.assertFalse(allowed["refused"])
        self.assertFalse(activation_result()["activated"])

    def test_scanner_catalog_and_pipeline(self):
        doc = catalog_document()
        self.assertEqual(doc["default_enabled"], ["tspu", "gov"])
        fast = admit("censys", b"10.0.0.0/8\n", provenance=None, panel="203.0.113.10", allow=[], previous=[])
        self.assertEqual(fast["reason"], "fast_feed_disabled")
        body = b"10.2.0.0/24\n203.0.113.10/32\n198.51.100.0/24\n"
        missing = admit("tspu", body, provenance=None, panel="203.0.113.10", allow=[], previous=[])
        self.assertEqual(missing["reason"], "missing_immutable_provenance")
        digest = hashlib.sha256(body).hexdigest()
        accepted = admit(
            "tspu",
            body,
            provenance={"immutable": True, "checksum": digest},
            panel="203.0.113.10",
            allow=["198.51.100.0/24"],
            previous=[],
        )
        self.assertTrue(accepted["ok"], accepted)
        self.assertEqual(accepted["accepted"], 1)
        self.assertGreaterEqual(accepted["panel_collisions"], 1)

    def test_decoy_and_plugin(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            key = b"node-secret"
            first = decoy_status(base, "node-a", key)
            again = decoy_status(base, "node-a", key)
            self.assertEqual(first["seed"], again["seed"])
            self.assertNotEqual(first["seed"], decoy_status(base, "node-b", key)["seed"])
            rotated = decoy_rotate(base, "node-a", key)
            self.assertEqual(rotated["seed"], first["seed"])
            self.assertEqual(rotated["generation"], 2)
            self.assertFalse(rotated["runtime_trackers"])
            rolled = decoy_rollback(base, "node-a", key)
            self.assertEqual(rolled["generation"], 1)
        plugin = plugin_contract(False)
        self.assertFalse(plugin["authoritative_ingress"])
        with self.assertRaises(ValueError):
            reject_authoritative({"authoritative_ingress": True})

    def test_no_global_flush_helpers(self):
        text = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "security/v2").rglob("*.py"))
        self.assertNotIn("iptables -F INPUT", text)
        self.assertNotIn("nft flush ruleset", text)
        self.assertNotIn("ufw reset", text)


class Cli(unittest.TestCase):
    def test_refuses_ainoc_and_activation(self):
        from security.v2.cli import main, resolve_base

        with self.assertRaises(SystemExit):
            resolve_base("/opt/ainoc/production")
        with self.assertRaises(SystemExit):
            resolve_base("/opt/remna-protection")
        with tempfile.TemporaryDirectory() as tmp:
            code = main(["policy-apply", "--base", tmp, "--evaluation", str(FIXTURES / "policy-eval-ok.json")])
            self.assertEqual(code, 2)
        self.assertEqual(main(["activation-result"]), 0)


if __name__ == "__main__":
    unittest.main()

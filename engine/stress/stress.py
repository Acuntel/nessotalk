#!/usr/bin/env python3
"""NessoTalk engine stress harness.

Hammers every piece of the hosted pipeline and prints a scored report:

  gate        license matrix: missing/bogus/real key, empty file, health
  accuracy    WER of cloud vs local decode on synthesized known-script clips
  latency     wall time by clip length, repeated, p50/p95
  concurrency N parallel requests to expose decoder serialization
  endurance   sequential burst, error rate

Usage:
  python3 stress.py --quick        # ~100 checks, a few minutes
  python3 stress.py --full         # ~250+ checks
  python3 stress.py --revocation   # live give/take-away proof (creates and
                                   # revokes a real test license)

Requires: macOS `say`/`afconvert` for clip synthesis, Brady's licensed
~/.dictation/config for the real-key path, .env.local for --revocation.
"""

import argparse
import concurrent.futures as cf
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.request
import uuid
import wave
from pathlib import Path

ENGINE = os.environ.get("ENGINE_URL", "https://nessotalk-engine-production.up.railway.app")
LOCAL_DECODER = "http://127.0.0.1:8977/inference"
SITE = "https://nesso.tech"

SCRIPTS = {
    "short": [
        "Send the updated invoice to the client before five today.",
        "The deploy finished and all the tests are passing now.",
        "Can you move our Tuesday meeting to Wednesday morning instead.",
    ],
    "medium": [
        "Okay so the quote is ready, it comes out to four thousand five hundred dollars including the extra coverage, and we can start on Tuesday if they sign the agreement tonight. Let them know the crew needs access to the back gate.",
        "I looked through the pull request this morning and the migration looks safe, but I want the rate limiter behind a feature flag before we ship it to production, and remember to rotate the API key after the demo.",
        "The onboarding flow drops people at the second step, so let's move the microphone permission later, show the value first, and only then ask for access. Track the completion rate before and after the change.",
    ],
    "long": [
        "Here is the plan for the week. Monday we finish the billing integration and test the webhook against the staging environment. Tuesday is the design review for the new dashboard, and I want the latency charts included this time. Wednesday we ship the update to the first fifty users and watch the error rates closely. Thursday is for fixing whatever breaks, and honestly something always breaks. Friday we write the changelog, record the demo video, and send the newsletter. If the numbers look good over the weekend we double the rollout on Monday.",
    ],
}

VOICES = ["Samantha", "Alex", "Karen"]
RATES = [175, 205]


# ---------- helpers ----------

class Tally:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.notes = []

    def check(self, ok, label):
        if ok:
            self.passed += 1
        else:
            self.failed += 1
            self.notes.append(f"FAIL: {label}")
        return ok


def norm_words(s):
    return re.sub(r"[^a-z0-9$ ]", "", s.lower().replace(",", "")).split()


def wer(ref, hyp):
    r, h = norm_words(ref), norm_words(hyp)
    if not r:
        return 0.0
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        d[i][0] = i
    for j in range(len(h) + 1):
        d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1,
                          d[i - 1][j - 1] + (r[i - 1] != h[j - 1]))
    return d[len(r)][len(h)] / len(r)


def synth(text, voice, rate, out_wav):
    aiff = out_wav.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(aiff), text],
                   check=True, capture_output=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(aiff), str(out_wav)], check=True, capture_output=True)
    aiff.unlink(missing_ok=True)


def wav_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def multipart(url, fields, file_field, file_path, headers=None, timeout=300):
    boundary = uuid.uuid4().hex
    body = b""
    for k, v in fields.items():
        body += (f"--{boundary}\r\nContent-Disposition: form-data; "
                 f"name=\"{k}\"\r\n\r\n{v}\r\n").encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; "
             f"filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode()
    body += Path(file_path).read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode()), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, {}, time.time() - t0
    except Exception as e:
        return -1, {"error": str(e)}, time.time() - t0


def cloud_transcribe(key, machine, wav):
    return multipart(f"{ENGINE}/transcribe",
                     {"machine": machine, "platform": "mac", "language": "en"},
                     "file", wav, headers={"x-license-key": key})


def local_transcribe(wav):
    return multipart(LOCAL_DECODER,
                     {"response_format": "json", "vad": "true", "language": "en"},
                     "file", wav)


def post_json(url, payload, headers=None):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, {}
    except Exception as e:
        return -1, {"error": str(e)}


def brady_credentials():
    cfg = Path.home() / ".dictation" / "config"
    key = ""
    for line in cfg.read_text().splitlines():
        if line.startswith("LICENSE_KEY="):
            key = line.split("=", 1)[1].strip()
    machine = subprocess.run(
        ["sh", "-c", "ioreg -rd1 -c IOPlatformExpertDevice | awk -F'\"' '/IOPlatformUUID/{print $4}'"],
        capture_output=True, text=True).stdout.strip()
    if not key or not machine:
        sys.exit("need LICENSE_KEY in ~/.dictation/config and a machine id")
    return key, machine


# ---------- test suites ----------

def suite_gate(t, key, machine, clip):
    print("\n== gate: license matrix ==")
    code, body, _ = multipart(f"{ENGINE}/transcribe",
                              {"machine": machine, "platform": "mac"}, "file", clip)
    t.check(code == 401, f"missing key -> 401 (got {code})")
    code, _, _ = cloud_transcribe("00000000-0000-0000-0000-000000000000",
                                  "stress-bogus", clip)
    t.check(code == 402, f"bogus key -> 402 (got {code})")
    code, body, _ = cloud_transcribe(key, machine, clip)
    t.check(code == 200 and body.get("text"), f"real key -> 200+text (got {code})")
    try:
        with urllib.request.urlopen(f"{ENGINE}/health", timeout=10) as r:
            h = json.loads(r.read().decode())
        t.check(h.get("decoder") is True, "health reports decoder up")
        t.check(h.get("model") == "engine-v1", "health reports engine-v1")
    except Exception as e:
        t.check(False, f"health reachable ({e})")
    empty = clip.parent / "empty.wav"
    empty.write_bytes(b"")
    code, _, _ = cloud_transcribe(key, machine, empty)
    t.check(code == 400, f"empty file -> 400 (got {code})")
    for label, code_expect in [("valid", True), ("unknown", False)]:
        k = key if label == "valid" else str(uuid.uuid4())
        code, body = post_json(f"{SITE}/api/license",
                               {"key": k, "machine": machine, "platform": "mac"})
        t.check(code == 200 and bool(body.get("valid")) is code_expect,
                f"/api/license {label} key -> valid={code_expect}")


def suite_accuracy_latency(t, key, machine, clips, repeats):
    print("\n== accuracy + latency: cloud vs local ==")
    lat = {"cloud": {}, "local": {}}
    wers = {"cloud": [], "local": []}
    for name, (wav, ref, bucket) in clips.items():
        for backend in ["cloud", "local"]:
            times = []
            for i in range(repeats):
                if backend == "cloud":
                    code, body, dt = cloud_transcribe(key, machine, wav)
                else:
                    code, body, dt = local_transcribe(wav)
                ok = t.check(code == 200 and body.get("text"),
                             f"{backend} decode {name} run{i} (got {code})")
                if ok:
                    times.append(dt)
                    if i == 0:
                        w = wer(ref, body["text"])
                        wers[backend].append(w)
                        t.check(w <= 0.35, f"{backend} WER {name} = {w:.2f} <= 0.35")
            if times:
                lat[backend].setdefault(bucket, []).extend(times)
    print(f"\n{'bucket':<8}{'audio':<8}{'cloud p50':<11}{'cloud p95':<11}{'local p50':<11}{'local p95':<11}")
    for bucket in ["short", "medium", "long"]:
        c = sorted(lat["cloud"].get(bucket, []))
        l = sorted(lat["local"].get(bucket, []))
        if not c or not l:
            continue
        secs = statistics.mean(wav_seconds(w) for w, r, b in clips.values() if b == bucket)
        p = lambda xs, q: xs[min(len(xs) - 1, int(q * len(xs)))]
        print(f"{bucket:<8}{secs:<8.1f}{p(c,0.5):<11.1f}{p(c,0.95):<11.1f}{p(l,0.5):<11.1f}{p(l,0.95):<11.1f}")
    for b in ["cloud", "local"]:
        if wers[b]:
            print(f"mean WER {b}: {statistics.mean(wers[b]):.3f}")
    return lat


def suite_concurrency(t, key, machine, clip, n):
    print(f"\n== concurrency: {n} parallel medium clips ==")
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=n) as ex:
        results = list(ex.map(lambda _: cloud_transcribe(key, machine, clip), range(n)))
    wall = time.time() - t0
    singles = [dt for code, _, dt in results if code == 200]
    for i, (code, body, dt) in enumerate(results):
        t.check(code == 200 and body.get("text"), f"concurrent req {i} ok ({code})")
    if singles:
        print(f"wall {wall:.1f}s · per-request {min(singles):.1f}-{max(singles):.1f}s "
              f"· serialization factor {wall / min(singles):.1f}x")
    return wall


def suite_endurance(t, key, machine, clip, n):
    print(f"\n== endurance: {n} sequential short clips ==")
    errors = 0
    times = []
    for i in range(n):
        code, body, dt = cloud_transcribe(key, machine, clip)
        ok = code == 200 and body.get("text")
        errors += 0 if ok else 1
        if ok:
            times.append(dt)
        t.check(ok, f"endurance req {i} ({code})")
    if times:
        print(f"errors {errors}/{n} · p50 {statistics.median(times):.1f}s · max {max(times):.1f}s")


def suite_revocation(t):
    print("\n== revocation: give and take away a real license ==")
    env = {}
    for line in (Path.home() / "dev/nessotalk/.env.local").read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    sb = env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
    svc = env["SUPABASE_SERVICE_ROLE_KEY"]
    hdrs = {"apikey": svc, "Authorization": f"Bearer {svc}"}

    email = f"stress+{uuid.uuid4().hex[:8]}@nesso.tech"
    code, user = post_json(f"{sb}/auth/v1/admin/users",
                           {"email": email, "password": uuid.uuid4().hex,
                            "email_confirm": True}, hdrs)
    t.check(code in (200, 201), f"create test user ({code})")
    uid = user.get("id")
    time.sleep(2)  # profile trigger

    def profile_patch(payload):
        req = urllib.request.Request(
            f"{sb}/rest/v1/profiles?id=eq.{uid}", method="PATCH",
            data=json.dumps(payload).encode())
        for k, v in {**hdrs, "Content-Type": "application/json",
                     "Prefer": "return=representation"}.items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())

    def profile_get():
        req = urllib.request.Request(
            f"{sb}/rest/v1/profiles?id=eq.{uid}&select=license_key,plan,revoked")
        for k, v in hdrs.items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())

    prof = profile_get()
    t.check(len(prof) == 1 and prof[0].get("license_key"), "profile + license auto-created")
    lic = prof[0]["license_key"]
    profile_patch({"plan": "pro"})

    clip = Path("/tmp/stress_revoke.wav")
    synth("This request proves the license lever works.", "Samantha", 190, clip)
    machine = "stress-revocation-machine"

    # GIVE: fresh pro license transcribes.
    code, body, _ = cloud_transcribe(lic, machine, clip)
    t.check(code == 200 and body.get("text"), f"GIVE: fresh license -> 200 ({code})")

    # TAKE AWAY: revoke, then verify at the license layer (instant) and note
    # the engine's positive-cache window (<=10 min) before its 402 lands.
    profile_patch({"revoked": True})
    code, body = post_json(f"{SITE}/api/license",
                           {"key": lic, "machine": machine, "platform": "mac"})
    t.check(code == 200 and body.get("valid") is False and body.get("reason") == "revoked",
            "TAKE: /api/license flips to revoked instantly")

    # A NEVER-CACHED key proves the engine's own 402 immediately: revoke a
    # second fresh license BEFORE its first engine call.
    code2, user2 = post_json(f"{sb}/auth/v1/admin/users",
                             {"email": f"stress+{uuid.uuid4().hex[:8]}@nesso.tech",
                              "password": uuid.uuid4().hex, "email_confirm": True}, hdrs)
    uid2 = user2.get("id")
    time.sleep(2)
    req = urllib.request.Request(f"{sb}/rest/v1/profiles?id=eq.{uid2}&select=license_key")
    for k, v in hdrs.items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as r:
        lic2 = json.loads(r.read().decode())[0]["license_key"]
    req = urllib.request.Request(f"{sb}/rest/v1/profiles?id=eq.{uid2}", method="PATCH",
                                 data=json.dumps({"plan": "pro", "revoked": True}).encode())
    for k, v in {**hdrs, "Content-Type": "application/json"}.items():
        req.add_header(k, v)
    urllib.request.urlopen(req, timeout=30)
    code, _, _ = cloud_transcribe(lic2, "stress-revocation-machine-2", clip)
    t.check(code == 402, f"TAKE: engine refuses a revoked license with 402 ({code})")

    # RESTORE: un-revoke; negative cache is 60s, so within ~70s it works again.
    profile_patch({"revoked": False})
    code, body = post_json(f"{SITE}/api/license",
                           {"key": lic, "machine": machine, "platform": "mac"})
    t.check(code == 200 and body.get("valid") is True, "RESTORE: license valid again instantly")

    # cleanup
    for u in [uid, uid2]:
        if u:
            req = urllib.request.Request(f"{sb}/auth/v1/admin/users/{u}", method="DELETE")
            for k, v in hdrs.items():
                req.add_header(k, v)
            try:
                urllib.request.urlopen(req, timeout=30)
            except Exception:
                pass
    print("test users cleaned up")


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--revocation", action="store_true")
    args = ap.parse_args()
    t = Tally()

    if args.revocation:
        suite_revocation(t)
    else:
        repeats = 5 if args.full else 3
        endurance_n = 40 if args.full else 15
        key, machine = brady_credentials()
        work = Path("/tmp/nessotalk-stress")
        work.mkdir(exist_ok=True)

        clips = {}
        for bucket, scripts in SCRIPTS.items():
            use = scripts if (args.full or bucket != "short") else scripts[:2]
            for i, script in enumerate(use):
                for v, voice in enumerate(VOICES if args.full else VOICES[:2]):
                    wav = work / f"{bucket}_{i}_{voice}.wav"
                    if not wav.exists():
                        synth(script, voice, RATES[v % len(RATES)], wav)
                    clips[f"{bucket}_{i}_{voice}"] = (wav, script, bucket)

        print(f"{len(clips)} clips synthesized · engine {ENGINE}")
        first_clip = next(iter(clips.values()))[0]
        suite_gate(t, key, machine, first_clip)
        suite_accuracy_latency(t, key, machine, clips, repeats)
        medium = next(w for w, r, b in clips.values() if b == "medium")
        suite_concurrency(t, key, machine, medium, 8 if args.full else 4)
        short = next(w for w, r, b in clips.values() if b == "short")
        suite_endurance(t, key, machine, short, endurance_n)

    print(f"\n===== {t.passed + t.failed} checks: {t.passed} passed, {t.failed} failed =====")
    for n in t.notes[:30]:
        print(" ", n)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

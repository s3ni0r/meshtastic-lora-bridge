#!/usr/bin/env swift
//
// asc_whats_new.swift — set a TestFlight build's "What to Test" text via the
// App Store Connect API (docs/release.md — release framework).
//
//   swift scripts/asc_whats_new.swift \
//     --key-id XXXXXXXXXX --issuer-id xxxxxxxx-… \
//     --key-file ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
//     --bundle-id fr.autoshot --version 1.5.101 --build 2607111015 \
//     --notes-file dist/whats_new.txt [--timeout 1800]
//
// Flow: ES256 JWT (CryptoKit) → resolve the app id by bundle id → poll the
// build (upload processing takes ~5–15 min) until VALID → PATCH (or POST)
// its en-US betaBuildLocalization's whatsNew. Idempotent — safe to re-run.
// No dependencies beyond macOS's swift + CryptoKit.
//

import Foundation
import CryptoKit

// MARK: - args

var opts: [String: String] = [:]
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let flag = argv.removeFirst()
    guard flag.hasPrefix("--"), !argv.isEmpty else {
        FileHandle.standardError.write("✗ bad argument: \(flag)\n".data(using: .utf8)!)
        exit(2)
    }
    opts[String(flag.dropFirst(2))] = argv.removeFirst()
}
func require(_ key: String) -> String {
    guard let v = opts[key], !v.isEmpty else {
        FileHandle.standardError.write("✗ missing --\(key)\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}
let keyID = require("key-id")
let issuerID = require("issuer-id")
let keyFile = (require("key-file") as NSString).expandingTildeInPath
let bundleID = require("bundle-id")
// --check-auth: stop after the JWT + app-record lookup (validates the key,
// signature, and ASC access without touching any build).
let checkAuthOnly = opts["check-auth"] != nil
let version = checkAuthOnly ? "" : require("version")
let buildNo = checkAuthOnly ? "" : require("build")
let notesFile = checkAuthOnly ? "" : require("notes-file")
let timeout = Double(opts["timeout"] ?? "1800") ?? 1800

guard let pem = try? String(contentsOfFile: keyFile, encoding: .utf8) else {
    FileHandle.standardError.write("✗ cannot read key file \(keyFile)\n".data(using: .utf8)!)
    exit(2)
}
var notes = ""
if !checkAuthOnly {
    guard let raw = try? String(contentsOfFile: notesFile, encoding: .utf8) else {
        FileHandle.standardError.write("✗ cannot read notes file \(notesFile)\n".data(using: .utf8)!)
        exit(2)
    }
    notes = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
}

// MARK: - JWT (ES256, 20-min expiry; regenerated per request — no expiry math)

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func makeToken() throws -> String {
    let header = try JSONSerialization.data(
        withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let now = Int(Date().timeIntervalSince1970)
    let payload = try JSONSerialization.data(withJSONObject: [
        "iss": issuerID, "iat": now, "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    ] as [String: Any])
    let signingInput = b64url(header) + "." + b64url(payload)
    let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    let sig = try key.signature(for: Data(signingInput.utf8))
    return signingInput + "." + b64url(sig.rawRepresentation)
}

// MARK: - tiny synchronous ASC client

let base = "https://api.appstoreconnect.apple.com"

func request(_ method: String, _ path: String,
             body: [String: Any]? = nil) throws -> [String: Any] {
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = method
    req.setValue("Bearer \(try makeToken())", forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let sem = DispatchSemaphore(value: 0)
    var out: (Data?, URLResponse?, Error?)
    URLSession.shared.dataTask(with: req) { out = ($0, $1, $2); sem.signal() }.resume()
    sem.wait()
    if let err = out.2 { throw err }
    let status = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
    let data = out.0 ?? Data()
    guard (200..<300).contains(status) else {
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "asc", code: status, userInfo: [
            NSLocalizedDescriptionKey: "\(method) \(path) → HTTP \(status): \(bodyText.prefix(400))",
        ])
    }
    if data.isEmpty { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("✗ \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - flow

do {
    // 1. App id by bundle id.
    let apps = try request("GET", "/v1/apps?filter[bundleId]=\(bundleID)&limit=1")
    guard let appID = ((apps["data"] as? [[String: Any]])?.first)?["id"] as? String else {
        fail("no ASC app record for bundle id \(bundleID)")
    }
    if checkAuthOnly {
        print("✓ auth OK — \(bundleID) is ASC app id \(appID)")
        exit(0)
    }

    // 2. Poll for the processed build (processing takes ~5–15 min).
    print("→ waiting for \(version) (\(buildNo)) to finish processing…")
    let deadline = Date().addingTimeInterval(timeout)
    var buildID: String?
    while Date() < deadline {
        let path = "/v1/builds?filter[app]=\(appID)&filter[version]=\(buildNo)"
            + "&filter[preReleaseVersion.version]=\(version)&limit=1"
        let builds = try request("GET", path)
        if let b = (builds["data"] as? [[String: Any]])?.first,
           let id = b["id"] as? String {
            let state = (b["attributes"] as? [String: Any])?["processingState"] as? String ?? "?"
            switch state {
            case "VALID":
                buildID = id
            case "FAILED", "INVALID":
                fail("build \(buildNo) processing state: \(state) — check App Store Connect")
            default:
                print("   … \(state)")
            }
        } else {
            print("   … not visible yet")
        }
        if buildID != nil { break }
        Thread.sleep(forTimeInterval: 30)
    }
    guard let buildID else {
        fail("timed out after \(Int(timeout)) s — re-run once processing finishes")
    }

    // 3. PATCH the existing en-US localization, or POST one if none exists.
    let locs = try request("GET", "/v1/builds/\(buildID)/betaBuildLocalizations")
    if let loc = (locs["data"] as? [[String: Any]])?.first,
       let locID = loc["id"] as? String {
        _ = try request("PATCH", "/v1/betaBuildLocalizations/\(locID)", body: [
            "data": ["type": "betaBuildLocalizations", "id": locID,
                     "attributes": ["whatsNew": notes]],
        ])
    } else {
        _ = try request("POST", "/v1/betaBuildLocalizations", body: [
            "data": ["type": "betaBuildLocalizations",
                     "attributes": ["whatsNew": notes, "locale": "en-US"],
                     "relationships": ["build": ["data": ["type": "builds", "id": buildID]]]],
        ])
    }
    print("✓ What to Test set for \(version) (\(buildNo))")
} catch {
    fail(error.localizedDescription)
}

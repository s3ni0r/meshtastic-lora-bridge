// One-time: create + install the App Store provisioning profile for
// com.s3ni0r.meshtracker via the ASC API (the export step's cloud signing
// lacked permission to do it implicitly). Reuses the release framework's
// JWT approach (CryptoKit ES256, no deps).
import Foundation
import CryptoKit

let env = ProcessInfo.processInfo.environment
guard let keyID = env["ASC_KEY_ID"], let issuerID = env["ASC_ISSUER_ID"] else {
    print("✗ missing ASC_KEY_ID/ASC_ISSUER_ID env"); exit(2)
}
let keyFile = ("~/.appstoreconnect/private_keys/AuthKey_\(keyID).p8" as NSString).expandingTildeInPath
let pem = try String(contentsOfFile: keyFile, encoding: .utf8)
let bundleIdentifier = "com.s3ni0r.meshtracker"

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func makeToken() throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let now = Int(Date().timeIntervalSince1970)
    let payload = try JSONSerialization.data(withJSONObject:
        ["iss": issuerID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"] as [String: Any])
    let input = b64url(header) + "." + b64url(payload)
    let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    return input + "." + b64url(try key.signature(for: Data(input.utf8)).rawRepresentation)
}
func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
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
    if let e = out.2 { throw e }
    let status = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
    let data = out.0 ?? Data()
    guard (200..<300).contains(status) else {
        print("✗ HTTP \(status) on \(method) \(path)")
        print(String(data: data, encoding: .utf8) ?? "")
        exit(3)
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// 0. idempotency: drop any existing profile with our name (a bad one blocks manual signing).
// filter[name] is unreliable with spaces — list and match client-side.
let existing = try request("GET", "/v1/profiles?limit=200")
for item in (existing["data"] as? [[String: Any]]) ?? [] {
    let nm = (item["attributes"] as? [String: Any])?["name"] as? String
    if nm == "MeshTracker App Store", let id = item["id"] as? String {
        _ = try request("DELETE", "/v1/profiles/\(id)")
        print("deleted stale profile \(id) (\(nm ?? ""))")
    }
}

// 1. bundle id resource — filter[identifier] PREFIX-matches (it also returns
// com.s3ni0r.meshtrackerwatch), so select the EXACT identifier explicitly.
let bid = try request("GET", "/v1/bundleIds?filter[identifier]=\(bundleIdentifier)")
let bidData = ((bid["data"] as? [[String: Any]]) ?? []).first { item in
    ((item["attributes"] as? [String: Any])?["identifier"] as? String) == bundleIdentifier
}
guard let bidData, let bidId = bidData["id"] as? String else {
    print("✗ bundle id \(bundleIdentifier) not registered (exact match)"); exit(4)
}
print("bundleId resource: \(bidId) (exact: \(bundleIdentifier))")

// 2. distribution certificates (Apple Distribution + legacy iOS Distribution)
var certIds: [String] = []
for t in ["DISTRIBUTION", "IOS_DISTRIBUTION"] {
    let c = try request("GET", "/v1/certificates?filter[certificateType]=\(t)&limit=20")
    for item in (c["data"] as? [[String: Any]]) ?? [] {
        if let id = item["id"] as? String { certIds.append(id) }
    }
}
guard !certIds.isEmpty else { print("✗ no distribution certificates on the team"); exit(5) }
print("distribution certs: \(certIds)")

// 3. create the App Store profile
let name = "MeshTracker App Store"
let body: [String: Any] = ["data": [
    "type": "profiles",
    "attributes": ["name": name, "profileType": "IOS_APP_STORE"],
    "relationships": [
        "bundleId": ["data": ["type": "bundleIds", "id": bidId]],
        "certificates": ["data": certIds.map { ["type": "certificates", "id": $0] }],
    ],
]]
let created = try request("POST", "/v1/profiles", body: body)
guard let attrs = (created["data"] as? [String: Any])?["attributes"] as? [String: Any],
      let content = attrs["profileContent"] as? String,
      let uuid = attrs["uuid"] as? String,
      let profileData = Data(base64Encoded: content) else {
    print("✗ profile created but content missing"); exit(6)
}

// 4. install where Xcode looks
for dir in ["~/Library/Developer/Xcode/UserData/Provisioning Profiles",
            "~/Library/MobileDevice/Provisioning Profiles"] {
    let d = (dir as NSString).expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    let path = d + "/\(uuid).mobileprovision"
    try profileData.write(to: URL(fileURLWithPath: path))
    print("installed: \(path)")
}
print("✓ App Store profile '\(name)' (uuid \(uuid)) ready")

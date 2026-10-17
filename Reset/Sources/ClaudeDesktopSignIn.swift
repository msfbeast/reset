import CommonCrypto
import Foundation
import Security

/// Opt-in live usage for the accounts signed in to the Claude desktop app, which Claude Code's sign-in doesn't cover.
///
/// The desktop app keeps a short-lived access token per Claude organization in its config.json, encrypted with a key
/// it stores in the Keychain as "Claude Safe Storage". Reset reads that key once per launch (macOS asks first, unless
/// it was told "Always Allow"), keeps it in memory, decrypts the cache in memory, and uses an unexpired token only to
/// ask api.anthropic.com for that account's usage, as LiveClaude does with Claude Code's. It never stores, refreshes
/// or rewrites a token or the cache: the desktop app renews its own tokens as it's used, and an expired one just
/// means that account goes back to being estimated.
enum ClaudeDesktopSignIn {
    struct SignIn: Equatable {
        var token: String
        var expiresAt: Date
        /// "team", "enterprise", "pro"… as the desktop app recorded it.
        var plan: String?
    }

    enum State: Equatable {
        case off
        /// No desktop app sign-in on this Mac.
        case notFound
        /// macOS hasn't let Reset read the desktop app's key yet; asking takes the user (see `allow`).
        case needsPermission
        case ok(accounts: Int)
        case problem(String)
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/config.json")
    }

    // MARK: Reading

    /// Every desktop-app account by organization, with its best token, plus how it went. Only uses the key `allow`
    /// read, so a scan never touches the Keychain: a read there can show macOS's prompt, and wait for it.
    static func read(now: Date = Date(), config: URL = configURL) -> (state: State, accounts: [String: SignIn]) {
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root[cacheV2Key] is String || root[cacheV1Key] is String else { return (.notFound, [:]) }
        lock.lock(); let result = keyResult; lock.unlock()
        let key: Data
        switch result {
        case .key(let k)?: key = k
        case .notFound?: return (.notFound, [:])
        case .failed(let why)?: return (.problem(why), [:])
        case .needsPermission?, nil: return (.needsPermission, [:])
        }
        guard let v2 = decodeCache(root[cacheV2Key], key: key), let v1 = decodeCache(root[cacheV1Key], key: key) else {
            return (.problem("Couldn't read the Claude desktop app's sign-in"), [:])
        }
        let accounts = signIns(v2: v2, v1: v1, account: root["lastKnownAccountUuid"] as? String, now: now)
        return (.ok(accounts: accounts.count), accounts)
    }

    /// One organization's token, read fresh for each fetch so a token the desktop app has since renewed is used.
    static func token(org: String, now: Date = Date()) -> LiveClaude.Token? {
        guard let s = read(now: now).accounts[org], usable(s, now: now) else { return nil }
        return LiveClaude.Token(access: s.token, expiresAt: s.expiresAt)
    }

    /// Reads the key from the Keychain, which shows macOS's "Reset wants to use … Claude Safe Storage" prompt unless
    /// Reset was told "Always Allow". Blocks until the user answers, so it runs off the main thread; `done` gets
    /// whether Reset has the key now, on the main queue.
    static func allow(done: @escaping (Bool) -> Void) {
        lock.lock(); let asked = generation; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = safeStorageKey()
            // Turned off while macOS was asking: keep nothing.
            lock.lock(); if generation == asked { keyResult = result }; let ok = generation == asked; lock.unlock()
            DispatchQueue.main.async { if case .key = result { done(ok) } else { done(false) } }
        }
    }

    /// Drops the key from memory, so turning the option off and on asks macOS again.
    static func forget() {
        lock.lock(); keyResult = nil; generation += 1; lock.unlock()
    }

    // MARK: Picking tokens

    static let cacheV2Key = "oauth:tokenCacheV2", cacheV1Key = "oauth:tokenCache"
    static let apiHost = "https://api.anthropic.com"
    /// Claude Code's and the desktop app's own login. The cache can hold several tokens for one organization,
    /// older partial-scope ones included; this client with full scopes is the one the desktop app itself uses.
    static let productionClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// A token about to expire would fail mid-fetch.
    static let expiryMargin: TimeInterval = 120
    /// An account stays listed, estimated, this long after its token expired, so it doesn't vanish (with its reset
    /// alert) whenever the desktop app has been closed for a few hours.
    static let listedAfterExpiry: TimeInterval = 7 * 86400

    static func usable(_ s: SignIn, now: Date) -> Bool { s.expiresAt > now.addingTimeInterval(expiryMargin) }

    /// The best token per organization, unexpired ones first, from the desktop app's two caches (`oauth:tokenCacheV2` and the
    /// older `oauth:tokenCache`). Keys are "<client>:<organization>:<api host>:<scopes>", and the desktop app
    /// moves them under "acct:<user>|" as it uses them: those count only for the user signed in now
    /// (`account`), and one there, a deletion marker included, replaces the same key without the prefix.
    static func signIns(v2: [String: Any], v1: [String: Any], account: String?, now: Date) -> [String: SignIn] {
        var entries: [String: Any] = [:]
        for cache in [v1, v2] {
            var legacy: [String: Any] = [:], scoped: [String: Any] = [:]
            for (key, entry) in cache {
                if key.hasPrefix("acct:") {
                    guard let bar = key.firstIndex(of: "|"), let account,
                          key.dropFirst(5)[..<bar].lowercased() == account.lowercased() else { continue }
                    scoped[String(key[key.index(after: bar)...])] = entry
                } else {
                    legacy[key] = entry
                }
            }
            // The newer cache wins over the older one, a scoped key over its legacy alias.
            entries.merge(legacy.merging(scoped) { $1 }) { $1 }
        }

        var best: [String: (SignIn, rank: [Double])] = [:]
        for (key, entry) in entries {
            guard let k = parseKey(key), k.scopes.contains("user:profile"),
                  let e = entry as? [String: Any], let token = e["token"] as? String, !token.isEmpty,
                  let ms = (e["expiresAt"] as? NSNumber)?.doubleValue else { continue }
            let expires = Date(timeIntervalSince1970: ms / 1000)
            guard expires > now.addingTimeInterval(-listedAfterExpiry) else { continue }
            let signIn = SignIn(token: token, expiresAt: expires, plan: e["subscriptionType"] as? String)
            let full = k.scopes.contains("user:inference")
            let rank: [Double] = [usable(signIn, now: now) ? 1 : 0, k.client == productionClient && full ? 1 : 0, full ? 1 : 0,
                                  Double(k.scopes.count), ms]
            if let current = best[k.org], current.rank.lexicographicallyPrecedes(rank) == false { continue }
            best[k.org] = (signIn, rank)
        }
        return best.mapValues(\.0)
    }

    static func parseKey(_ key: String) -> (client: String, org: String, scopes: [String])? {
        guard let host = key.range(of: ":\(apiHost):") else { return nil }
        let ids = key[..<host.lowerBound].split(separator: ":")
        guard ids.count == 2, UUID(uuidString: String(ids[0])) != nil, UUID(uuidString: String(ids[1])) != nil else { return nil }
        return (ids[0].lowercased(), ids[1].lowercased(), key[host.upperBound...].split(separator: " ").map(String.init))
    }

    // MARK: Decrypting

    /// Electron's safeStorage on macOS: "v10" + AES-128-CBC with a 16-space IV, keyed by PBKDF2-SHA1 of the
    /// Keychain password with the salt "saltysalt" and 1003 rounds.
    static func decodeCache(_ stored: Any?, key: Data) -> [String: Any]? {
        guard let text = stored as? String else { return [:] }
        guard let sealed = Data(base64Encoded: text), let plain = decrypt(sealed, key: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    static func deriveKey(password: String) -> Data? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        return status == kCCSuccess ? Data(key) : nil
    }

    static func decrypt(_ sealed: Data, key: Data) -> Data? { crypt(CCOperation(kCCDecrypt), sealed, key: key) }

    /// The inverse, for tests.
    static func encrypt(_ plain: Data, key: Data) -> Data? { crypt(CCOperation(kCCEncrypt), plain, key: key) }

    private static func crypt(_ op: CCOperation, _ input: Data, key: Data) -> Data? {
        let prefix = Data("v10".utf8)
        let body: Data
        if op == CCOperation(kCCDecrypt) {
            guard input.starts(with: prefix) else { return nil }
            body = input.dropFirst(prefix.count)
        } else {
            body = input
        }
        guard key.count == kCCKeySizeAES128 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = Array(key).withUnsafeBytes { k in
            Array(body).withUnsafeBytes { b in
                CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count,
                        iv, b.baseAddress, body.count, &out, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        let result = Data(out.prefix(moved))
        return op == CCOperation(kCCDecrypt) ? result : prefix + result
    }

    // MARK: The Keychain

    enum KeyResult { case key(Data), notFound, needsPermission, failed(String) }

    private static let lock = NSLock()
    /// What reading the key gave this launch; nil until `allow` has asked.
    private static var keyResult: KeyResult?
    /// Bumped by `forget`, so an answer that arrives after the option was turned off is dropped.
    private static var generation = 0

    /// Read through the Security framework rather than /usr/bin/security, so macOS's "Always Allow" trusts Reset
    /// alone; trusting the command-line tool would let any program read the desktop app's key without asking.
    private static func safeStorageKey() -> KeyResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8),
                  let key = deriveKey(password: password) else { return .failed("The Claude desktop app's key couldn't be read") }
            return .key(key)
        case errSecItemNotFound: return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .needsPermission
        case let status: return .failed("Keychain error \(status)")
        }
    }
}

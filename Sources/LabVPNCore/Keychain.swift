import Foundation
import Security

public enum Keychain {
    private static let service = "de.mariusrueve.labvpn"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func account(for profile: Profile) -> String { "\(profile.id):\(profile.username)" }

    public static func password(account: String) -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deletePassword(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    public static func setPassword(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var item = query(account: account)
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }
}

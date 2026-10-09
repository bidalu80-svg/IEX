import Foundation
import Combine
import Security

@MainActor
final class MailAccountStore: ObservableObject {
    static let shared = MailAccountStore()
    @Published private(set) var accounts: [MailAccount] = []
    @Published private(set) var loadError: String?
    private struct Record: Codable { var account: MailAccount; var credentials: MailCredentials }
    private var records: [Record] = []
    private let service = "com.ze.mail.accounts.v1"
    private init() { reload() }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "accounts", kSecAttrSynchronizable as String: false]
    }
    func reload() {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        do {
            if status == errSecItemNotFound { records = [] }
            else {
                guard status == errSecSuccess, let data = result as? Data else {
                    throw MailError.message("读取邮箱凭据失败，请解锁设备后重试（\(status)）。")
                }
                records = try JSONDecoder().decode([Record].self, from: data)
            }
            accounts = records.map(\.account); loadError = nil
        } catch { loadError = "邮箱资料读取失败，请解锁设备后重新打开。" }
    }
    func credentials(for id: UUID) throws -> MailCredentials {
        guard let value = records.first(where: { $0.account.id == id }) else { throw MailError.message("邮箱已删除，请重新选择账号。") }
        return value.credentials
    }
    func save(_ account: MailAccount, imapPassword: String, smtpPassword: String) throws {
        guard loadError == nil else { throw MailError.message("请先重新读取已保存的邮箱，避免覆盖原有资料。") }
        try account.validate()
        let previous = records.first { $0.account.id == account.id }?.credentials
        let incoming = imapPassword.isEmpty ? (previous?.imapPassword ?? "") : imapPassword
        let outgoing = smtpPassword.isEmpty ? (previous?.smtpPassword ?? incoming) : smtpPassword
        guard !incoming.isEmpty, !outgoing.isEmpty, MailCodec.safeLine(incoming), MailCodec.safeLine(outgoing) else {
            throw MailError.message("请输入有效的密码或邮箱授权码。")
        }
        guard !records.contains(where: { $0.account.id != account.id && $0.account.address.lowercased() == account.address.lowercased() && $0.account.imapHost.lowercased() == account.imapHost.lowercased() }) else {
            throw MailError.message("这个邮箱已经保存，请编辑现有邮箱。")
        }
        var updated = records
        let record = Record(account: account, credentials: MailCredentials(imapPassword: incoming, smtpPassword: outgoing))
        if let index = updated.firstIndex(where: { $0.account.id == account.id }) { updated[index] = record }
        else { updated.append(record) }
        try persist(updated)
    }
    func delete(_ account: MailAccount) throws {
        guard loadError == nil else { throw MailError.message("请先重新读取邮箱资料。") }
        try persist(records.filter { $0.account.id != account.id })
    }
    private func persist(_ values: [Record]) throws {
        let data = try JSONEncoder().encode(values)
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MailError.message("保存邮箱失败（钥匙串状态 \(status)），原有资料已保留。") }
        records = values; accounts = values.map(\.account)
    }
}

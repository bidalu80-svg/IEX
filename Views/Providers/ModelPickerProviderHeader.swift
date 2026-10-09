import SwiftUI

/// Independent buttons keep edit/balance taps from also folding the provider.
struct ModelPickerProviderHeader: View {
    let title: String
    let providerID: String
    let quota: ProviderAPIQuota?
    let canEdit: Bool
    let collapsed: Bool?
    let onEdit: () -> Void
    let onToggle: () -> Void

    private var amount: Decimal? {
        guard let value = quota?.displayAmount, !value.isNaN else { return nil }
        return value
    }
    static func amountText(_ amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = amount != 0 && abs(NSDecimalNumber(decimal: amount).doubleValue) < 0.01 ? 4 : 2
        let magnitude = amount < 0 ? -amount : amount
        let digits = formatter.string(from: NSDecimalNumber(decimal: magnitude)) ?? "\(magnitude)"
        // Do not let ICU insert a currency-spacing NBSP between US$ and digits;
        // the compact picker badge must match the reference across iOS versions.
        let prefix: String
        switch currency.uppercased() {
        case "USD": prefix = "US$"
        case "CNY": prefix = "¥"
        case "EUR": prefix = "€"
        case "GBP": prefix = "£"
        case "JPY": prefix = "JP¥"
        default: prefix = currency.uppercased() + " "
        }
        return (amount < 0 ? "-" : "") + prefix + digits
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { providerName; balance }
                VStack(alignment: .leading, spacing: 6) { providerName; balance }
            }
            Spacer(minLength: 4)
            if canEdit {
                Button(action: onEdit) {
                    Text("编辑").font(.subheadline.weight(.semibold))
                        .frame(minWidth: 36, minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .accessibilityIdentifier("model-picker-provider-edit-" + providerID)
                .accessibilityLabel(Text("编辑服务商 \(title)"))
            }
            if let collapsed {
                Button(action: onToggle) {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "展开服务商模型" : "折叠服务商模型")
                .accessibilityIdentifier("model-picker-provider-fold-" + providerID)
            }
        }
        .padding(.vertical, 2)
        .textCase(nil)
    }
    private var providerName: some View {
        Text(title).font(.headline.weight(.bold)).foregroundStyle(.primary)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var balance: some View {
        if let amount, let quota {
            Button(action: onEdit) {
                HStack(spacing: 4) {
                    Text("余额 \(Self.amountText(amount, currency: quota.currency))")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(amount <= 0 ? Color.red : Color.green, in: Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("model-picker-provider-balance-" + providerID)
        }
    }
}

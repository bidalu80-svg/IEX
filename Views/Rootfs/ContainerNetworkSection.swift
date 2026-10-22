//
//  ContainerNetworkSection.swift
//  ZeApp
//
//  [T-container-dns] Settings → Rootfs Management → Container Network.
//
//  The editor only appears in Custom mode, so the common path (Automatic)
//  stays a single row. In Custom mode the warning and the Save button live in
//  the same card as the field: the state of the input, what is wrong with it
//  and the action that fixes it are never more than one glance apart.
//

import SwiftUI

struct ContainerNetworkSection: View {
    @ObservedObject var dns: ContainerDNSSettings

    @State private var draft: String = ""

    private var servers: [String] {
        ContainerDNSSettings.validServers(from: draft)
    }

    var body: some View {
        Section {
            HStack {
                Text("DNS Mode")
                Spacer()
                Picker(selection: $dns.mode) {
                    ForEach(ContainerDNSMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Color.secondary)
            }

            if dns.mode == .custom {
                editor

                if servers.isEmpty {
                    Text("Enter at least one DNS server. System DNS stays in use until then.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    dns.customText = draft
                    dns.apply()
                } label: {
                    Text("Save DNS Servers")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(servers.isEmpty ? Color.secondary : Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(servers.isEmpty)
            }
        } header: {
            Text("Container Network")
        } footer: {
            if dns.mode == .automatic {
                Text("Automatic follows system DNS and re-syncs on every network change. Keep it on Automatic when a proxy app uses Fake-IP or TUN mode, or when a VPN supplies DNS.")
            } else {
                Text("Custom writes only these servers to the container's /etc/resolv.conf and keeps them unchanged across network changes. Separate addresses with newlines or commas; Linux uses the first 3.")
            }
        }
        .onAppear {
            draft = dns.customText
        }
        .onChange(of: dns.mode) { newValue in
            if newValue == .custom {
                draft = dns.customText
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text("One IPv4 or IPv6 address per line")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(UIColor.placeholderText))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $draft)
                .font(.system(size: 17, design: .monospaced))
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

//
//  CapabilityMatrixView.swift
//  mailin
//
//  The on/off matrix: every capability of every page, one switch each.
//
//  What this view is for, beyond convenience: a capability that has never been
//  run against a real archive ships OFF, and this is where someone turns it on
//  deliberately, having read what it does and what happens if they turn it
//  back off. That makes a risky engine shippable without it being imposed.
//
//  The three things every row states, because a switch without them is a trap:
//   • whether it is running RIGHT NOW, and if not, why not (page off,
//     switched off, or a dependency off — never an unexplained dim row);
//   • what happens to existing work when it is switched off (always: nothing
//     is deleted);
//   • its maturity, so "Experimental" is visible before the flip, not after.
//

import SwiftUI

struct CapabilityMatrixView: View {
    @Environment(ModuleRegistry.self) private var modules
    @Environment(\.dismiss) private var dismiss

    /// Show one page's capabilities, or all four when nil.
    var scope: AppModule?

    @State private var pendingOff: Capability?
    @State private var showOnlyRunning = false

    private var pages: [AppModule] {
        if let scope { return [scope] }
        return AppModule.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(pages) { page in
                        pageSection(page)
                    }
                    footnote
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .confirmationDialog(
            pendingOff.map { "Switch off “\($0.displayName)”?" } ?? "",
            isPresented: Binding(get: { pendingOff != nil },
                                 set: { if !$0 { pendingOff = nil } }),
            titleVisibility: .visible
        ) {
            if let capability = pendingOff {
                Button("Switch off") {
                    modules.set(capability, enabled: false)
                    pendingOff = nil
                }
                Button("Keep it on", role: .cancel) { pendingOff = nil }
            }
        } message: {
            if let capability = pendingOff {
                Text(offMessage(for: capability))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scope?.displayName ?? "Features")
                    .font(.title3.weight(.semibold))
                Text("Every capability can be switched off on its own. Nothing is deleted when you do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Running only", isOn: $showOnlyRunning)
                .toggleStyle(.switch)
                .font(.caption)
                .help("Hide everything that is not currently active")
            if scope != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: One page

    @ViewBuilder
    private func pageSection(_ page: AppModule) -> some View {
        let capabilities = Capability.all(for: page)
            .filter { !showOnlyRunning || modules.isOn($0) }

        if !capabilities.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(page.displayName)
                        .font(.headline)
                    if !modules.isEnabled(page) {
                        Text("page off")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(modules.activeCapabilities(of: page).count) of \(Capability.all(for: page).count) running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // A page that is off is shown, not hidden: the user needs to
                // see that these capabilities exist and why none of them runs.
                if !modules.isEnabled(page) {
                    Text("Switch this page on to use anything below. These switches keep their positions meanwhile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(capabilities) { capability in
                    row(capability)
                    if capability != capabilities.last { Divider() }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: One capability

    private func row(_ capability: Capability) -> some View {
        let block = modules.block(capability)
        let isRunning = block == nil

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isRunning ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isRunning ? .green : .secondary)
                    .font(.caption)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(capability.displayName)
                            .font(.callout.weight(.medium))
                        maturityTag(capability.maturity)
                    }
                    Text(capability.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Why it is not running, when the switch says it should be.
                    if let block, modules.switchPosition(capability) {
                        Label(block.explanation, systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if let warning = capability.warning, modules.switchPosition(capability) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Toggle("", isOn: Binding(
                        get: { modules.switchPosition(capability) },
                        set: { newValue in
                            if newValue {
                                modules.set(capability, enabled: true)
                            } else {
                                // Ask first, because turning one off can turn
                                // its dependents off too.
                                pendingOff = capability
                            }
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(capability.displayName)
                        .accessibilityValue(isRunning ? "running" : (block?.explanation ?? "off"))

                    if modules.hasExplicitChoice(capability) {
                        Button("Default") { modules.resetToDefault(capability) }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .help("Return to the shipped default (\(capability.defaultsOn ? "on" : "off"))")
                    }
                }
            }

            if !modules.switchPosition(capability) {
                Text(capability.whenOff)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func maturityTag(_ maturity: Capability.Maturity) -> some View {
        let color: Color = switch maturity {
        case .stable: .green
        case .preview: .blue
        case .experimental: .orange
        }
        return Text(maturity.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .opacity(maturity == .stable ? 0 : 1)   // no badge for the norm
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("About these switches")
                .font(.caption.weight(.semibold))
            Text("""
                “Experimental” and “Preview” capabilities ship switched off, so installing an \
                update never changes how your archive behaves until you ask it to. Switching \
                anything off hides or stops it — it never deletes cases, documents, holds, \
                audit entries or imported mail.
                """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func offMessage(for capability: Capability) -> String {
        var message = capability.whenOff
        let dependents = capability.dependents.filter { modules.switchPosition($0) }
        if !dependents.isEmpty {
            message += "\n\nThis will also stop: "
                + dependents.map(\.displayName).joined(separator: ", ")
                + " — their switches stay on and they resume when this is back on."
        }
        return message
    }
}

//
//  AutomationRulesView.swift
//  mailin
//
//  SwiftUI interface for managing automation rules
//

import SwiftUI

struct AutomationRulesView: View {
    @StateObject private var engine = AutomationRulesEngine()
    @State private var showingAddSheet = false
    @State private var editingRule: AutomationRule?
    @State private var showingRunConfirmation = false
    @State private var runResults: [UUID: [AutomationAction]]?
    @State private var showingResults = false
    @State private var showTutorial = false

    let emails: [MBOXParser.RawEmail]

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
                .foregroundColor(AppColors.separatorLight)

            if engine.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }
        }
        .background(AppColors.backgroundPrimary)
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 650, minHeight: 400, idealHeight: 600)
        #endif
        .sheet(isPresented: $showingAddSheet) {
            RuleEditorSheet(engine: engine, rule: nil)
                .resizableSheet()
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(engine: engine, rule: rule)
                .resizableSheet()
        }
        .sheet(isPresented: $showingResults) {
            RunResultsSheet(results: runResults ?? [:], emails: emails)
                .resizableSheet()
        }
        .featureTutorial(.automationRules, key: "automation_rules_tutorial_seen", isPresented: $showTutorial)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text("Automation Rules")
                    .font(Typography.title2)
                    .accessibilityAddTraits(.isHeader)
                Text("\(engine.rules.count) rule\(engine.rules.count == 1 ? "" : "s") configured")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }

            Spacer()

            HStack(spacing: Spacing.xSmall) {
                Button {
                    showingRunConfirmation = true
                } label: {
                    Label("Run Rules Now", systemImage: "play.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(emails.isEmpty || engine.rules.isEmpty)
                .accessibilityLabel("Run all enabled rules on current emails")
                .adaptiveDestructiveConfirmation(
                    "Run Automation Rules",
                    isPresented: $showingRunConfirmation,
                    message: "This will evaluate \(engine.rules.filter(\.isEnabled).count) enabled rule\(engine.rules.filter(\.isEnabled).count == 1 ? "" : "s") against \(emails.count) email\(emails.count == 1 ? "" : "s").",
                    actionTitle: "Run Rules"
                ) {
                    runResults = engine.applyRules(to: emails)
                    showingResults = true
                }

                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Add a new automation rule")

                TutorialHelpButton(showTutorial: $showTutorial)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "gearshape.2",
            title: "No Automation Rules",
            message: "Create rules to automatically categorize, tag, and flag emails based on conditions like sender, subject, sentiment, and more.",
            actionTitle: "Create First Rule"
        ) {
            showingAddSheet = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rules List

    private var rulesList: some View {
        List {
            ForEach(engine.rules) { rule in
                RuleRowView(rule: rule, engine: engine) {
                    editingRule = rule
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(rule.name), \(rule.isEnabled ? "enabled" : "disabled"), \(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s"), \(rule.actions.count) action\(rule.actions.count == 1 ? "" : "s")")
            }
            .onDelete { offsets in
                engine.removeRule(at: offsets)
            }
            .onMove { source, destination in
                engine.moveRule(from: source, to: destination)
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Rule Row

private struct RuleRowView: View {
    let rule: AutomationRule
    @ObservedObject var engine: AutomationRulesEngine
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: Spacing.small) {
            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in engine.toggleRule(rule.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable \(rule.name)")

            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Text(rule.name)
                    .font(Typography.headline)
                    .foregroundColor(rule.isEnabled ? .primary : AppColors.secondary)

                HStack(spacing: Spacing.xSmall) {
                    Label("\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s")", systemImage: "line.3.horizontal.decrease.circle")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.info)

                    Label("\(rule.actions.count) action\(rule.actions.count == 1 ? "" : "s")", systemImage: "bolt.circle")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.success)
                }
            }

            Spacer()

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.title3)
                    .foregroundColor(AppColors.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(rule.name)")
        }
        .padding(.vertical, Spacing.xxSmall)
        .opacity(rule.isEnabled ? 1.0 : 0.6)
    }
}

// MARK: - Rule Editor Sheet

private struct RuleEditorSheet: View {
    @ObservedObject var engine: AutomationRulesEngine
    let rule: AutomationRule?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var isEnabled: Bool = true
    @State private var conditions: [AutomationCondition] = []
    @State private var actions: [AutomationAction] = []

    // Condition builder state
    @State private var selectedConditionType: String = AutomationCondition.allTypeLabels.first ?? ""
    @State private var conditionValue: String = ""

    // Action builder state
    @State private var selectedActionType: String = AutomationAction.allTypeLabels.first ?? ""
    @State private var actionValue: String = ""

    private var isEditing: Bool { rule != nil }

    var body: some View {
        NavigationStack {
            Form {
                ruleInfoSection
                conditionsSection
                actionsSection
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Rule" : "New Rule")
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 450, idealHeight: 550)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityLabel("Cancel and discard changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add Rule") {
                        saveRule()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || conditions.isEmpty || actions.isEmpty)
                    .accessibilityLabel(isEditing ? "Save rule changes" : "Add new rule")
                }
            }
            .onAppear {
                if let rule {
                    name = rule.name
                    isEnabled = rule.isEnabled
                    conditions = rule.conditions
                    actions = rule.actions
                }
            }
        }
    }

    // MARK: - Sections

    private var ruleInfoSection: some View {
        Section {
            TextField("Rule name", text: $name)
                .font(Typography.body)
                .accessibilityLabel("Rule name")
            Toggle("Enabled", isOn: $isEnabled)
                .accessibilityLabel("Rule enabled")
        } header: {
            Text("Rule Info")
                .font(Typography.caption1)
        }
    }

    private var conditionsSection: some View {
        Section {
            ForEach(conditions) { condition in
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundColor(AppColors.info)
                        .accessibilityHidden(true)
                    Text(condition.displayName)
                        .font(Typography.callout)
                    Spacer()
                    Button {
                        conditions.removeAll { $0.id == condition.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(AppColors.error)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove condition: \(condition.displayName)")
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Picker("Condition type", selection: $selectedConditionType) {
                    ForEach(AutomationCondition.allTypeLabels, id: \.self) { label in
                        Text(label).tag(label)
                    }
                }
                .accessibilityLabel("Select condition type")

                if AutomationCondition.requiresValue(selectedConditionType) {
                    TextField("Value", text: $conditionValue)
                        .font(Typography.body)
                        .accessibilityLabel("Condition value")
                }

                Button {
                    addCondition()
                } label: {
                    Label("Add Condition", systemImage: "plus.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(AutomationCondition.requiresValue(selectedConditionType) && conditionValue.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add condition to rule")
            }
        } header: {
            Text("Conditions (any match triggers the rule)")
                .font(Typography.caption1)
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(actions) { action in
                HStack {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundColor(AppColors.success)
                        .accessibilityHidden(true)
                    Text(action.displayName)
                        .font(Typography.callout)
                    Spacer()
                    Button {
                        actions.removeAll { $0.id == action.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(AppColors.error)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove action: \(action.displayName)")
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Picker("Action type", selection: $selectedActionType) {
                    ForEach(AutomationAction.allTypeLabels, id: \.self) { label in
                        Text(label).tag(label)
                    }
                }
                .accessibilityLabel("Select action type")

                if AutomationAction.requiresValue(selectedActionType) {
                    TextField("Value", text: $actionValue)
                        .font(Typography.body)
                        .accessibilityLabel("Action value")
                }

                Button {
                    addAction()
                } label: {
                    Label("Add Action", systemImage: "plus.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(AutomationAction.requiresValue(selectedActionType) && actionValue.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add action to rule")
            }
        } header: {
            Text("Actions")
                .font(Typography.caption1)
        }
    }

    // MARK: - Helpers

    private func addCondition() {
        let value = conditionValue.trimmingCharacters(in: .whitespaces)
        guard let condition = AutomationCondition.from(typeLabel: selectedConditionType, value: value) else { return }
        conditions.append(condition)
        conditionValue = ""
    }

    private func addAction() {
        let value = actionValue.trimmingCharacters(in: .whitespaces)
        guard let action = AutomationAction.from(typeLabel: selectedActionType, value: value) else { return }
        actions.append(action)
        actionValue = ""
    }

    private func saveRule() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !conditions.isEmpty, !actions.isEmpty else { return }

        if let existingRule = rule {
            let updated = AutomationRule(
                id: existingRule.id,
                name: trimmedName,
                isEnabled: isEnabled,
                conditions: conditions,
                actions: actions
            )
            engine.updateRule(updated)
        } else {
            let newRule = AutomationRule(
                name: trimmedName,
                isEnabled: isEnabled,
                conditions: conditions,
                actions: actions
            )
            engine.addRule(newRule)
        }
    }
}

// MARK: - Run Results Sheet

private struct RunResultsSheet: View {
    let results: [UUID: [AutomationAction]]
    let emails: [MBOXParser.RawEmail]
    @Environment(\.dismiss) private var dismiss

    private var emailsByID: [UUID: MBOXParser.RawEmail] {
        Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "No Matches",
                        message: "No emails matched the enabled automation rules."
                    )
                } else {
                    List {
                        Section {
                            Text("\(results.count) email\(results.count == 1 ? "" : "s") matched")
                                .font(Typography.headline)
                                .foregroundColor(AppColors.success)
                                .accessibilityLabel("\(results.count) emails matched automation rules")
                        }

                        ForEach(Array(results.keys), id: \.self) { emailID in
                            if let email = emailsByID[emailID],
                               let actions = results[emailID] {
                                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                                    Text(email.headers["Subject"] ?? "(No Subject)")
                                        .font(Typography.callout)
                                        .lineLimit(1)

                                    Text(email.headers["From"] ?? "Unknown")
                                        .font(Typography.caption1)
                                        .foregroundColor(AppColors.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: Spacing.xxSmall) {
                                        ForEach(actions) { action in
                                            Text(action.displayName)
                                                .font(Typography.caption2)
                                                .padding(.horizontal, Spacing.xSmall)
                                                .padding(.vertical, Spacing.xxxSmall)
                                                .background(AppColors.backgroundTertiary)
                                                .cornerRadius(CornerRadius.small)
                                        }
                                    }
                                }
                                .padding(.vertical, Spacing.xxxSmall)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Rule Results")
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 520, minHeight: 350, idealHeight: 500)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Dismiss results")
                }
            }
        }
    }
}

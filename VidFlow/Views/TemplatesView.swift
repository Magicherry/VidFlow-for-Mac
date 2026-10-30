import SwiftUI
import VidFlowCore

struct TemplatesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var deleting: DownloadTemplate?

    private var selected: DownloadTemplate? { model.templates.find(selection) }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                if !model.templates.custom.isEmpty {
                    Section(L.get("Templates_Mine")) {
                        ForEach(model.templates.custom) { row($0) }
                    }
                }
                Section {
                    ForEach(TemplateStore.builtIns) { row($0) }
                } header: {
                    Text(L.get("Templates_BuiltIn"))
                } footer: {
                    if model.templates.custom.isEmpty {
                        Text(L.get("Templates_EmptyDescription")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let t = model.templates.find(id) { menu(t) }
            }
            .onDeleteCommand { if let t = selected, !t.isBuiltIn { deleting = t } }

            Group {
                if let t = selected {
                    TemplateEditor(template: t)
                } else {
                    ContentUnavailableView(L.get("Template_NoSelection"), systemImage: "slider.horizontal.3",
                                           description: Text(L.get("Settings_TemplatesDescription")))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(L.get("Nav_Templates"))
        .onAppear { if selected == nil { selection = model.templates.defaultTemplate(model.settings).id } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(L.get("Template_New"), systemImage: "plus") {
                    var t = DownloadTemplate(name: model.templates.uniqueName(L.get("Template_NewName")))
                    t.id = UUID()
                    model.templates.save(t)
                    selection = t.id
                }
                .help(L.get("Template_New"))
                Button(L.get("Template_Duplicate"), systemImage: "plus.square.on.square") {
                    if let t = selected { duplicate(t) }
                }
                .disabled(selected == nil)
                .help(L.get("Template_Duplicate"))
                Button(L.get("Template_Delete"), systemImage: "trash") { deleting = selected }
                    .disabled(selected?.isBuiltIn != false)
                    .help(L.get("Template_Delete"))
            }
        }
        .confirmationDialog(deleting.map { L.format("Template_DeleteTitle", $0.displayName) } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L.get("Template_Delete"), role: .destructive) {
                if let t = deleting { delete(t) }
            }
            Button(L.get("Common_Cancel"), role: .cancel) {}
        } message: {
            Text(L.get("Template_DeleteBody"))
        }
    }

    private func row(_ t: DownloadTemplate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.displayName).lineLimit(1)
                Text(DownloadLabels.summary(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if t.id == model.templates.defaultTemplate(model.settings).id {
                Text(L.get("Template_DefaultBadge"))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .tag(t.id)
    }

    @ViewBuilder private func menu(_ t: DownloadTemplate) -> some View {
        Button(L.get("Template_SetDefault")) { model.settings.defaultTemplateId = t.id }
        Button(L.get("Template_Duplicate")) { duplicate(t) }
        if !t.isBuiltIn {
            Divider()
            Button(L.get("Template_Delete"), role: .destructive) { deleting = t }
        }
    }

    private func duplicate(_ t: DownloadTemplate) {
        let copy = model.templates.duplicate(t, name: model.templates.uniqueName(L.format("Template_CopyName", t.displayName)))
        selection = copy.id
    }

    private func delete(_ t: DownloadTemplate) {
        model.templates.delete(t)
        if model.settings.defaultTemplateId == t.id { model.settings.defaultTemplateId = TemplateStore.builtIns[0].id }
        if selection == t.id { selection = nil }
    }
}

/// A user template saves as it is edited; a built-in preset is shown read-only.
private struct TemplateEditor: View {
    let template: DownloadTemplate
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if template.isBuiltIn {
                    LabeledContent(L.get("Template_Name"), value: template.displayName)
                    Text(L.get("Template_BuiltInNote")).font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField(L.get("Template_Name"), text: Binding(get: { template.name }, set: { name in
                        var t = template
                        t.name = name
                        model.templates.save(t)
                    }))
                }
                Toggle(L.get("Template_SetDefault"), isOn: Binding(
                    get: { model.templates.defaultTemplate(model.settings).id == template.id },
                    set: { on in model.settings.defaultTemplateId = on ? template.id : TemplateStore.builtIns[0].id }
                ))
                .disabled(model.templates.defaultTemplate(model.settings).id == template.id)
            }
            Group {
                OptionsSections(options: Binding(get: { template }, set: { model.templates.save($0) }), video: nil, showNaming: true)
            }
            .disabled(template.isBuiltIn)
        }
        .formStyle(.grouped)
        .frame(maxWidth: contentColumnWidth)
        .frame(maxWidth: .infinity)
        .id(template.id)
    }
}

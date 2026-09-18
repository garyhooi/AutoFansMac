//
//  ProfilesView.swift
//  AutoFansMac
//
//  R5/R6: many custom profiles with one-click switching, plus the two immutable
//  built-ins (PROMPT.md §6.4).
//

import SwiftUI
import SMCKit

struct ProfilesView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var renamingProfileID: String?
    @State private var renameText = ""
    @State private var pendingDelete: Profile?
    /// The profile open in the editor.
    @State private var editing: Profile?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            List {
                Section("Built-in") {
                    ForEach(env.profiles.profiles.filter(\.builtIn)) { profile in
                        row(profile)
                    }
                }
                Section("Custom") {
                    let custom = env.profiles.profiles.filter { !$0.builtIn }
                    if custom.isEmpty {
                        Text("No custom profiles yet. Create one, or press Edit on a built-in to keep "
                             + "your own version of it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(custom) { profile in
                            row(profile)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .navigationTitle("Profiles")
        .sheet(item: $pendingDelete) { profile in
            deleteConfirmation(profile)
        }
        .sheet(item: $editing) { profile in
            ProfileEditorView(
                source: profile,
                onSave: { edited in
                    editing = nil
                    save(edited, from: profile)
                },
                onCancel: { editing = nil }
            )
            .environmentObject(env)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                let sensor = env.defaultCurveSensor()
                let profile = env.profiles.createProfile(
                    name: "New profile",
                    defaultSensorKey: sensor?.key,
                    defaultSensorName: sensor?.name
                )
                Task { @MainActor in await env.activateProfile(id: profile.id) }
            } label: {
                Label("New", systemImage: "plus")
            }

            Spacer()

            // Deferred: `applyAtLaunch` lives on ProfileStore, an ObservableObject now
            // re-emitted through the environment, so writing it from a binding setter can
            // publish during the update.
            Toggle("Apply on launch", isOn: Binding(
                get: { env.profiles.applyAtLaunch },
                set: { newValue in deferToNextRunLoop { env.profiles.applyAtLaunch = newValue } }
            ))
            .toggleStyle(.switch)
            .help("Re-apply the active profile automatically when AutoFansMac starts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Saved to \(ProfileStore.profilesURL.path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([ProfileStore.profilesURL])
            }
            .buttonStyle(.link)
            .font(.caption2)
            .help("Show profiles.json in the Finder")
            Spacer()
            if let error = env.profiles.lastError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func row(_ profile: Profile) -> some View {
        let isActive = profile.id == env.profiles.document.activeProfileID
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if renamingProfileID == profile.id {
                        TextField("Name", text: $renameText, onCommit: {
                            env.profiles.rename(id: profile.id, to: renameText)
                            renamingProfileID = nil
                        })
                        .frame(width: 180)
                    } else {
                        Text(profile.name).font(.headline)
                    }
                    if profile.builtIn {
                        Text("built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                    }
                }
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                editing = profile
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .help(profile.builtIn
                  ? "\(profile.name) is built-in and cannot change — editing it saves your settings as a profile of your own"
                  : "Edit this profile's fan settings")

            if !isActive {
                Button("Activate") {
                    Task { @MainActor in await env.activateProfile(id: profile.id) }
                }
                .buttonStyle(.borderedProminent)
            }

            Menu {
                Button("Duplicate") {
                    if let copy = env.profiles.duplicate(id: profile.id) {
                        Task { @MainActor in await env.activateProfile(id: copy.id) }
                    }
                }
                if !profile.builtIn {
                    Button("Rename…") {
                        renameText = profile.name
                        renamingProfileID = profile.id
                    }
                    Divider()
                    Button("Delete", role: .destructive) { pendingDelete = profile }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { @MainActor in await env.activateProfile(id: profile.id) }
        }
    }

    /// Stores an edited profile.
    ///
    /// A built-in is a definition the app restores on every load, so "editing" one cannot mean
    /// writing to it: the result is kept as an editable copy, which becomes active — the
    /// profile the user was actually asking for.
    private func save(_ edited: Profile, from source: Profile) {
        if source.builtIn {
            guard let copy = env.profiles.duplicate(id: source.id) else { return }
            var updated = edited
            updated.id = copy.id
            updated.builtIn = false
            env.profiles.replaceProfile(updated)
            env.log.info("profiles", "kept the edit of “\(source.name)” as “\(updated.name)”")
            Task { @MainActor in await env.activateProfile(id: copy.id) }
            return
        }

        env.profiles.replaceProfile(edited)
        env.log.info("profiles", "saved “\(edited.name)”")
        // Editing the profile that is in force is a change to the fans, not just to the file.
        if env.profiles.document.activeProfileID == edited.id {
            Task { @MainActor in await env.applyActiveProfile(reason: "profile edited") }
        }
    }

    private func deleteConfirmation(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(profile.name)”?").font(.headline)
            Text("This cannot be undone. The profile's settings are removed from profiles.json.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    env.profiles.delete(id: profile.id)
                    pendingDelete = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

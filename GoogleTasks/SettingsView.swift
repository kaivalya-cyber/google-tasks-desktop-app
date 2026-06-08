import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showingSignOutAlert = false
    @State private var clientIDInput = UserDefaults.standard.string(forKey: "oauth_client_id") ?? AppConstants.OAuth.clientID
    @State private var saveConfirmed = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            accountSettings
                .tabItem { Label("Account", systemImage: "person.circle") }
            aboutSettings
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: AppConstants.SettingsWindow.width, height: AppConstants.SettingsWindow.height)
    }

    // MARK: - General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.title2)
                .padding(.top, 8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("OAuth2 Client ID")
                    .font(.headline)

                Text("Configure your Google Cloud Console OAuth 2.0 client ID for the desktop application.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("Client ID", text: $clientIDInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                HStack {
                    Button("Reset to Default") {
                        clientIDInput = "YOUR_CLIENT_ID.apps.googleusercontent.com"
                    }

                    Spacer()

                    if saveConfirmed {
                        Text("Saved!")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }

                    Button("Save") {
                        UserDefaults.standard.set(clientIDInput, forKey: "oauth_client_id")
                        saveConfirmed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            saveConfirmed = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.system(size: 11))
                Text("Get your client ID from the Google Cloud Console → APIs & Services → Credentials")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.05)))

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Account

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account")
                .font(.title2)
                .padding(.top, 8)

            Divider()

            if dataManager.authManager.isAuthenticated {
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in with Google")
                            .font(.system(size: 14, weight: .medium))
                        Text("Connected to Google Tasks")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))

                Button(role: .destructive) {
                    showingSignOutAlert = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert("Sign Out", isPresented: $showingSignOutAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Sign Out", role: .destructive) {
                        dataManager.signOut()
                    }
                } message: {
                    Text("Are you sure you want to sign out? Your tasks will no longer be available offline.")
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Not signed in")
                        .font(.system(size: 13, weight: .medium))
                    Text("Sign in to access your Google Tasks")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        Task { await dataManager.signIn() }
                    } label: {
                        Label("Sign in with Google", systemImage: "person.circle.fill")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Spacer()
        }
        .padding(16)
    }

    // MARK: - About

    private var aboutSettings: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 56))
                .foregroundColor(.blue)
            Text("Google Tasks for Mac")
                .font(.title2).fontWeight(.bold)
            Text("Version 1.0.0")
                .font(.system(size: 12)).foregroundColor(.secondary)
            Text("A native macOS menu bar app for managing Google Tasks.\nBuilt with Swift and SwiftUI.")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://tasks.google.com/")!) {
                    Label("Google Tasks", systemImage: "link").font(.system(size: 11))
                }
                Link(destination: URL(string: "https://console.cloud.google.com/")!) {
                    Label("Cloud Console", systemImage: "gearshape.2").font(.system(size: 11))
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

#Preview {
    SettingsView().environmentObject(DataManager.shared)
}

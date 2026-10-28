import AppKit
import Foundation
import SwiftUI

/// "Send feedback": the only thing the app ever sends over the network on its own (apart from model downloads), and
/// only when you press Send. It carries exactly what you typed, an optional email, and the app and macOS versions.
/// No dictations, no history, no device identifiers: each message gets a fresh random id.
enum Feedback {
    /// The MurmurBee PostHog project. Project keys are write-only and public by design.
    static let projectKey = "phc_AxA9apJcmvy3nG3sdzsoQ8ictiL6Q7h38A9pgh2gQRjX"
    static let endpoint = URL(string: "https://eu.i.posthog.com/i/v0/e/")!

    static func send(message: String, email: String) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var properties: [String: Any] = [
            "message": message,
            "app_version": version,
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "$process_person_profile": false,
        ]
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEmail.isEmpty { properties["reply_email"] = trimmedEmail }
        let body: [String: Any] = [
            "api_key": projectKey, "event": "app_feedback",
            "distinct_id": UUID().uuidString, "properties": properties,
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

struct FeedbackSheet: View {
    let close: (_ sent: Bool) -> Void
    @State private var message = ""
    @State private var email = ""
    @State private var sending = false
    @State private var failed = false

    private var canSend: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if let bee = Brand.bee { Image(nsImage: bee).resizable().interpolation(.high).frame(width: 28, height: 28) }
                Text("Send feedback").font(Brand.sora(20)).foregroundStyle(Brand.linen)
            }
            Text("Tell me what's working, what isn't, or what you'd love to see. I read every message.")
                .font(.system(size: 13)).foregroundStyle(Brand.sand)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Your feedback").font(.system(size: 14)).foregroundStyle(Brand.sand.opacity(0.7))
                        .padding(.horizontal, 13).padding(.vertical, 10)
                }
                TextEditor(text: $message)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.border))

            TextField("Email, if you'd like a reply (optional)", text: $email)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.border))

            Text(failed
                 ? "Couldn't send it. Check your internet connection and try again."
                 : "This sends only what you type here, plus the app and macOS version. Nothing else leaves your Mac.")
                .font(.system(size: 12)).foregroundStyle(failed ? Brand.honey : Brand.sand)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { close(false) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.sand)
                    .padding(.horizontal, 12)
                    .keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send") { send() }
                    .buttonStyle(HoneyButton())
                    .opacity(canSend ? 1 : 0.5)
                    .disabled(!canSend)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Brand.night)
        .brandWindow()
    }

    private func send() {
        sending = true; failed = false
        Task {
            do {
                try await Feedback.send(message: message, email: email)
                close(true)
            } catch {
                failed = true
                sending = false
            }
        }
    }
}

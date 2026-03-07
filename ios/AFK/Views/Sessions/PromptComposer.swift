import SwiftUI
import PhotosUI

struct PromptComposer: View {
    let sessionId: String
    let commandStore: CommandStore
    let apiClient: APIClient
    var sessionStore: SessionStore?
    var isDisabled: Bool = false
    @AppStorage("biometricGateEnabled", store: BuildEnvironment.userDefaults) private var biometricGateEnabled = false
    @State private var prompt = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showTemplates = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var attachedImages: [AttachedImage] = []

    private var canSend: Bool {
        let hasText = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !attachedImages.isEmpty
        return (hasText || hasImages) && !isSending && !isDisabled
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }

                if !attachedImages.isEmpty {
                    attachedImagesStrip
                }

                if prompt.isEmpty && attachedImages.isEmpty && !isDisabled {
                    quickActionButtons
                }

                inputField
            }
        }
        .onChange(of: selectedPhotos) { _, newItems in
            Task { await loadPhotos(from: newItems) }
        }
        .sheet(isPresented: $showTemplates) {
            NavigationStack {
                List {
                    Section("Quick Actions") {
                        ForEach(CommandTemplate.builtIn) { template in
                            Button {
                                prompt = template.prompt
                                showTemplates = false
                                Task { await send() }
                            } label: {
                                Label(template.name, systemImage: template.icon)
                            }
                        }
                    }
                }
                .navigationTitle("Templates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showTemplates = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Menu {
                Button {
                    showTemplates = true
                } label: {
                    Label("Templates", systemImage: "text.badge.star")
                }

                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 3, matching: .images) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .glassEffect(.regular.interactive(), in: .circle)

            TextField("Send a message...", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .gray)
                    .frame(width: 36, height: 36)
            }
            .disabled(!canSend)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var attachedImagesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { img in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            attachedImages.removeAll { $0.id == img.id }
                            selectedPhotos.removeAll { $0.itemIdentifier == img.itemIdentifier }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.6)))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var quickActionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(CommandTemplate.builtIn.prefix(4))) { template in
                    QuickActionPill(title: template.name, icon: template.icon) {
                        prompt = template.prompt
                        Task { await send() }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func loadPhotos(from items: [PhotosPickerItem]) async {
        var loaded: [AttachedImage] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { continue }
            let compressed = compressImage(uiImage)
            loaded.append(AttachedImage(
                itemIdentifier: item.itemIdentifier,
                thumbnail: uiImage,
                base64Data: compressed.base64,
                mediaType: compressed.mediaType
            ))
        }
        attachedImages = loaded
    }

    private func compressImage(_ image: UIImage) -> (base64: String, mediaType: String) {
        // Downscale if needed (max 1024px on longest side)
        let maxDim: CGFloat = 1024
        let scaledImage: UIImage
        if max(image.size.width, image.size.height) > maxDim {
            let scale = maxDim / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaledImage = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            scaledImage = image
        }
        let data = scaledImage.jpegData(compressionQuality: 0.7) ?? Data()
        return (data.base64EncodedString(), "image/jpeg")
    }

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }

        if biometricGateEnabled {
            let biometric = BiometricService()
            do {
                try await biometric.authenticate(reason: "Authenticate to send command")
            } catch {
                errorMessage = "Authentication required"
                return
            }
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let promptText = text.isEmpty ? "Look at the attached image(s)." : text
        let useE2EE = sessionStore?.hasE2EEKey(for: sessionId) == true

        // Encrypt prompt if E2EE is available
        let promptEncrypted: String? = useE2EE ? sessionStore?.encryptPrompt(promptText, sessionId: sessionId) : nil

        // Build image attachments (encrypted or plaintext)
        var images: [ImageAttachment]?
        var imagesEncrypted: [ImageAttachment]?

        if !attachedImages.isEmpty {
            if useE2EE {
                imagesEncrypted = attachedImages.compactMap { img in
                    guard let encData = sessionStore?.encryptImageData(img.base64Data, sessionId: sessionId) else { return nil }
                    return ImageAttachment(mediaType: img.mediaType, data: encData)
                }
            } else {
                images = attachedImages.map {
                    ImageAttachment(mediaType: $0.mediaType, data: $0.base64Data)
                }
            }
        }

        do {
            let response = try await apiClient.continueSession(
                sessionId: sessionId,
                prompt: promptText,
                promptEncrypted: promptEncrypted,
                images: images,
                imagesEncrypted: imagesEncrypted
            )
            commandStore.startCommand(id: response.commandId, sessionId: sessionId, prompt: promptText)
            prompt = ""
            attachedImages = []
            selectedPhotos = []
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
        }
    }
}

// MARK: - Attached Image Model

struct AttachedImage: Identifiable {
    let id = UUID()
    let itemIdentifier: String?
    let thumbnail: UIImage
    let base64Data: String
    let mediaType: String
}

struct ImageAttachment: Codable {
    let mediaType: String
    let data: String
}

// MARK: - Quick Action Pill

struct QuickActionPill: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

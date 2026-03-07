import SwiftUI

struct ToolResultImageView: View {
    let image: ToolResultImage
    @State private var showFullScreen = false

    private var uiImage: UIImage? {
        guard let data = Data(base64Encoded: image.data) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        if let uiImage {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { showFullScreen = true }
                .fullScreenCover(isPresented: $showFullScreen) {
                    FullScreenImageView(uiImage: uiImage)
                }
        }
    }
}

struct FullScreenImageView: View {
    let uiImage: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width * scale)
                        .frame(minHeight: geo.size.height)
                }
            }
            .ignoresSafeArea()
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = max(1.0, min(value.magnification, 5.0))
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation { scale = scale > 1.0 ? 1.0 : 3.0 }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Image(uiImage: uiImage), preview: SharePreview("Image", image: Image(uiImage: uiImage)))
                }
            }
        }
    }
}

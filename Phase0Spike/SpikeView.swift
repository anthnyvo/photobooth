import SwiftUI

struct SpikeView: View {
    @StateObject private var model = SpikeViewModel()

    var body: some View {
        HStack(spacing: 0) {
            // Left: live view + capture
            VStack(spacing: 12) {
                statusBanner

                ZStack {
                    Rectangle().fill(.black)
                    if let frame = model.liveViewImage {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text("no live view")
                            .foregroundStyle(.gray)
                    }
                    VStack {
                        HStack {
                            Spacer()
                            Text(String(format: "%.1f fps", model.fps))
                                .font(.system(.title3, design: .monospaced).bold())
                                .padding(8)
                                .background(.black.opacity(0.6))
                                .foregroundStyle(model.fps >= 15 ? .green : .orange)
                        }
                        Spacer()
                    }
                    .padding(8)
                }
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button(action: model.capture) {
                    Label(model.isCapturing ? "Capturing…" : "Trigger Capture",
                          systemImage: "camera.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCapturing)

                if let capture = model.lastCapture {
                    HStack(alignment: .top, spacing: 12) {
                        Image(uiImage: capture)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if let rtt = model.captureRoundTripSeconds {
                            VStack(alignment: .leading) {
                                Text("Capture round trip")
                                    .font(.headline)
                                Text(String(format: "%.2f s", rtt))
                                    .font(.system(.largeTitle, design: .monospaced).bold())
                                    .foregroundStyle(rtt <= 5 ? .green : .orange)
                                Text("budget: ≤ 5 s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)

            Divider()

            // Right: diagnostic log
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Diagnostics").font(.headline)
                    Spacer()
                    ShareLink(item: model.exportLog()) {
                        Label("Export log", systemImage: "square.and.arrow.up")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.contains("!!") ? .red : .primary)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: model.logLines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .padding()
            .frame(width: 380)
            .background(Color(.secondarySystemBackground))
        }
        .onAppear { model.start() }
    }

    private var statusBanner: some View {
        Text(model.step.rawValue)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(bannerColor.opacity(0.2))
            .foregroundStyle(bannerColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bannerColor: Color {
        switch model.step {
        case .liveView: return .green
        case .disconnected: return .red
        case .ready, .remoteMode: return .blue
        default: return .orange
        }
    }
}

#Preview {
    SpikeView()
}

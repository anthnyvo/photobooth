import SwiftUI

/// Idle/attract screen — loops live view as a backdrop with a shutter-ring
/// "tap to start" control. Branding-driven: logo and accent color come from
/// EventConfig; the dark chassis styling is fixed (see Theme.swift).
struct AttractView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    /// Pick-then-confirm: tapping a mode highlights it; only the Start pill
    /// actually begins the session. Defaults to Single Photo.
    @State private var selectedMode: Mode = .single
    @State private var selectedCategory: Category = .photo

    /// Whether the event offers any choice beyond a plain single photo —
    /// drives the pick-then-confirm UI vs. the direct shutter button.
    private var hasModeChoices: Bool {
        model.config.strip.enabled || model.config.animationsEnabled
    }

    var body: some View {
        ZStack {
            ChassisBackground()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Chassis.base.opacity(0.55).ignoresSafeArea())
                // AR-style prop preview — same pixel aspect as the frame,
                // so the identical scaledToFill transform keeps the two
                // layers aligned. Drawn above the dim so props read clearly.
                if let propOverlay = model.livePropOverlay {
                    Image(uiImage: propOverlay)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }

            VStack(spacing: 24) {
                Spacer()
                if let logoName = model.config.logoAssetName {
                    let url = EventStorage.shared.assetURL(eventId: model.config.eventId, filename: logoName)
                    if let uiImage = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 140)
                    }
                }

                if hasModeChoices {
                    // Two-level picker: category tabs (Photo / Strips /
                    // Animated) so the row never turns into one long
                    // cluttered scroll, and each option inside a category
                    // renders as a miniature of the actual output — a
                    // 3-shot strip option IS a tiny 3-frame strip — so
                    // guests can see what they're getting, not decode an
                    // icon. Start pill below still confirms.
                    VStack(spacing: 18) {
                        HStack(spacing: 10) {
                            ForEach(categories, id: \.self) { category in
                                Button {
                                    selectCategory(category)
                                } label: {
                                    Text(category.rawValue)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(selectedCategory == category ? Color.black : Chassis.textPrimary)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 20)
                                        .background(
                                            Capsule().fill(selectedCategory == category
                                                ? AnyShapeStyle(Color.white)
                                                : AnyShapeStyle(.ultraThinMaterial))
                                        )
                                        .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 18) {
                                ForEach(modes(in: selectedCategory), id: \.self) { mode in
                                    ModePreviewCard(
                                        title: title(for: mode),
                                        isSelected: selectedMode == mode,
                                        action: { selectedMode = mode }
                                    ) {
                                        art(for: mode)
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                        }
                    }
                } else {
                    // Shutter-ring start control: outer hairline ring, accent
                    // inner disc — reads as a camera control, not a web button.
                    Button {
                        model.tapToStart()
                    } label: {
                        VStack(spacing: 18) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                Circle()
                                    .strokeBorder(Chassis.hairline, lineWidth: 1)
                                Circle()
                                    .strokeBorder(.white.opacity(0.8), lineWidth: 3)
                                    .padding(10)
                                Circle()
                                    .fill(Chassis.textPrimary)
                                    .padding(18)
                            }
                            .frame(width: 108, height: 108)
                            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)

                            ChassisLabel(text: "Tap to Start")
                        }
                    }
                    .buttonStyle(.plain)
                }

                if model.config.filtersEnabled {
                    // Filter chips — guest picks a look before starting;
                    // applied to the saved file (before overlay/frame) in
                    // finishCapture, or per frame for Boomerang/GIF.
                    // Resets to Original per guest.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(PhotoFilter.allCases) { filter in
                                Button {
                                    model.selectedFilter = filter
                                } label: {
                                    Text(filter.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(model.selectedFilter == filter ? Color.black : Chassis.textPrimary)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 18)
                                        .background(
                                            Capsule().fill(model.selectedFilter == filter
                                                ? AnyShapeStyle(Color.white)
                                                : AnyShapeStyle(.ultraThinMaterial))
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(Chassis.hairline, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.top, 4)
                }

                if model.config.ai.props {
                    // Face-prop chips — same pick-then-shoot pattern as
                    // filters; anchored to detected faces and burned into
                    // the file (stills and GIFs alike). Resets per guest.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(PhotoProp.allCases) { prop in
                                Button {
                                    model.selectedProp = prop
                                } label: {
                                    Text(prop.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(model.selectedProp == prop ? Color.black : Chassis.textPrimary)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 18)
                                        .background(
                                            Capsule().fill(model.selectedProp == prop
                                                ? AnyShapeStyle(Color.white)
                                                : AnyShapeStyle(.ultraThinMaterial))
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(Chassis.hairline, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.top, 4)
                }

                if hasModeChoices {
                    // The confirm step — mode/filter taps above only mark a
                    // choice, this actually starts the session.
                    PillButton(title: "Start") {
                        switch selectedMode {
                        case .single:
                            model.tapToStart()
                        case .strip(let option):
                            model.tapToStart(stripShotCount: option.count, layout: option.layout)
                        case .animated(let style):
                            model.tapToStartAnimated(style)
                        }
                        selectedMode = .single
                    }
                    .padding(.top, 8)
                }
                Spacer()
            }

            if let error = model.lastError {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Chassis.textPrimary)
                        .padding(10)
                        .background(.red.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap-anywhere is a shortcut for the single shutter button; once
            // any mode choice is offered, starting requires the explicit
            // pick-then-Start flow instead, so this no-ops there.
            guard !hasModeChoices else { return }
            model.tapToStart()
        }
        .task { await model.runLivePropOverlayLoop() }
    }

    /// Every offered (shot count, layout) combination — e.g. 3-shot and
    /// 4-shot each offered in every enabled layout, not one fixed pairing.
    private var stripOptions: [StripOption] {
        let counts = model.config.strip.shotCounts.sorted()
        let layouts = model.config.strip.layouts.sorted()
        return layouts.flatMap { layout in
            counts.map { count in
                StripOption(count: count, layout: layout)
            }
        }
    }

    // MARK: - Categories

    /// Top-level grouping for the two-level mode picker — only categories
    /// the event actually offers appear.
    private var categories: [Category] {
        var result: [Category] = [.photo]
        if model.config.strip.enabled { result.append(.strips) }
        if model.config.animationsEnabled { result.append(.animated) }
        return result
    }

    private func modes(in category: Category) -> [Mode] {
        switch category {
        case .photo: [.single]
        case .strips: stripOptions.map(Mode.strip)
        case .animated: AnimatedStyle.allCases.map(Mode.animated)
        }
    }

    /// Switching category auto-selects its first option so the Start pill
    /// always fires something visible on screen.
    private func selectCategory(_ category: Category) {
        selectedCategory = category
        if let first = modes(in: category).first {
            selectedMode = first
        }
    }

    private func title(for mode: Mode) -> String {
        switch mode {
        case .single: "Single Photo"
        case .strip(let option): option.label
        case .animated(let style): style.displayName
        }
    }

    private func art(for mode: Mode) -> AnyView {
        switch mode {
        case .single:
            AnyView(SinglePolaroidPreview())
        case .strip(let option):
            AnyView(StripPreview(count: option.count, layout: option.layout))
        case .animated(let style):
            AnyView(AnimatedPreview(style: style))
        }
    }

    private enum Category: String, Hashable {
        case photo = "Photo"
        case strips = "Photo Strips"
        case animated = "Animated"
    }

    private enum Mode: Hashable {
        case single
        case strip(StripOption)
        case animated(AnimatedStyle)
    }

    private struct StripOption: Identifiable, Hashable {
        let count: Int
        let layout: EventConfig.StripOptions.Layout

        var id: String { "\(count)-\(layout.rawValue)" }
        var label: String { "\(count)-Shot \(layout.displayName)" }
    }
}

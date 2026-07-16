import SwiftUI

/// Idle/attract screen — loops live view as a backdrop with the guest's
/// choices organized into category tabs (Photo / Strips / Animated /
/// Filters / Props — only what the event enables). One category's options
/// are visible at a time, each drawn as a miniature of what the guest
/// actually gets; the Start pill confirms. Future guest-facing choices
/// should join this system as new categories, not new stacked rows.
struct AttractView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    /// Pick-then-confirm: tapping a mode highlights it; only the Start pill
    /// actually begins the session. Defaults to Single Photo.
    @State private var selectedMode: Mode = .single
    @State private var selectedCategory: Category = .photo
    @State private var entered = false

    /// Whether anything is choosable at all — with every category off, the
    /// screen keeps the plain shutter-ring/tap-anywhere flow instead.
    private var hasPicker: Bool {
        categories.count > 1
    }

    var body: some View {
        ZStack {
            ChassisBackground()

            LiveViewBackdrop(feed: model.liveFeed, filter: model.selectedFilter, dim: 0.55)

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

                if hasPicker {
                    VStack(spacing: 22) {
                        // Category tabs — switching shows only that
                        // category's options, nothing else stacks up.
                        // ViewThatFits centers the row when it fits the
                        // screen (the common iPad case) and only falls back
                        // to a left-starting scroll when an event enables
                        // enough categories to overflow.
                        ViewThatFits(in: .horizontal) {
                            categoryTabs
                            ScrollView(.horizontal, showsIndicators: false) { categoryTabs }
                        }
                        .entrance(entered, delay: 0.05)

                        // Options slide in from the trailing edge when the
                        // category changes — reads as flipping to the next
                        // page rather than content teleporting. Same
                        // fits-then-scrolls centering as the tabs above.
                        ViewThatFits(in: .horizontal) {
                            optionsRow
                            ScrollView(.horizontal, showsIndicators: false) { optionsRow }
                        }
                        .animation(.spring(duration: 0.45, bounce: 0.12), value: selectedCategory)
                        .entrance(entered, delay: 0.1)
                    }

                    // The confirm step — every pick above only marks a
                    // choice, this actually starts the session with the
                    // selected mode (plus whatever filter/prop is set).
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
                    .scaleEffect(1.15)
                    .padding(.top, 14)
                    .entrance(entered, delay: 0.16)
                } else {
                    // Shutter-ring start control: outer hairline ring, accent
                    // inner disc — reads as a camera control, not a web button.
                    Button {
                        model.tapToStart()
                    } label: {
                        VStack(spacing: 22) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                Circle()
                                    .strokeBorder(Chassis.hairline, lineWidth: 1)
                                Circle()
                                    .strokeBorder(.white.opacity(0.8), lineWidth: 4)
                                    .padding(13)
                                Circle()
                                    .fill(Chassis.textPrimary)
                                    .padding(24)
                            }
                            .frame(width: 148, height: 148)
                            .shadow(color: .black.opacity(0.5), radius: 16, y: 7)

                            ChassisLabel(text: "Tap to Start", size: 13)
                        }
                    }
                    .buttonStyle(.plain)
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
            // any picker category is offered, starting requires the explicit
            // pick-then-Start flow instead, so this no-ops there.
            guard !hasPicker else { return }
            model.tapToStart()
        }
        .onAppear { entered = true }
        .task { await model.runLivePropOverlayLoop() }
        // Light haptic tick on every pick — selection should feel physical.
        .sensoryFeedback(.selection, trigger: selectedMode)
        .sensoryFeedback(.selection, trigger: selectedCategory)
        .sensoryFeedback(.selection, trigger: model.selectedFilter)
        .sensoryFeedback(.selection, trigger: model.selectedProp)
    }

    // MARK: - Category tabs / options rows

    /// Extracted so ViewThatFits above can measure/build the identical
    /// content both bare (centers when it fits) and inside a ScrollView
    /// (left-starting fallback when it doesn't) without duplicating markup.
    @ViewBuilder
    private var categoryTabs: some View {
        HStack(spacing: 14) {
            ForEach(categories, id: \.self) { category in
                Button {
                    selectCategory(category)
                } label: {
                    Text(category.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selectedCategory == category ? Color.black : Chassis.textPrimary)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 26)
                        .background(
                            Capsule().fill(selectedCategory == category
                                ? AnyShapeStyle(Color.white)
                                : AnyShapeStyle(.ultraThinMaterial))
                        )
                        .overlay(Capsule().strokeBorder(Chassis.hairline, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var optionsRow: some View {
        HStack(spacing: 22) {
            categoryContent
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .id(selectedCategory)
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        )
    }

    // MARK: - Category content

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .photo, .strips, .animated:
            ForEach(modes(in: selectedCategory), id: \.self) { mode in
                ModePreviewCard(
                    title: title(for: mode),
                    isSelected: selectedMode == mode,
                    action: { selectedMode = mode }
                ) {
                    art(for: mode)
                }
            }
        case .filters:
            ForEach(PhotoFilter.offered(glamEnabled: model.config.glam.enabled)) { filter in
                ModePreviewCard(
                    title: filter.displayName,
                    isSelected: model.selectedFilter == filter,
                    action: { model.selectedFilter = filter }
                ) {
                    AnyView(FilterPreview(filter: filter))
                }
            }
        case .props:
            ForEach(PhotoProp.allCases) { prop in
                ModePreviewCard(
                    title: prop.displayName,
                    isSelected: model.selectedProp == prop,
                    action: { model.selectedProp = prop }
                ) {
                    AnyView(PropPreview(prop: prop))
                }
            }
        case .stickers:
            // "None" chip first, then one per event sticker asset.
            ModePreviewCard(
                title: "None",
                isSelected: model.selectedSticker == nil,
                action: { model.selectedSticker = nil }
            ) {
                AnyView(Color.black.opacity(0.2))
            }
            ForEach(model.config.stickers.assetNames, id: \.self) { name in
                ModePreviewCard(
                    title: stickerLabel(name),
                    isSelected: model.selectedSticker == name,
                    action: { model.selectedSticker = name }
                ) {
                    AnyView(StickerPreview(eventId: model.config.eventId, assetName: name))
                }
            }
        }
    }

    /// Human-ish label from a sticker filename ("hearts.png" -> "Hearts").
    private func stickerLabel(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return base.replacingOccurrences(of: "_", with: " ").capitalized
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

    /// Only categories the event actually enables appear.
    private var categories: [Category] {
        var result: [Category] = [.photo]
        if model.config.strip.enabled { result.append(.strips) }
        if model.config.animationsEnabled { result.append(.animated) }
        if model.config.filtersEnabled { result.append(.filters) }
        if model.config.ai.props { result.append(.props) }
        if model.config.stickers.enabled && !model.config.stickers.assetNames.isEmpty {
            result.append(.stickers)
        }
        return result
    }

    private func modes(in category: Category) -> [Mode] {
        switch category {
        case .photo: [.single]
        case .strips: stripOptions.map(Mode.strip)
        case .animated: AnimatedStyle.allCases.map(Mode.animated)
        case .filters, .props, .stickers: []
        }
    }

    /// Switching to a mode category auto-selects its first option so the
    /// Start pill always fires something visible; filter/prop categories
    /// leave the chosen mode alone — they're additive picks.
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
        case filters = "Filters"
        case props = "Props"
        case stickers = "Stickers"
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

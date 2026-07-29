import SwiftUI
import BoothStorage

/// Idle/attract screen — loops live view as a backdrop with the guest's
/// choices split into two clearly separate zones:
///
///   FORMAT  — what the guest gets: Single Photo / a strip option / an
///             animated style (Boomerang, GIF). Exactly one, always chosen,
///             shown right on the Start button.
///   STYLE   — how it looks: Filters / Props / Stickers. Additive, optional.
///
/// The split exists because the two are different kinds of choice, and a
/// previous single-tab design let them bleed together: merely tapping into
/// the Animated tab committed the GIF format, and then styling never reset
/// it, so a guest who picked a filter could hit Start and get a GIF they
/// never asked for. Format and style are now independent — a style pick can
/// never change the format, and the Start button always names the format it
/// will actually run.
struct AttractView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    /// Pick-then-confirm: tapping a format marks it; only Start begins the
    /// session. Defaults to Single Photo, the safe default.
    @State private var selectedMode: Mode = .single
    /// Which STYLE category's options are showing. Set on appear to the first
    /// enabled one; nil only until then / when no style category is enabled.
    @State private var selectedStyle: StyleCategory?
    @State private var entered = false

    /// Every capture format the event offers. Single is always available;
    /// strips and animated join only when enabled. More than one means the
    /// FORMAT row is worth showing; exactly one (plain single photo) means
    /// there's nothing to pick and the Start button just says so.
    private var formatModes: [Mode] {
        var modes: [Mode] = [.single]
        if model.config.strip.enabled { modes += stripOptions.map(Mode.strip) }
        if model.config.animationsEnabled { modes += AnimatedStyle.allCases.map(Mode.animated) }
        return modes
    }

    /// Only the STYLE categories the event actually enables.
    private var styleCategories: [StyleCategory] {
        var result: [StyleCategory] = []
        if model.config.filtersEnabled { result.append(.filters) }
        if model.config.ai.props { result.append(.props) }
        if model.config.stickers.enabled && !model.config.stickers.assetNames.isEmpty {
            result.append(.stickers)
        }
        return result
    }

    /// Whether anything is choosable at all. With a single format and no
    /// styles, the screen keeps the plain shutter-ring/tap-anywhere flow.
    private var hasPicker: Bool {
        formatModes.count > 1 || !styleCategories.isEmpty
    }

    /// The style category to render options for right now — the explicit
    /// pick, falling back to the first enabled one before onAppear runs.
    private var activeStyle: StyleCategory? {
        selectedStyle ?? styleCategories.first
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
                    VStack(spacing: 20) {
                        // FORMAT zone — exclusive, only shown when there's
                        // more than one to choose. With just Single Photo the
                        // Start button already names it, so a one-item row
                        // would be noise.
                        if formatModes.count > 1 {
                            VStack(spacing: 10) {
                                ChassisLabel(text: "Format", size: 11)
                                ViewThatFits(in: .horizontal) {
                                    formatRow
                                    ScrollView(.horizontal, showsIndicators: false) { formatRow }
                                }
                            }
                            .entrance(entered, delay: 0.05)
                        }

                        // STYLE zone — additive; never touches the format.
                        if let activeStyle {
                            VStack(spacing: 10) {
                                ChassisLabel(text: "Style", size: 11)
                                if styleCategories.count > 1 {
                                    ViewThatFits(in: .horizontal) {
                                        styleTabs
                                        ScrollView(.horizontal, showsIndicators: false) { styleTabs }
                                    }
                                }
                                ViewThatFits(in: .horizontal) {
                                    styleRow(activeStyle)
                                    ScrollView(.horizontal, showsIndicators: false) { styleRow(activeStyle) }
                                }
                                .animation(.spring(duration: 0.45, bounce: 0.12), value: activeStyle)
                            }
                            .entrance(entered, delay: 0.1)
                        }
                    }

                    // Confirm step — always names the format it will run, so
                    // the guest sees exactly what they'll get before it fires.
                    PillButton(title: "Start · \(title(for: selectedMode))") {
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
            // any picker is offered, starting requires the explicit
            // pick-then-Start flow instead, so this no-ops there.
            guard !hasPicker else { return }
            model.tapToStart()
        }
        .onAppear {
            entered = true
            if selectedStyle == nil { selectedStyle = styleCategories.first }
        }
        .task { await model.runLivePropOverlayLoop() }
        // Light haptic tick on every pick — selection should feel physical.
        .sensoryFeedback(.selection, trigger: selectedMode)
        .sensoryFeedback(.selection, trigger: selectedStyle)
        .sensoryFeedback(.selection, trigger: model.selectedFilter)
        .sensoryFeedback(.selection, trigger: model.selectedProp)
        .sensoryFeedback(.selection, trigger: model.selectedSticker)
    }

    // MARK: - FORMAT row

    /// Extracted so ViewThatFits can measure/build the identical content both
    /// bare (centers when it fits) and inside a ScrollView (left-starting
    /// fallback when it doesn't) without duplicating markup.
    @ViewBuilder
    private var formatRow: some View {
        HStack(spacing: 22) {
            ForEach(formatModes, id: \.self) { mode in
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
    }

    // MARK: - STYLE tabs / rows

    @ViewBuilder
    private var styleTabs: some View {
        HStack(spacing: 14) {
            ForEach(styleCategories, id: \.self) { category in
                Button {
                    selectedStyle = category
                } label: {
                    Text(category.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(activeStyle == category ? Color.black : Chassis.textPrimary)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 26)
                        .background(
                            Capsule().fill(activeStyle == category
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
    private func styleRow(_ category: StyleCategory) -> some View {
        HStack(spacing: 22) {
            styleContent(category)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .id(category)
        .transition(
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        )
    }

    @ViewBuilder
    private func styleContent(_ category: StyleCategory) -> some View {
        switch category {
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

    /// STYLE categories only — the additive modifiers. Format lives in its
    /// own `Mode` type so the two can never be confused for one another.
    private enum StyleCategory: String, Hashable {
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

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

    /// Whether anything is choosable at all — with every category off, the
    /// screen keeps the plain shutter-ring/tap-anywhere flow instead.
    private var hasPicker: Bool {
        categories.count > 1
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

                if hasPicker {
                    VStack(spacing: 18) {
                        // Category tabs — switching shows only that
                        // category's options, nothing else stacks up.
                        ScrollView(.horizontal, showsIndicators: false) {
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
                            .padding(.horizontal, 24)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 18) {
                                categoryContent
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                        }
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
                    .padding(.top, 8)
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
        .task { await model.runLivePropOverlayLoop() }
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
            ForEach(PhotoFilter.allCases) { filter in
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
        }
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
        return result
    }

    private func modes(in category: Category) -> [Mode] {
        switch category {
        case .photo: [.single]
        case .strips: stripOptions.map(Mode.strip)
        case .animated: AnimatedStyle.allCases.map(Mode.animated)
        case .filters, .props: []
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

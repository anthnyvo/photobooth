import SwiftUI

/// Idle/attract screen — loops live view as a backdrop with a shutter-ring
/// "tap to start" control. Branding-driven: logo and accent color come from
/// EventConfig; the dark chassis styling is fixed (see Theme.swift).
struct AttractView: View {
    @ObservedObject var model: BoothViewModel
    let theme: Theme
    /// Pick-then-confirm: tapping a mode highlights it; only the Start pill
    /// actually begins the session. nil count = Single Photo (the default).
    @State private var selectedOption: StripOption?

    var body: some View {
        ZStack {
            ChassisBackground()

            if let frame = model.liveViewImage {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .overlay(Chassis.base.opacity(0.55).ignoresSafeArea())
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

                if model.config.strip.enabled {
                    // Strip mode is available for this event but shouldn't
                    // force every guest into one fixed count/layout — every
                    // combination the event offers (e.g. 3-shot and 4-shot,
                    // vertical/horizontal/grid) gets its own button, plus
                    // Single. Tapping highlights the pick; the Start pill
                    // below confirms it, so guests can browse without the
                    // countdown flow firing on the first touch.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 32) {
                            DialButton(label: "Single Photo", systemImage: "camera", isSelected: selectedOption == nil, diameter: 92) {
                                selectedOption = nil
                            }
                            ForEach(stripOptions) { option in
                                DialButton(label: option.label, systemImage: "photo.stack.fill", isSelected: selectedOption == option, diameter: 92) {
                                    selectedOption = option
                                }
                            }
                        }
                        .padding(.horizontal, 24)
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
                    // finishCapture. Resets to Original per guest.
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

                if model.config.strip.enabled {
                    // The confirm step — mode/filter taps above only mark a
                    // choice, this actually starts the session.
                    PillButton(title: "Start") {
                        if let option = selectedOption {
                            model.tapToStart(stripShotCount: option.count, layout: option.layout)
                        } else {
                            model.tapToStart()
                        }
                        selectedOption = nil
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
            // strip mode is offered, starting requires an explicit Single/
            // Strip choice instead, so this no-ops there.
            guard !model.config.strip.enabled else { return }
            model.tapToStart()
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

    private struct StripOption: Identifiable, Equatable {
        let count: Int
        let layout: EventConfig.StripOptions.Layout

        var id: String { "\(count)-\(layout.rawValue)" }
        var label: String { "\(count)-Shot \(layout.displayName)" }
    }
}

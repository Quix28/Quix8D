import SwiftUI

struct SpatialMapView: View {
    @ObservedObject var controller: MenuBarController
    @State private var selectedID: String?
    @State private var draggingID: String?

    static let mapSize: CGFloat = 220
    private static let headRadius: CGFloat = 16
    // Keeps tokens off the head.
    private static let innerRadius: CGFloat = 30
    private static let tokenSize: CGFloat = 28
    private static var mapRadius: CGFloat { mapSize / 2 - tokenSize / 2 - 2 }
    private static let ringDistances = [1.0, 2.5, 5.0]
    private static let trayRowHeight: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            map
                .frame(width: Self.mapSize, height: Self.mapSize)
            sidePanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var map: some View {
        let center = CGPoint(x: Self.mapSize / 2, y: Self.mapSize / 2)
        return ZStack {
            Canvas { context, _ in
                drawBackground(in: &context, center: center)
            }
            head.position(center)
            ForEach(controller.placedApps) { app in
                if let position = controller.position(for: app) {
                    token(for: app, at: position, center: center)
                }
            }
        }
        .coordinateSpace(name: "spatialMap")
        .background(Circle().fill(Color.black.opacity(0.3)))
    }

    private func drawBackground(in context: inout GraphicsContext, center: CGPoint) {
        let line = Color.white.opacity(0.12)
        for distance in Self.ringDistances {
            let r = Self.innerRadius + (Self.mapRadius - Self.innerRadius) * CGFloat(SpatialMap.radiusFraction(ofDistance: distance))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), with: .color(line))
            context.draw(Text(distance == 5 ? "5 m" : String(format: "%g m", distance)).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: center.x + r * 0.72 + 8, y: center.y - r * 0.72 - 4))
        }
        let edge = Self.mapSize / 2 - 4
        context.stroke(Path { $0.move(to: CGPoint(x: center.x, y: center.y - edge)); $0.addLine(to: CGPoint(x: center.x, y: center.y + edge)) }, with: .color(line))
        context.stroke(Path { $0.move(to: CGPoint(x: center.x - edge, y: center.y)); $0.addLine(to: CGPoint(x: center.x + edge, y: center.y)) }, with: .color(line))
        let label = { (text: String) in Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
        context.draw(label("Front"), at: CGPoint(x: center.x, y: 8))
        context.draw(label("Back"), at: CGPoint(x: center.x, y: Self.mapSize - 8))
        context.draw(label("L"), at: CGPoint(x: 8, y: center.y - 8))
        context.draw(label("R"), at: CGPoint(x: Self.mapSize - 8, y: center.y - 8))
    }

    private var head: some View {
        ZStack {
            Triangle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 10, height: 8)
                .offset(y: -Self.headRadius - 2)
            Circle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 2 * Self.headRadius, height: 2 * Self.headRadius)
            Image(systemName: "headphones")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.7))
        }
        .accessibilityHidden(true)
    }

    private func token(for app: AudioApp, at position: AppPosition, center: CGPoint) -> some View {
        let offset = SpatialMap.point(for: position, radius: Self.mapRadius, innerRadius: Self.innerRadius)
        let isSelected = selectedID == app.id
        return Image(nsImage: app.icon)
            .resizable()
            .frame(width: Self.tokenSize - 4, height: Self.tokenSize - 4)
            .padding(2)
            .background(Circle().fill(isSelected ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.18)))
            .overlay(alignment: .bottom) {
                if isSelected || draggingID == app.id {
                    Text(Self.describe(position))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.7)))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .offset(y: 16)
                }
            }
            .position(x: center.x + offset.x, y: center.y + offset.y)
            .zIndex(isSelected ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("spatialMap"))
                    .onChanged { drag in
                        selectedID = app.id
                        draggingID = app.id
                        let moved = SpatialMap.position(
                            at: CGPoint(x: drag.location.x - center.x, y: drag.location.y - center.y),
                            radius: Self.mapRadius, innerRadius: Self.innerRadius)
                        controller.setPosition(moved, for: app, commit: false)
                    }
                    .onEnded { _ in
                        draggingID = nil
                        controller.setPosition(controller.position(for: app), for: app)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { remove(app) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(app.name)
            .accessibilityValue(Self.describe(position))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 5.0 : -5.0
                controller.setPosition(AppPosition(azimuth: position.azimuth + step, distance: position.distance), for: app)
            }
    }

    static func describe(_ position: AppPosition) -> String {
        String(format: "%.0f° · %.1f m", position.azimuth.rounded() == 360 ? 0 : position.azimuth.rounded(), position.distance)
    }

    private var unplacedApps: [AudioApp] {
        controller.audioApps.filter { controller.position(for: $0) == nil }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not placed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if unplacedApps.isEmpty {
                Text(controller.audioApps.isEmpty ? "No apps are playing sound." : "Every playing app is on the map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(unplacedApps) { app in
                            Button {
                                controller.setPosition(AppPosition(azimuth: 0), for: app)
                                selectedID = app.id
                            } label: {
                                HStack(spacing: 6) {
                                    Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                                    Text(app.name).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(height: Self.trayRowHeight - 4)
                        }
                    }
                }
                // ScrollView has no intrinsic height in a size-to-fit popover.
                .frame(height: min(CGFloat(unplacedApps.count), 4) * Self.trayRowHeight)
            }
            Divider()
            if let app = controller.placedApps.first(where: { $0.id == selectedID }),
               let position = controller.position(for: app) {
                details(for: app, at: position)
            }
        }
    }

    private func details(for app: AudioApp, at position: AppPosition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                Text(app.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("Angle").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                TextField("Angle", value: Binding(
                    get: { position.azimuth.rounded() == 360 ? 0 : position.azimuth.rounded() },
                    set: { controller.setPosition(AppPosition(azimuth: $0, distance: position.distance), for: app) }
                ), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .labelsHidden()
                Text("°").foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Distance").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                Slider(value: Binding(
                    get: { position.distance },
                    set: { controller.setPosition(AppPosition(azimuth: position.azimuth, distance: $0), for: app, commit: false) }
                ), in: AppPosition.distanceRange) { editing in
                    if !editing { controller.setPosition(controller.position(for: app), for: app) }
                }
                .controlSize(.small)
                Text(String(format: "%.1f m", position.distance))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            Button("Remove from map") { remove(app) }
                .controlSize(.small)
        }
    }

    private func remove(_ app: AudioApp) {
        controller.setPosition(nil, for: app)
        if selectedID == app.id { selectedID = nil }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path {
            $0.move(to: CGPoint(x: rect.midX, y: rect.minY))
            $0.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            $0.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            $0.closeSubpath()
        }
    }
}

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum IssueReportMetrics {
    /// Rows are inset 8 points from the 32-point panel.
    static var rowRadius: CGFloat { InterfaceScale.metric(24) }
    /// Controls are inset 8 points from their row.
    static var controlRadius: CGFloat { InterfaceScale.metric(16) }
}

struct IssueReportRowBackground: ViewModifier {
    var isHighlighted = false
    var padding: CGFloat = InterfaceScale.metric(14)
    /// Focuses the row's field from a click anywhere in the row, padding
    /// included, rather than only on the field's own text.
    var focus: (() -> Void)?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: IssueReportMetrics.rowRadius, style: .continuous)
        let row = content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(isHighlighted ? 0.8 : 0.5), in: shape)
            .overlay {
                shape
                    .strokeBorder(SakuraCordAccentColor.color.opacity(isHighlighted ? 0.55 : 0), lineWidth: 1.5)
            }
            .animation(.easeOut(duration: 0.15), value: isHighlighted)
        if let focus {
            row.contentShape(shape).onTapGesture(perform: focus)
        } else {
            row
        }
    }
}

extension View {
    func issueReportRow(highlighted: Bool = false, padding: CGFloat = 14, focus: (() -> Void)? = nil) -> some View {
        modifier(IssueReportRowBackground(isHighlighted: highlighted, padding: padding, focus: focus))
    }
}

struct IssueReportFieldHeader: View {
    let label: String
    var isOptional = false
    var count: Int?
    var maximum: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(6)) {
            Text(label).font(.interface(.callout).weight(.semibold))
            if isOptional {
                Text("Optional").font(.interface(.caption)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: InterfaceScale.metric(8))
            if let count, let maximum, count > maximum * 4 / 5 {
                Text("\(count)/\(maximum)")
                    .font(.interface(.caption))
                    .monospacedDigit()
                    .foregroundStyle(count > maximum ? .red : .secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A multi-line field where Return inserts a new line, as reports expect.
struct IssueReportTextArea<Focus: Hashable>: View {
    let field: IssueReportField
    @Binding var text: String
    var focus: FocusState<Focus?>.Binding
    let focusValue: Focus

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            IssueReportFieldHeader(
                label: field.label, isOptional: !field.required,
                count: text.count, maximum: field.maxLength
            )
            ZStack(alignment: .topLeading) {
                if text.isEmpty, let placeholder = field.placeholder {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .focused(focus, equals: focusValue)
                    .tint(SakuraCordAccentColor.color)
                    .frame(minHeight: field.kind == .paragraph ? 66 : 20, maxHeight: InterfaceScale.metric(180))
                    .fixedSize(horizontal: false, vertical: true)
                    // Aligns typed text with the label despite the text view's line padding.
                    .padding(.horizontal, -InterfaceScale.metric(5))
                    .accessibilityLabel(field.label)
            }
            .font(.interface(.body))
            if let description = field.description {
                Text(description).font(.interface(.caption)).foregroundStyle(.secondary)
            }
        }
        .issueReportRow(highlighted: focus.wrappedValue == focusValue) { focus.wrappedValue = focusValue }
    }
}

struct IssueReportChoiceGroup: View {
    let field: IssueReportField
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            IssueReportFieldHeader(label: field.label, isOptional: !field.required)
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.top, InterfaceScale.metric(6))
                .padding(.bottom, InterfaceScale.metric(4))
            ForEach(field.options ?? []) { option in
                IssueReportChoiceRow(
                    title: option.label,
                    isSelected: selection == option.value
                ) {
                    withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
                        selection = selection == option.value && !field.required ? "" : option.value
                    }
                }
            }
        }
        .issueReportRow(padding: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
    }
}

private struct IssueReportChoiceRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(10)) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.interfaceSystem(size: 17))
                    .foregroundStyle(isSelected ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, InterfaceScale.metric(10))
            .frame(minHeight: InterfaceScale.metric(36))
            .background(
                isSelected
                    ? AnyShapeStyle(SakuraCordAccentColor.color.opacity(0.16))
                    : AnyShapeStyle(.quaternary.opacity(isHovered ? 0.7 : 0)),
                in: RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Areas from the hub's metadata, with an explicit "Not sure".
struct IssueReportAreaPicker: View {
    let field: IssueReportField
    let areas: [IssueReportForm.Area]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            IssueReportFieldHeader(label: field.label, isOptional: !field.required)
                .padding(.horizontal, InterfaceScale.metric(6))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: InterfaceScale.metric(6))], alignment: .leading, spacing: InterfaceScale.metric(6)) {
                chip(id: "", emoji: "🤷", label: "Not sure", help: "We’ll pick one")
                ForEach(areas) { area in
                    chip(id: area.id, emoji: area.emoji, label: area.label, help: area.description)
                }
            }
        }
        .issueReportRow(padding: 8)
    }

    private func chip(id: String, emoji: String, label: String, help: String) -> some View {
        let isSelected = selection == id
        return Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { selection = id }
        } label: {
            HStack(spacing: InterfaceScale.metric(7)) {
                Text(emoji)
                Text(label).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.interface(.callout))
            .padding(.horizontal, InterfaceScale.metric(12))
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(32), alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .regular.tint(SakuraCordAccentColor.color.opacity(0.7)).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .scaleEffect(isSelected ? 1.02 : 1)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Screenshots, recordings, or mockups: dropped, pasted from Finder, or chosen.
struct IssueReportAttachmentTray: View {
    let field: IssueReportField
    let attachments: [IssueReportAttachment]
    let remainingSlots: Int
    let add: ([URL]) -> Void
    let remove: (IssueReportAttachment) -> Void
    @State private var isImporting = false
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            IssueReportFieldHeader(label: field.label, isOptional: !field.required)
                .padding(.horizontal, InterfaceScale.metric(6))
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: InterfaceScale.metric(8)) {
                        ForEach(attachments) { attachment in
                            IssueReportAttachmentTile(attachment: attachment) { remove(attachment) }
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, InterfaceScale.metric(2))
                }
                .scrollIndicators(.never)
            }
            Button { isImporting = true } label: {
                HStack(spacing: InterfaceScale.metric(10)) {
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "photo.badge.plus")
                        .font(.interfaceSystem(size: 18))
                        .foregroundStyle(isTargeted ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isTargeted ? "Drop to attach" : "Drop files or choose…")
                        Text(field.description ?? "Up to 5 files, 10 MB each")
                            .font(.interface(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, InterfaceScale.metric(12))
                .frame(minHeight: InterfaceScale.metric(52))
                .background(
                    SakuraCordAccentColor.color.opacity(isTargeted ? 0.14 : 0),
                    in: RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous)
                        .strokeBorder(
                            isTargeted ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.quaternary),
                            style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [5, 4])
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(remainingSlots <= 0)
            .opacity(remainingSlots <= 0 ? 0.5 : 1)
        }
        .issueReportRow(padding: 8)
        .animation(.snappy(duration: 0.25), value: attachments)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 && remainingSlots > 0 }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .movie, .text, .json, .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { add(urls) }
        }
    }
}

private struct IssueReportAttachmentTile: View {
    let attachment: IssueReportAttachment
    let remove: () -> Void
    @State private var thumbnail: CGImage?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
                } else {
                    VStack(spacing: InterfaceScale.metric(4)) {
                        Image(nsImage: NSWorkspace.shared.icon(for: attachment.contentType))
                            .resizable()
                            .frame(width: InterfaceScale.metric(34), height: InterfaceScale.metric(34))
                        Text(attachment.name)
                            .font(.interface(.caption2))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, InterfaceScale.metric(6))
                    }
                }
            }
            .frame(width: InterfaceScale.metric(76), height: InterfaceScale.metric(76))
            .background(.quaternary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.interfaceSystem(size: 9, weight: .bold))
                    .frame(width: InterfaceScale.metric(20), height: InterfaceScale.metric(20))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding(InterfaceScale.metric(4))
            .opacity(isHovered ? 1 : 0.85)
            .help("Remove \(attachment.name)")
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .onModalHover { isHovered = $0 }
        .help(attachment.name)
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            let data = attachment.data
            thumbnail = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
            }.value
        }
    }
}

struct IssueReportToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var isAvailable = true

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: symbol)
                .font(.interfaceSystem(size: 15, weight: .medium))
                .foregroundStyle(isOn && isAvailable ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.secondary))
                .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: InterfaceScale.metric(8))
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(SakuraCordAccentColor.color)
                .disabled(!isAvailable)
        }
        .padding(.horizontal, InterfaceScale.metric(8))
        .frame(minHeight: InterfaceScale.metric(48))
        .opacity(isAvailable ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }
}

/// A capsule action whose icon may be an SF Symbol or a bundled brand symbol.
struct IssueReportActionButton: View {
    let title: String
    let icon: Image
    var primary = false
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(8)) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    icon
                }
                Text(title)
            }
            .font(.interface(.body).weight(.semibold))
            .padding(.horizontal, InterfaceScale.metric(18))
            .frame(height: InterfaceScale.metric(40))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            primary ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .disabled(isBusy)
        .help(title)
        .accessibilityLabel(title)
    }
}

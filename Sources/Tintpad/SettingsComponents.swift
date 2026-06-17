import SwiftUI

/// A titled card matching the grouped-Form look, for panes built with custom
/// layouts (Repos/Recents/Prompts) so they feel consistent with the Form panes.
struct SettingsCard<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.caption2.weight(.semibold)).tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.12), lineWidth: 1))
        }
    }
}

/// A scrolling container with consistent padding/width for custom panes.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(22)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A friendly empty state: glyph + title + subtitle.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

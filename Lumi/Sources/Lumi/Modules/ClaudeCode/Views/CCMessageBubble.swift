import SwiftUI

struct CCMessageBubble: View {
    let message: ClaudeCodeController.CCMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundColor(.purple.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.purple.opacity(0.15)))
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 11))
                    .foregroundColor(PanelInk.primary)
                    .padding(10)
                    .background(
                        message.role == .user
                            ? Color.pink.opacity(0.25)
                            : PanelInk.chip(0.08)
                    )
                    .cornerRadius(10)
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.pink.opacity(0.7))
                    .frame(width: 22, height: 22)
            }
        }
    }
}

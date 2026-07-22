import SwiftUI

struct ChatSettingsView: View {
    var body: some View {
        Form {
            ChatAdvancedSettingsSection()
            MCPSettingsSection()
        }
        .formStyle(.grouped)
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @State private var showQuitAlert = false
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            ScrollView {
                SettingsContent(settings: settings)
            }
            // ここを旧シグネチャに戻す
            .onChange(of: settings.language) {
                updateWindowTitle()
            }
            .onAppear {
                updateWindowTitle()
            }
            
            footerArea
        }
        .frame(width: 440)
    }
    
    private var footerArea: some View {
        HStack {
            Spacer()
            Button(action: restartApp) {
                Text(t("restart"))
            }
            Button(action: { showQuitAlert = true }) {
                Text(t("quit"))
                    .foregroundColor(.red)
            }
            .keyboardShortcut("q")
            .alert(t("quitAlertTitle"), isPresented: $showQuitAlert) {
                Button(t("quit"), role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
                Button(t("cancel"), role: .cancel) {}
            } message: {
                Text(t("quitAlertMessage"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(NSColor.separatorColor)),
            alignment: .top
        )
    }
    
    private func updateWindowTitle() {
        for window in NSApp.windows {
            window.title = t("windowTitle")
        }
    }

    private func restartApp() {
        AppRestartManager.restart()
    }
}

//
// MARK: - 設定画面全体
//

struct SettingsContent: View {
    @ObservedObject var settings: SettingsModel
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            LanguageSettingCard(settings: settings)
            MoveSettingCard(settings: settings)
            ResizeSettingCard(settings: settings)
            DetailSettingCardView(settings: settings)
        }
        .padding(20)
    }
}

//
// MARK: - 言語設定
//

struct LanguageSettingCard: View {
    @ObservedObject var settings: SettingsModel
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Text(t("languageSettings"))
                    .font(.headline)
                
                Spacer()
                
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        if lang == .system {
                            Text(LocalizationManager.shared.text("systemDefault", language: .system)).tag(lang)
                        } else {
                            Text(lang.rawValue).tag(lang)
                        }
                    }
                }
                .frame(width: 150)
                .labelsHidden()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

//
// MARK: - 移動設定
//

struct MoveSettingCard: View {
    @ObservedObject var settings: SettingsModel
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        SettingCard(
            title: t("moveWindow"),
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            color: .blue,
            isOn: $settings.isMoveEnabled
        ) {
            MoveResizeSettingContent(
                setting: $settings.moveSetting,
                settings: settings
            )
        }
    }
}

//
// MARK: - リサイズ設定
//

struct ResizeSettingCard: View {
    @ObservedObject var settings: SettingsModel
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        SettingCard(
            title: t("resizeWindow"),
            icon: "arrow.up.left.and.arrow.down.right",
            color: .orange,
            isOn: $settings.isResizeEnabled
        ) {
            MoveResizeSettingContent(
                setting: $settings.resizeSetting,
                settings: settings
            )
        }
    }
}

//
// MARK: - 移動 / リサイズ 共通 UI
//

struct MoveResizeSettingContent: View {
    @Binding var setting: ShortcutSetting
    @ObservedObject var settings: SettingsModel
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // 修飾キー
            HStack(alignment: .top) {
                Label(t("modifierKey"), systemImage: "keyboard")
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 6) {
                    if settings.hasConflict && !settings.isRecording {
                        Label(t("conflictWarning"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    
                    KeyRecorderButton(
                        setting: $setting,
                        isGlobalRecording: $settings.isRecording,
                        timeout: settings.recordingTimeout,
                        isConflict: settings.hasConflict,
                        language: settings.language
                    )
                    .frame(width: 150)
                    
                    Toggle(t("modifierOnly"), isOn: $setting.allowModifierOnly)
                        .toggleStyle(.checkbox)
                }
            }
            
            Divider()
            
            // クリック種別
            HStack(alignment: .center) {
                Label(t("click"), systemImage: "computermouse")
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                
                Spacer()
                
                Picker("", selection: $setting.mouseButton) {
                    ForEach(MouseButton.allCases) { btn in
                        Text(btn.localizedName(lang: settings.language)).tag(btn)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }
}

//
// MARK: - 詳細設定
//

struct DetailSettingCardView: View {
    @ObservedObject var settings: SettingsModel
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        DetailSettingCard(
            title: t("detailSettings"),
            icon: "wrench",
            color: .gray         // スパナを灰色に
        ) {
            VStack(alignment: .leading, spacing: 12) {
                
                // 長押し時間
                VStack(alignment: .leading, spacing: 4) {
                    Label(t("longPressDuration"), systemImage: "timer")
                        .font(.headline)
                    
                    HStack {
                        Slider(value: $settings.recordingTimeout, in: 0.5...3.0, step: 0.1)
                        Text(String(format: "%.1f%@", settings.recordingTimeout, t("sec")))
                            .frame(width: 60, alignment: .trailing)
                    }
                    
                    Text(t("longPressDesc"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // ログイン時自動実行（アイコンなし）
                Toggle(isOn: $settings.launchAtLogin) {
                    Text(t("launchAtLogin"))
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

//
// MARK: - 共通カード UI
//

struct SettingCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @Binding var isOn: Bool
    let content: Content
    
    init(title: String, icon: String, color: Color, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.color = color
        self._isOn = isOn
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(isOn ? color : .gray)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(isOn ? .primary : .secondary)
                
                Spacer()
                
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            content
                .padding(16)
                .opacity(isOn ? 1 : 0.5)
                .disabled(!isOn)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct DetailSettingCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    let content: Content
    
    init(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.color = color
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Text(title)
                    .font(.headline)
                
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            content
                .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

//
// MARK: - キーレコーダーボタン
//

struct KeyRecorderButton: View {
    @Binding var setting: ShortcutSetting
    @Binding var isGlobalRecording: Bool
    var timeout: Double
    var isConflict: Bool
    var language: AppLanguage
    
    @State private var isRecordingSelf = false
    @State private var monitor: Any?
    @State private var timer: Timer?
    @State private var progress: CGFloat = 0.0
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: language)
    }
    
    var body: some View {
        Button(action: {
            if isRecordingSelf {
                stopRecording()
            } else {
                startRecording()
            }
        }) {
            ZStack(alignment: .leading) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                        
                        if isRecordingSelf && setting.allowModifierOnly {
                            Rectangle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: geometry.size.width * progress)
                                .animation(
                                    progress == 0
                                    ? .linear(duration: 0)
                                    : .linear(duration: timeout),
                                    value: progress
                                )
                        }
                    }
                }
                
                HStack {
                    if isRecordingSelf {
                        Image(systemName: "record.circle.fill")
                            .foregroundColor(.red)
                            .symbolEffect(.pulse)
                        
                        if setting.flags == 0 && setting.keyCode == -1 {
                            if setting.allowModifierOnly {
                                Text(t("inputLongPress"))
                                    .foregroundColor(.red)
                                    .font(.caption)
                            } else {
                                Text(t("inputKey"))
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                        } else {
                            Text(setting.keyDisplayString)
                                .foregroundColor(.primary)
                                .fontWeight(.bold)
                                .lineLimit(1)
                                .id(setting.keyDisplayString)
                                .animation(nil, value: setting.keyDisplayString)
                        }
                    } else {
                        if setting.keyDisplayString == "None" {
                            Text(t("notSet"))
                                .foregroundColor(.secondary)
                        } else {
                            Text(setting.keyDisplayString)
                                .fontWeight(.medium)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var borderColor: Color {
        if isRecordingSelf { return .blue }
        if isConflict { return .red }
        return Color(NSColor.separatorColor)
    }
    
    private func startRecording() {
        if isGlobalRecording { return }
        
        isRecordingSelf = true
        isGlobalRecording = true
        progress = 0.0
        
        setting.keyCode = -1
        setting.flags = 0
        
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            
            let mask: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
            let flags = event.modifierFlags.intersection(mask)
            
            if event.type == .flagsChanged {
                DispatchQueue.main.async {
                    self.setting.flags = flags.rawValue
                    self.setting.keyCode = -1
                    
                    if !self.setting.allowModifierOnly { return }
                    
                    self.resetTimerAndProgress()
                    
                    if flags.isEmpty { return }
                    
                    withAnimation {
                        self.progress = 1.0
                    }
                    
                    self.timer = Timer.scheduledTimer(withTimeInterval: self.timeout, repeats: false) { _ in
                        self.stopRecording()
                    }
                }
                return nil
            }
            
            if event.type == .keyDown {
                DispatchQueue.main.async {
                    if self.setting.allowModifierOnly { return }
                    
                    self.resetTimerAndProgress()
                    self.setting.keyCode = Int(event.keyCode)
                    self.setting.flags = flags.rawValue
                    self.stopRecording()
                }
                return nil
            }
            
            return event
        }
    }
    
    private func resetTimerAndProgress() {
        timer?.invalidate()
        timer = nil
        progress = 0.0
    }
    
    private func stopRecording() {
        resetTimerAndProgress()
        
        isRecordingSelf = false
        isGlobalRecording = false
        
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var permissionCoordinator: AccessibilityPermissionCoordinator
    @State private var showQuitAlert = false
    
    private func t(_ key: String) -> String {
        LocalizationManager.shared.text(key, language: settings.language)
    }
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Divider()

                ScrollView {
                    SettingsContent(settings: settings)
                }
                .onChange(of: settings.language) {
                    updateWindowTitle()
                }
                .onAppear {
                    updateWindowTitle()
                }

                footerArea
            }
            .blur(radius: permissionCoordinator.isTrusted ? 0 : 8)
            .disabled(!permissionCoordinator.isTrusted)
            .allowsHitTesting(permissionCoordinator.isTrusted)
            .accessibilityHidden(!permissionCoordinator.isTrusted)

            if !permissionCoordinator.isTrusted {
                Button(t("accessibilityPermissionOpenSettings")) {
                    permissionCoordinator.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: permissionCoordinator.isTrusted)
        .frame(width: WindoorDesign.Layout.settingsWidth)
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
        .padding(.horizontal, WindoorDesign.Layout.footerHorizontalPadding)
        .padding(.vertical, WindoorDesign.Layout.footerVerticalPadding)
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
        VStack(spacing: WindoorDesign.Layout.sectionSpacing) {
            LanguageSettingCard(settings: settings)
            MoveSettingCard(settings: settings)
            ResizeSettingCard(settings: settings)
            DetailSettingCardView(settings: settings)
        }
        .padding(WindoorDesign.Layout.pagePadding)
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
                WindoorIconBadge(
                    systemName: "globe",
                    color: WindoorDesign.Icon.languageColor
                )
                
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
                .frame(width: WindoorDesign.Layout.controlColumnWidth)
                .labelsHidden()
            }
            .padding(WindoorDesign.Layout.cardHeaderPadding)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(WindoorDesign.Card.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: WindoorDesign.Card.cornerRadius)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(WindoorDesign.Card.shadowOpacity),
            radius: WindoorDesign.Card.shadowRadius,
            x: 0,
            y: 1
        )
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
            color: WindoorDesign.Icon.moveColor,
            isOn: $settings.isMoveEnabled,
            canEnable: settings.moveSetting.isValidTrigger,
            isEditing: settings.isRecording
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
            color: WindoorDesign.Icon.resizeColor,
            isOn: $settings.isResizeEnabled,
            canEnable: settings.resizeSetting.isValidTrigger,
            isEditing: settings.isRecording
        ) {
            VStack(spacing: 16) {
                MoveResizeSettingContent(
                    setting: $settings.resizeSetting,
                    settings: settings
                )

                Divider()

                HStack(alignment: .center) {
                    Label(t("anchorPoint"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(.secondary)
                        .frame(width: WindoorDesign.Layout.rowLabelWidth, alignment: .leading)

                    Spacer()

                    Picker("", selection: $settings.resizeAnchorPoint) {
                        ForEach(ResizeAnchorPoint.allCases) { anchorPoint in
                            Text(anchorPoint.localizedName(lang: settings.language)).tag(anchorPoint)
                        }
                    }
                    .labelsHidden()
                    .frame(width: WindoorDesign.Layout.controlColumnWidth)
                }
            }
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
                    .frame(width: WindoorDesign.Layout.rowLabelWidth, alignment: .leading)
                
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
                    .frame(width: WindoorDesign.Layout.controlColumnWidth)
                    
                    Toggle(t("modifierOnly"), isOn: $setting.allowModifierOnly)
                        .toggleStyle(.checkbox)
                }
            }
            
            Divider()
            
            // クリック種別
            HStack(alignment: .center) {
                Label(t("click"), systemImage: "computermouse")
                    .foregroundColor(.secondary)
                    .frame(width: WindoorDesign.Layout.rowLabelWidth, alignment: .leading)
                
                Spacer()

                HStack(spacing: 8) {
                    if setting.isLeftClickOnly {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .help(t("leftClickOnlyWarning"))
                            .accessibilityLabel(t("leftClickOnlyWarning"))
                    }

                    Picker("", selection: $setting.mouseButton) {
                        ForEach(MouseButton.allCases) { btn in
                            Text(btn.localizedName(lang: settings.language)).tag(btn)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                .frame(width: WindoorDesign.Layout.controlColumnWidth)
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
            color: WindoorDesign.Icon.detailColor
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

                Toggle(isOn: $settings.preserveWindowOrder) {
                    Text(t("preserveWindowOrder"))
                }
                .toggleStyle(.checkbox)

                Divider()

                Toggle(isOn: $settings.showMenuBarIcon) {
                    Text(t("showMenuBarIcon"))
                }
                .toggleStyle(.checkbox)

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
    let canEnable: Bool
    let isEditing: Bool
    let content: Content
    
    init(
        title: String,
        icon: String,
        color: Color,
        isOn: Binding<Bool>,
        canEnable: Bool = true,
        isEditing: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self._isOn = isOn
        self.canEnable = canEnable
        self.isEditing = isEditing
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                WindoorIconBadge(systemName: icon, color: isOn ? color : .gray)
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(isOn ? .primary : .secondary)
                
                Spacer()
                
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .disabled(!canEnable)
            }
            .padding(WindoorDesign.Layout.cardHeaderPadding)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            content
                .padding(WindoorDesign.Layout.cardContentPadding)
                .opacity(isOn || !canEnable || isEditing ? 1 : 0.5)
                .disabled(!isOn && canEnable && !isEditing)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(WindoorDesign.Card.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: WindoorDesign.Card.cornerRadius)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(WindoorDesign.Card.shadowOpacity),
            radius: WindoorDesign.Card.shadowRadius,
            x: 0,
            y: 1
        )
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
                WindoorIconBadge(systemName: icon, color: color)
                
                Text(title)
                    .font(.headline)
                
                Spacer()
            }
            .padding(WindoorDesign.Layout.cardHeaderPadding)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            content
                .padding(WindoorDesign.Layout.cardContentPadding)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(WindoorDesign.Card.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: WindoorDesign.Card.cornerRadius)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(WindoorDesign.Card.shadowOpacity),
            radius: WindoorDesign.Card.shadowRadius,
            x: 0,
            y: 1
        )
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

import Foundation

// 言語定義
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "System Default" // 内部IDとして使用、表示名は辞書で変換
    case japanese = "日本語"
    case english = "English"
    case german = "Deutsch"
    case french = "Français"
    case spanish = "Español"
    case korean = "한국어"
    case chineseSimplified = "简体中文"
    case chineseTraditional = "繁體中文"
    case portugueseBrazil = "Português (Brasil)"
    case russian = "Русский"
    
    var id: String { self.rawValue }
}

class LocalizationManager {
    static let shared = LocalizationManager()
    
    // 現在有効な言語を判定
    func resolveLanguage(_ language: AppLanguage) -> AppLanguage {
        if language == .system {
            let preferredLang = Locale.preferredLanguages.first ?? "en"
            
            if preferredLang.hasPrefix("ja") { return .japanese }
            if preferredLang.hasPrefix("de") { return .german }
            if preferredLang.hasPrefix("fr") { return .french }
            if preferredLang.hasPrefix("es") { return .spanish }
            if preferredLang.hasPrefix("ko") { return .korean }
            
            if preferredLang.hasPrefix("zh") {
                if preferredLang.contains("Hant") || preferredLang.contains("TW") || preferredLang.contains("HK") {
                    return .chineseTraditional
                }
                return .chineseSimplified
            }
            
            if preferredLang.hasPrefix("pt") { return .portugueseBrazil }
            if preferredLang.hasPrefix("ru") { return .russian }
            
            return .english
        }
        return language
    }
    
    // 翻訳辞書
    private let translations: [AppLanguage: [String: String]] = [
        .japanese: [
            "systemDefault": "システムに合わせる",
            "windowTitle": "Windoor 設定",
            "languageSettings": "言語設定",
            "conflictWarning": "設定が重複しています",
            "moveWindow": "ウィンドウの移動",
            "resizeWindow": "ウィンドウのリサイズ",
            "modifierKey": "修飾キー",
            "click": "クリック",
            "modifierOnly": "修飾キーのみ",
            "detailSettings": "詳細設定",
            "longPressDuration": "長押し確定の時間",
            "longPressDesc": "「修飾キーのみ」がオンの場合、キーを押し続けると確定します。",
            "launchAtLogin": "ログイン時に自動実行",
            "quit": "終了",
            "quitAlertTitle": "Windoorを終了",
            "quitAlertMessage": "アプリを終了してもよろしいですか？\nウィンドウ操作機能が停止します。",
            "cancel": "キャンセル",
            "inputKey": "キーを入力...",
            "inputLongPress": "長押しで確定...",
            "notSet": "未設定",
            "sec": "秒",
            "leftClick": "左クリック",
            "rightClick": "右クリック",
            "centerClick": "ホイール(中)",
            "menuSettings": "設定...",
            "menuQuit": "Windoorを終了"
        ],
        .english: [
            "systemDefault": "System Default",
            "windowTitle": "Windoor Settings",
            "languageSettings": "Language",
            "conflictWarning": "Configuration Conflict",
            "moveWindow": "Move Window",
            "resizeWindow": "Resize Window",
            "modifierKey": "Modifier Key",
            "click": "Click",
            "modifierOnly": "Modifier Only",
            "detailSettings": "Advanced Settings",
            "longPressDuration": "Long Press Duration",
            "longPressDesc": "Hold key to confirm when 'Modifier Only' is on.",
            "launchAtLogin": "Launch at Login",
            "quit": "Quit",
            "quitAlertTitle": "Quit Windoor",
            "quitAlertMessage": "Are you sure you want to quit?\nWindow management features will stop.",
            "cancel": "Cancel",
            "inputKey": "Press Key...",
            "inputLongPress": "Hold to Confirm...",
            "notSet": "Not Set",
            "sec": "s",
            "leftClick": "Left Click",
            "rightClick": "Right Click",
            "centerClick": "Middle Click",
            "menuSettings": "Settings...",
            "menuQuit": "Quit Windoor"
        ],
        .german: [
            "systemDefault": "Systemstandard",
            "windowTitle": "Windoor Einstellungen",
            "languageSettings": "Sprache",
            "conflictWarning": "Konflikt bei Einstellungen",
            "moveWindow": "Fenster verschieben",
            "resizeWindow": "Fenstergröße ändern",
            "modifierKey": "Modifikatortaste",
            "click": "Klick",
            "modifierOnly": "Nur Modifikator",
            "detailSettings": "Erweiterte Einstellungen",
            "longPressDuration": "Dauer für langes Drücken",
            "longPressDesc": "Taste gedrückt halten zum Bestätigen.",
            "launchAtLogin": "Beim Anmelden starten",
            "quit": "Beenden",
            "quitAlertTitle": "Windoor beenden",
            "quitAlertMessage": "Möchten Sie wirklich beenden?",
            "cancel": "Abbrechen",
            "inputKey": "Taste drücken...",
            "inputLongPress": "Gedrückt halten...",
            "notSet": "Nicht gesetzt",
            "sec": "s",
            "leftClick": "Linksklick",
            "rightClick": "Rechtsklick",
            "centerClick": "Mittelklick",
            "menuSettings": "Einstellungen...",
            "menuQuit": "Windoor beenden"
        ],
        .french: [
            "systemDefault": "Système par défaut",
            "windowTitle": "Paramètres Windoor",
            "languageSettings": "Langue",
            "conflictWarning": "Conflit de configuration",
            "moveWindow": "Déplacer la fenêtre",
            "resizeWindow": "Redimensionner",
            "modifierKey": "Touche modif.",
            "click": "Clic",
            "modifierOnly": "Modif. uniquement",
            "detailSettings": "Paramètres avancés",
            "longPressDuration": "Durée appui long",
            "longPressDesc": "Maintenez pour confirmer si 'Modif. uniquement' est actif.",
            "launchAtLogin": "Lancer à la connexion",
            "quit": "Quitter",
            "quitAlertTitle": "Quitter Windoor",
            "quitAlertMessage": "Voulez-vous vraiment quitter ?",
            "cancel": "Annuler",
            "inputKey": "Appuyez...",
            "inputLongPress": "Maintenez...",
            "notSet": "Non défini",
            "sec": "s",
            "leftClick": "Clic gauche",
            "rightClick": "Clic droit",
            "centerClick": "Clic milieu",
            "menuSettings": "Paramètres...",
            "menuQuit": "Quitter Windoor"
        ],
        .spanish: [
            "systemDefault": "Predeterminado del sistema",
            "windowTitle": "Configuración Windoor",
            "languageSettings": "Idioma",
            "conflictWarning": "Conflicto de configuración",
            "moveWindow": "Mover ventana",
            "resizeWindow": "Redimensionar",
            "modifierKey": "Tecla modificadora",
            "click": "Clic",
            "modifierOnly": "Solo modificador",
            "detailSettings": "Ajustes avanzados",
            "longPressDuration": "Duración pulsación larga",
            "longPressDesc": "Mantenga pulsado para confirmar.",
            "launchAtLogin": "Ejecutar al iniciar sesión",
            "quit": "Salir",
            "quitAlertTitle": "Salir de Windoor",
            "quitAlertMessage": "¿Seguro que quieres salir?",
            "cancel": "Cancelar",
            "inputKey": "Presione tecla...",
            "inputLongPress": "Mantenga...",
            "notSet": "No establecido",
            "sec": "s",
            "leftClick": "Clic izquierdo",
            "rightClick": "Clic derecho",
            "centerClick": "Clic central",
            "menuSettings": "Ajustes...",
            "menuQuit": "Salir de Windoor"
        ],
        .korean: [
            "systemDefault": "시스템 기본값",
            "windowTitle": "Windoor 설정",
            "languageSettings": "언어",
            "conflictWarning": "설정 충돌",
            "moveWindow": "창 이동",
            "resizeWindow": "창 크기 조절",
            "modifierKey": "수식 키",
            "click": "클릭",
            "modifierOnly": "수식 키만 사용",
            "detailSettings": "고급 설정",
            "longPressDuration": "길게 누르기 시간",
            "longPressDesc": "'수식 키만 사용'이 켜져 있으면 길게 눌러 확정합니다.",
            "launchAtLogin": "로그인 시 자동 실행",
            "quit": "종료",
            "quitAlertTitle": "Windoor 종료",
            "quitAlertMessage": "정말 종료하시겠습니까?",
            "cancel": "취소",
            "inputKey": "키 입력...",
            "inputLongPress": "길게 눌러 확정...",
            "notSet": "미설정",
            "sec": "초",
            "leftClick": "좌클릭",
            "rightClick": "우클릭",
            "centerClick": "휠 클릭",
            "menuSettings": "설정...",
            "menuQuit": "Windoor 종료"
        ],
        .chineseSimplified: [
            "systemDefault": "跟随系统",
            "windowTitle": "Windoor 设置",
            "languageSettings": "语言",
            "conflictWarning": "配置冲突",
            "moveWindow": "移动窗口",
            "resizeWindow": "调整大小",
            "modifierKey": "修饰键",
            "click": "点击",
            "modifierOnly": "仅修饰键",
            "detailSettings": "高级设置",
            "longPressDuration": "长按确认时间",
            "longPressDesc": "开启“仅修饰键”时，长按以确认。",
            "launchAtLogin": "登录时自动启动",
            "quit": "退出",
            "quitAlertTitle": "退出 Windoor",
            "quitAlertMessage": "确定要退出吗？",
            "cancel": "取消",
            "inputKey": "输入按键...",
            "inputLongPress": "长按确认...",
            "notSet": "未设置",
            "sec": "秒",
            "leftClick": "左键",
            "rightClick": "右键",
            "centerClick": "中键",
            "menuSettings": "设置...",
            "menuQuit": "退出 Windoor"
        ],
        .chineseTraditional: [
            "systemDefault": "系統預設",
            "windowTitle": "Windoor 設定",
            "languageSettings": "語言",
            "conflictWarning": "設定衝突",
            "moveWindow": "移動視窗",
            "resizeWindow": "調整大小",
            "modifierKey": "修飾鍵",
            "click": "點擊",
            "modifierOnly": "僅修飾鍵",
            "detailSettings": "進階設定",
            "longPressDuration": "長按確認時間",
            "longPressDesc": "開啟「僅修飾鍵」時，長按以確認。",
            "launchAtLogin": "登入時自動啟動",
            "quit": "結束",
            "quitAlertTitle": "結束 Windoor",
            "quitAlertMessage": "確定要結束嗎？",
            "cancel": "取消",
            "inputKey": "輸入按鍵...",
            "inputLongPress": "長按確認...",
            "notSet": "未設定",
            "sec": "秒",
            "leftClick": "左鍵",
            "rightClick": "右鍵",
            "centerClick": "中鍵",
            "menuSettings": "設定...",
            "menuQuit": "結束 Windoor"
        ],
        .portugueseBrazil: [
            "systemDefault": "Padrão do Sistema",
            "windowTitle": "Configurações Windoor",
            "languageSettings": "Idioma",
            "conflictWarning": "Conflito de configuração",
            "moveWindow": "Mover Janela",
            "resizeWindow": "Redimensionar",
            "modifierKey": "Tecla Modificadora",
            "click": "Clique",
            "modifierOnly": "Apenas Modificador",
            "detailSettings": "Configurações Avançadas",
            "longPressDuration": "Duração do toque longo",
            "longPressDesc": "Segure para confirmar quando 'Apenas Modificador' estiver ativado.",
            "launchAtLogin": "Iniciar ao fazer login",
            "quit": "Sair",
            "quitAlertTitle": "Sair do Windoor",
            "quitAlertMessage": "Tem certeza que deseja sair?",
            "cancel": "Cancelar",
            "inputKey": "Pressione...",
            "inputLongPress": "Segure...",
            "notSet": "Não definido",
            "sec": "s",
            "leftClick": "Clique Esquerdo",
            "rightClick": "Clique Direito",
            "centerClick": "Clique do Meio",
            "menuSettings": "Configurações...",
            "menuQuit": "Sair do Windoor"
        ],
        .russian: [
            "systemDefault": "Системные настройки",
            "windowTitle": "Настройки Windoor",
            "languageSettings": "Язык",
            "conflictWarning": "Конфликт настроек",
            "moveWindow": "Перемещение",
            "resizeWindow": "Изменение размера",
            "modifierKey": "Модификатор",
            "click": "Клик",
            "modifierOnly": "Только модификатор",
            "detailSettings": "Дополнительно",
            "longPressDuration": "Длительность нажатия",
            "longPressDesc": "Удерживайте клавишу для подтверждения.",
            "launchAtLogin": "Запускать при входе",
            "quit": "Выход",
            "quitAlertTitle": "Выйти из Windoor",
            "quitAlertMessage": "Вы уверены, что хотите выйти?",
            "cancel": "Отмена",
            "inputKey": "Нажмите клавишу...",
            "inputLongPress": "Удерживайте...",
            "notSet": "Не задано",
            "sec": "с",
            "leftClick": "Левый клик",
            "rightClick": "Правый клик",
            "centerClick": "Средний клик",
            "menuSettings": "Настройки...",
            "menuQuit": "Выйти из Windoor"
        ]
    ]
    
    func text(_ key: String, language: AppLanguage) -> String {
        let resolvedLang = resolveLanguage(language)
        return translations[resolvedLang]?[key] ?? translations[.english]?[key] ?? key
    }
}

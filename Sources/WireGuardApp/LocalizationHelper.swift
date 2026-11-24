// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

private let baseLocalization = Bundle.main.path(forResource: "Base", ofType: "lproj").flatMap(Bundle.init(path:))

func tr(_ key: String) -> String {
    let translation = NSLocalizedString(key, comment: "")
    return translation == key ? baseLocalization?.localizedString(forKey: key, value: key, table: nil) ?? key : translation
}

func tr(format: String, _ arguments: CVarArg...) -> String {
    return String(format: tr(format), arguments: arguments)
}

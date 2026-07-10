//
//  keyboardApp.swift
//  keyboard
//
//  Created by Meher Deepak on 21/06/26.
//

import SwiftUI
import CoreData

@main
struct keyboardApp: App {
    let persistenceController = PersistenceController.shared

    init() { FontInstaller.registerBundledFonts() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

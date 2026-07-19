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

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let spec = DesignLabSpec.commandLine {
                    DesignLabView(spec: spec)
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            }
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}

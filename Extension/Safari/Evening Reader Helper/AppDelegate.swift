//
//  AppDelegate.swift
//  Evening Reader Helper
//
//  Created by Jonathan Bobrow on 11/2/26.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Points every Chromium browser at the helper this app carries, so the Chrome
        // extension works once the app has been opened.
        _ = ChromeHosts.outcome
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}

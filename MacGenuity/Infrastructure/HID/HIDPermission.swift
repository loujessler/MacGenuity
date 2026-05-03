//
//  HIDPermission.swift
//  MacGenuity
//
//  Wraps `IOHIDCheckAccess` / `IOHIDRequestAccess`. Avoids attempting
//  device opens until macOS has granted Input Monitoring access — which
//  is what previously triggered tight TCC retry loops and
//  "TCC deny IOHIDDeviceOpen" log spam.
//

import Foundation
import IOKit
import IOKit.hid
import AppKit

enum HIDPermission {
    /// Reads the current access state without prompting the user.
    static func currentState() -> HIDAccessState {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch access {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown
        }
    }

    /// Requests access. May trigger a one-time system prompt the first
    /// time it is invoked for this app bundle. Returns the resulting state.
    static func requestAccess() -> HIDAccessState {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        return granted ? .granted : currentState()
    }

    /// Reveal the Input Monitoring pane in System Settings.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

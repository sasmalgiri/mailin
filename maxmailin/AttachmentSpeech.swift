//
//  AttachmentSpeech.swift
//  maxmailin
//
//  TYPE-05 (owner, 2026-11-06): the words spoken in an audio or video
//  attachment become searchable text, recognised on this device with
//  Apple's Speech framework — never sent anywhere (`requiresOnDeviceRecognition`).
//  Recognised speech is its own document kind in the chunk index, so a hit
//  is labelled "Recognised speech: file" in the evidence chips and counted
//  apart in coverage. A recording the device has no on-device model for, or
//  that the person has not allowed recognition for, is recorded with that
//  reason — never as "no match".
//
//  Switch: capability `.attachmentSpeech` (Settings ▸ Modules), pushed by
//  CapabilityWiring. Runs inside the attachment indexing pass, off the main
//  thread; the Speech callbacks are awaited with a semaphore there.
//

import AVFoundation
import Foundation
import Speech

enum AttachmentSpeech {
    nonisolated(unsafe) static var isEnabled = false

    /// Containers AVFoundation decodes on every supported system.
    static let mediaExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac", "mov", "mp4", "m4v", "3gp", "mpg", "mpeg"]

    static func isMedia(mimeType: String, filename: String) -> Bool {
        let mime = mimeType.lowercased()
        return mime.hasPrefix("audio/") || mime.hasPrefix("video/") || mediaExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    struct Transcript: Sendable, Equatable {
        /// The recognised words; nil when recognition could not run.
        let text: String?
        /// The language the recogniser used, e.g. "en-US".
        let locale: String?
        /// Why nothing could be recognised, for the coverage note.
        let failure: String?
        /// True when the person has not allowed speech recognition for mailin.
        let notAuthorized: Bool
    }

    /// Longest a single recording is waited for.
    static let timeout: TimeInterval = 20 * 60

    /// Recognises one file (audio, or the audio track of a video). Blocks the
    /// calling thread, which must not be the main thread.
    static func transcribe(fileURL: URL) -> Transcript {
        precondition(!Thread.isMainThread, "speech recognition waits synchronously; call it off the main thread")
        // IPAD-07: the one place a recording is about to be recognised — ask here, not at launch.
        switch requestAuthorizationBeforeRecognising() {
        case .authorized: break
        case .denied, .restricted:
            return Transcript(text: nil, locale: nil, failure: String(localized: "speech recognition is not allowed for mailin — allow it in System Settings ▸ Privacy & Security ▸ Speech Recognition"), notAuthorized: true)
        case .notDetermined:
            return Transcript(text: nil, locale: nil, failure: String(localized: "speech recognition has not been allowed yet — the next time the app is in front it asks once"), notAuthorized: true)
        @unknown default:
            return Transcript(text: nil, locale: nil, failure: String(localized: "speech recognition is not available"), notAuthorized: true)
        }
        guard let recognizer = onDeviceRecognizer() else {
            return Transcript(text: nil, locale: nil, failure: String(localized: "no on-device speech model is installed for \(Locale.current.identifier) or English — add the language's dictation pack in System Settings"), notAuthorized: false)
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, iOS 16.0, *) { request.addsPunctuation = true }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var text: String?; var error: Error?; var finished = false }
        let box = Box()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                box.text = result.bestTranscription.formattedString
                if result.isFinal, !box.finished { box.finished = true; done.signal() }
            }
            if let error, !box.finished {
                box.error = error; box.finished = true; done.signal()
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return Transcript(text: box.text, locale: recognizer.locale.identifier,
                              failure: String(localized: "recognition did not finish within \(Int(timeout / 60)) minutes"), notAuthorized: false)
        }
        if let error = box.error, box.text == nil {
            return Transcript(text: nil, locale: recognizer.locale.identifier, failure: error.localizedDescription, notAuthorized: false)
        }
        return Transcript(text: box.text, locale: recognizer.locale.identifier, failure: nil, notAuthorized: false)
    }

    /// The person's language first, then English, then any installed
    /// on-device model — never a recogniser that would need the network.
    static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        var candidates = [Locale.current, Locale(identifier: "en-US")]
        candidates += SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
        var seen = Set<String>()
        for locale in candidates where seen.insert(locale.identifier).inserted {
            if let r = SFSpeechRecognizer(locale: locale), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }

    /// Current status without prompting.
    static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    /// IPAD-07: when the permission prompt may appear. Never at launch (the
    /// capability's state is pushed then, before the person has done anything);
    /// only when the person turns the switch on, or when a recording is about
    /// to be recognised with the switch on — and only while undetermined.
    enum AuthorizationTrigger: Sendable { case launchWiring, personTurnedSwitchOn, recordingAboutToBeRecognised }

    static func shouldRequestAuthorization(trigger: AuthorizationTrigger, switchOn: Bool,
                                           status: SFSpeechRecognizerAuthorizationStatus) -> Bool {
        guard switchOn, status == .notDetermined else { return false }
        switch trigger {
        case .launchWiring: return false
        case .personTurnedSwitchOn, .recordingAboutToBeRecognised: return true
        }
    }

    /// The system call, replaceable in tests so no prompt is shown there.
    nonisolated(unsafe) static var requestHook: (@Sendable (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void) = { completion in
        SFSpeechRecognizer.requestAuthorization { completion($0) }
    }

    /// Asks once when `shouldRequestAuthorization` allows it (the system shows the prompt).
    @MainActor
    static func requestAuthorizationIfAppropriate(trigger: AuthorizationTrigger) {
        guard shouldRequestAuthorization(trigger: trigger, switchOn: isEnabled, status: authorizationStatus()) else { return }
        requestHook { _ in }
    }

    /// Asks once (the system shows the prompt when the status is undetermined).
    @MainActor
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requestHook { continuation.resume(returning: $0) }
        }
    }

    /// Off the main thread, just before a recording is recognised with the
    /// switch on: asks once and waits for the answer (bounded, so an unanswered
    /// prompt cannot hold the indexing pass forever).
    static func requestAuthorizationBeforeRecognising() -> SFSpeechRecognizerAuthorizationStatus {
        let status = authorizationStatus()
        guard shouldRequestAuthorization(trigger: .recordingAboutToBeRecognised, switchOn: isEnabled, status: status) else { return status }
        let answered = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var status: SFSpeechRecognizerAuthorizationStatus = .notDetermined }
        let box = Box()
        requestHook { box.status = $0; answered.signal() }
        _ = answered.wait(timeout: .now() + 120)
        return box.status
    }
}

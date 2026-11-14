//
//  EmailStore+ArchiveCore.swift
//  maxmailin
//
//  C-1: the legacy SwiftData store's conformance to ArchiveCore's store
//  protocol lives on the app side of the boundary. EmailStore already
//  exposes exactly this surface (its actor-isolated synchronous methods
//  witness the async requirements).
//

import Foundation
@testable import ArchiveCore

extension EmailStore: EmailArchiveStore {}

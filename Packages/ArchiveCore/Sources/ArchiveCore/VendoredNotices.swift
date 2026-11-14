//
//  VendoredNotices.swift
//  ArchiveCore
//
//  The licence notices of third-party code compiled into ArchiveCore, for the
//  app's Third-Party Notices screen. BSD-2-Clause clause 2 asks that a binary
//  distribution reproduce the notice in its documentation. Legal text: kept
//  in English, verbatim (a test holds it to the vendored COPYING file).
//

import Foundation

enum VendoredNotices {
    /// libarchive 3.8.11 — the RAR 1.5–4.x and RAR 5.0 readers (CLibArchiveRAR).
    static let libarchive = """
    libarchive 3.8.11 (RAR 1.5–4.x and RAR 5.0 readers) — https://www.libarchive.org

    The libarchive distribution as a whole is Copyright by Tim Kientzle. The RAR readers are
    Copyright (c) 2003-2007 Tim Kientzle, Copyright (c) 2011 Andres Mejia (RAR 1.5–4.x) and
    Copyright (c) 2018 Grzegorz Antoniak (RAR 5.0); other contributors as named in each file.
    PPMd var.H by Dmitry Shkarin and Igor Pavlov (public domain). BLAKE2 reference code
    Copyright 2012 Samuel Neves (used under CC0 1.0).

    Copyright (c) 2003-2018 <author(s)>
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer
       in this position and unchanged.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
    IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
    OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
    IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
    NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
    THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """

    /// Every notice, in the order a notices screen should show them.
    static let all: [String] = [libarchive]
}

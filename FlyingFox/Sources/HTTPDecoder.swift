//
//  HTTPDecoder.swift
//  FlyingFox
//
//  Created by Simon Whitty on 13/02/2022.
//  Copyright © 2022 Simon Whitty. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/swhitty/FlyingFox
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import FlyingSocks
import Foundation

struct HTTPDecoder {

    static func decodeRequest<S>(from bytes: S) async throws -> HTTPRequest where S: AsyncChunkedSequence, S.Element == UInt8 {
        let status = try await bytes.lines.takeNext()
        let comps = status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard comps.count == 3 else {
            throw Error("No HTTP Method")
        }

        let method = HTTPMethod(String(comps[0]))
        let version = HTTPVersion(String(comps[2]))
        let (path, query) = Self.readComponents(from: String(comps[1]))

        let headers = try await Self.readHeaders(from: bytes)
        let body = try await HTTPDecoder.readBody(from: bytes, length: headers[.contentLength])

        return HTTPRequest(
            method: method,
            version: version,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    static func decodeResponse<S>(from bytes: S) async throws -> HTTPResponse where S: AsyncChunkedSequence, S.Element == UInt8 {
        let comps = try await bytes.lines.takeNext()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard comps.count == 3,
              let code = Int(comps[1]) else {
            throw Error("Invalid Status Line")
        }

        let version = HTTPVersion(String(comps[0]))
        let statusCode = HTTPStatusCode(code, phrase: String(comps[2]))

        let headers = try await Self.readHeaders(from: bytes)
        let body = try await HTTPDecoder.readBody(from: bytes, length: headers[.contentLength])

        return HTTPResponse(
            version: version,
            statusCode: statusCode,
            headers: headers,
            body: try await body.get()
        )
    }

    static func readComponents(from target: String) -> (path: String, query: [HTTPRequest.QueryItem]) {
        makeComponents(from: URLComponents(string: target))
    }

    static func makeComponents(from comps: URLComponents?) -> (path: String, query: [HTTPRequest.QueryItem]) {
        let path = (comps?.path).flatMap { URL(string: $0)?.standardized.path } ?? ""
        let query = comps?.queryItems?.map {
            HTTPRequest.QueryItem(name: $0.name, value: $0.value ?? "")
        }
        return (path, query ?? [])
    }

    @Sendable
    static func readHeader(from line: String) -> (header: HTTPHeader, value: String)? {
        let comps = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard comps.count > 1 else { return nil }
        let name = comps[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = comps[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return (HTTPHeader(name), value)
    }

    static func readHeaders<S: AsyncChunkedSequence>(from bytes: S) async throws -> [HTTPHeader : String] where S.Element == UInt8 {
        try await bytes
            .lines
            .prefix { $0 != "\r" && $0 != "" }
            .compactMap(Self.readHeader)
            .reduce(into: [HTTPHeader: String]()) { $0[$1.header] = $1.value }
    }

    static func readBody<S: AsyncChunkedSequence>(from bytes: S, length: String?, maxSizeForComplete: Int = 10_485_760) async throws -> HTTPBodySequence where S.Element == UInt8 {
        guard let length = length.flatMap(Int.init) else {
            return HTTPBodySequence(data: Data())
        }

        if length <= maxSizeForComplete {
            return try await HTTPBodySequence(data: makeBodyData(from: bytes, length: length))
        } else {
            return HTTPBodySequence(from: bytes, count: length, chunkSize: 4096)
        }
    }

    static func makeBodyData<S: AsyncChunkedSequence>(from bytes: S, length: Int) async throws -> Data where S.Element == UInt8 {
        var iterator = bytes.makeAsyncIterator()
        guard let buffer = try await iterator.nextChunk(count: length) else {
            throw Error("AsyncChunkedSequence prematurely ended")
        }

        return Data(buffer)
    }
}

extension HTTPDecoder {

    struct Error: LocalizedError {
        var errorDescription: String?

        init(_ description: String) {
            self.errorDescription = description
        }
    }
}

extension AsyncSequence where Element == UInt8 {

    // some AsyncSequence<String>
    var lines: AsyncThrowingMapSequence<CollectUntil<Self>, String> {
        collectStrings(separatedBy: "\n")
    }
}

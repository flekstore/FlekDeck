//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/22.
//

import SwiftUI

public final class DownloadHelper : ObservableObject {
    @Published var downloadProgress : Float = 0.0
    @Published var downloadedSize : Int64 = 0
    @Published var totalSize : Int64 = 0
    @Published var isDownloading = false
    @Published var cancelled = false
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: UnsafeContinuation<(), Never>?
    
    func download(url: URL, to: URL) async throws {
        var ansError: Error? = nil

        await MainActor.run {
            cancelled = false
            
            downloadProgress = 0.0
            downloadedSize = 0
            totalSize = 0
            
            isDownloading = true
        }
        
        await withUnsafeContinuation { c in
            continuation = c
            
            let session = URLSession(configuration: .default, delegate: DownloadDelegate(progressCallback: { progress, downloaded, total in
                Task{ await MainActor.run {
                    self.downloadProgress = progress
                    self.downloadedSize = downloaded
                    self.totalSize = total
                }}
            }, completeCallback: {tempFileURL, error in
                Task{ await MainActor.run {
                    self.isDownloading = false
                }}
                if let error {
                    print(error)
                    ansError = error
                }
                if let tempFileURL {
                    do {
                        let fm = FileManager.default
                        try fm.moveItem(at: tempFileURL, to: to)
                    } catch {
                        ansError = error
                    }
                }
                if self.continuation != nil {
                    self.continuation = nil
                    c.resume()
                }

            }), delegateQueue: .main)

            downloadTask = session.downloadTask(with: url)
            downloadTask?.resume()
        }
        if let ansError {
            throw ansError
        }
    }
    
    func cancel() {
        if let c = continuation {
            continuation = nil
            c.resume()
        }
        cancelled = true
        downloadTask?.cancel()
        isDownloading = false
    }
}


class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressCallback: (Float, Int64, Int64) -> Void
    let completeCallback: (URL?, Error?) -> Void

    /// URLSession reports every chunk it writes, a few hundred times a second on
    /// a fast connection, and each report costs the main thread several hops.
    /// Nothing that shows the progress needs it more often than this.
    private static let reportInterval: TimeInterval = 0.1
    private var lastReport: TimeInterval = 0

    init(progressCallback: @escaping (Float, Int64, Int64) -> Void,
         completeCallback: @escaping (URL?, Error?) -> Void) {
        self.progressCallback = progressCallback
        self.completeCallback = completeCallback
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        let finished = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard finished || now - lastReport >= Self.reportInterval else { return }
        lastReport = now
        // -1 (NSURLSessionTransferSizeUnknown) when the server sends no length;
        // dividing by it made progress negative.
        let progress = totalBytesExpectedToWrite > 0 ? Float(totalBytesWritten) / Float(totalBytesExpectedToWrite) : 0
        progressCallback(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode

            if (200...299).contains(statusCode) {
                completeCallback(location, nil)
            } else {
                completeCallback(nil, NSError(domain: "", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error: \(statusCode)"]))
            }
        } else {
            completeCallback(nil, NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completeCallback(nil, error)
        }
    }
}



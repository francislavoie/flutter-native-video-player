import AVFoundation
import Foundation

/// Handles DRM (Digital Rights Management) for protected content playback
/// Supports FairPlay Streaming and AES-128 (Standard HLS Encryption)
class VideoPlayerDrmHandler: NSObject {
    private var contentKeySession: AVContentKeySession?
    private var drmConfig: [String: Any]
    private var certificateData: Data?
    private var certificateUrl: URL?
    private var licenseUrl: URL?
    private var licenseHeaders: [String: String]?
    
    init(drmConfig: [String: Any]) {
        self.drmConfig = drmConfig
        
        // Extract configuration values
        if let licenseUrlString = drmConfig["licenseUrl"] as? String {
            self.licenseUrl = URL(string: licenseUrlString)
        }
        
        if let certificateUrlString = drmConfig["certificateUrl"] as? String {
            self.certificateUrl = URL(string: certificateUrlString)
        }
        
        if let headers = drmConfig["headers"] as? [String: String] {
            self.licenseHeaders = headers
        }
        
        super.init()
    }
    
    /// Sets up DRM for the given asset
    /// - Parameters:
    ///   - asset: The AVURLAsset to configure DRM for
    ///   - completion: Completion handler called when setup is complete
    func setupDRM(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let drmType = drmConfig["type"] as? String else {
            completion(false, NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "DRM type not specified"]))
            return
        }
        
        let drmTypeLower = drmType.lowercased()
        
        // For AES-128 (standard HLS encryption), headers passed to AVURLAsset should be sufficient
        // AVPlayer will automatically handle key requests for standard HLS encryption
        if drmTypeLower == "aes-128" {
            completion(true, nil)
            return
        }
        
        // For FairPlay, we need to set up AVContentKeySession
        if drmTypeLower == "fairplay" {
            setupFairPlay(asset: asset, completion: completion)
        } else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported DRM type: \(drmType)"])
            completion(false, error)
        }
    }
    
    /// Sets up FairPlay DRM
    private func setupFairPlay(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let licenseUrl = licenseUrl else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "License URL is required for FairPlay"])
            completion(false, error)
            return
        }
        
        
        // Create content key session
        contentKeySession = AVContentKeySession(keySystem: AVContentKeySystem.fairPlayStreaming)
        
        // Set delegate and queue
        let delegateQueue = DispatchQueue(label: "com.better_native_video_player.drm")
        contentKeySession?.setDelegate(self, queue: delegateQueue)
        
        // Add asset to content key session
        contentKeySession?.addContentKeyRecipient(asset)
        
        // Fetch certificate if URL is provided
        if let certificateUrl = certificateUrl {
            fetchCertificate(url: certificateUrl) { [weak self] success, error in
                if success {
                    completion(true, nil)
                } else {
                    completion(false, error)
                }
            }
        } else {
            // No certificate URL provided - FairPlay will use default certificate
            completion(true, nil)
        }
    }
    
    /// Fetches the FairPlay application certificate
    private func fetchCertificate(url: URL, completion: @escaping (Bool, Error?) -> Void) {
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Add custom headers if provided
        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                completion(false, error)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch certificate: Invalid response"])
                completion(false, error)
                return
            }
            
            guard let data = data else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch certificate: No data"])
                completion(false, error)
                return
            }
            
            self.certificateData = data
            completion(true, nil)
        }
        
        task.resume()
    }
    
    /// Cleans up DRM resources
    func cleanup() {
        // Note: We can't remove specific assets from the session without tracking them
        // The session will be cleaned up when deallocated
        contentKeySession = nil
        certificateData = nil
    }
}

// MARK: - AVContentKeySessionDelegate

extension VideoPlayerDrmHandler: AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        
        guard let licenseUrl = licenseUrl else {
            keyRequest.processContentKeyResponseError(NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "License URL not configured"]))
            return
        }
        
        // Get the initialization data (SPC - Server Playback Context) from the key request
        // For FairPlay, this is the data that needs to be sent to the license server
        guard let initializationData = keyRequest.initializationData else {
            keyRequest.processContentKeyResponseError(NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "No initialization data"]))
            return
        }
        
        // For FairPlay, the initialization data (SPC) may need to be wrapped with the certificate
        // However, AVContentKeySession typically handles this automatically
        // If manual wrapping is needed, it would be done here
        var requestData = initializationData
        
        // Create license request
        var request = URLRequest(url: licenseUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData
        
        // Add custom headers if provided
        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        
        // Send license request
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                keyRequest.processContentKeyResponseError(error)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "License request failed with status code: \(statusCode)"])
                keyRequest.processContentKeyResponseError(error)
                return
            }
            
            guard let data = data else {
                let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data in license response"])
                keyRequest.processContentKeyResponseError(error)
                return
            }
            
            // Process the license response
            do {
                let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: data)
                keyRequest.processContentKeyResponse(keyResponse)
            } catch {
                keyRequest.processContentKeyResponseError(error)
            }
        }
        
        task.resume()
    }
    
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        // Handle persistable content key requests (for offline playback)
        // For now, we'll handle it the same way as regular key requests
        contentKeySession(session, didProvide: keyRequest as AVContentKeyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        // Handle renewing content key requests
        contentKeySession(session, didProvide: keyRequest)
    }
    
    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest, reason retryReason: String) -> Bool {
        // Retry once for network errors
        return retryReason.contains("network") || retryReason.contains("timeout")
    }
}



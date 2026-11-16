#if DEBUG
  import AppKit
  import Darwin
  import Foundation

  // Explicit debug-only controller over inherited anonymous pipes, never HTTP.
  // It runs the exact app model, service actor, Keychain store and native listener.
  // The QR bundle goes only to a dedicated pipe, not stdout, logs or a file.
  @MainActor
  enum NativeIntegrationSession {
    static func run(replyFD: Int32, memoryOnly: Bool = false) async {
      var descriptor = stat()
      guard fstat(replyFD, &descriptor) == 0, descriptor.st_mode & S_IFMT == S_IFIFO else {
        exit(2)
      }
      let reply = FileHandle(fileDescriptor: replyFD, closeOnDealloc: false)
      let pasteboard = NSPasteboard.withUniqueName()
      let model: AppModel
      if memoryOnly {
        let memory = MemoryStore()
        // Explicit test-only random identity; never reads/writes the real Keychain.
        guard (try? Endpoint(memory)) != nil else {
          pasteboard.releaseGlobally()
          exit(2)
        }
        model = AppModel(receiver: ReceiverCoordinator(store: memory), pasteboard: pasteboard)
      } else {
        model = AppModel(pasteboard: pasteboard)
      }
      model.beginSession()
      await model.refreshAddresses()
      while let line = await nextLine() {
        do {
          let command = try StrictJSON.decodeObject(Data(line.utf8))
          let op = try text(command, "op")
          var response: Object = ["ok": true]
          switch op {
          case "ready":
            for _ in 0..<300 {
              if model.receiverStatus == .listening { break }
              if case .failed = model.receiverStatus { break }
              if model.needsIdentityAccess { break }
              try await Task.sleep(for: .milliseconds(100))
            }
            guard model.receiverStatus == .listening else { throw Rejected.state }
            response["fingerprint"] = model.savedIdentity?.fingerprint
            response["highest"] = model.savedIdentity?.highestCounter
          case "new_pairing":
            guard try text(command, "host") == "10.0.2.2" else { throw Rejected.invalid }
            model.selectedAddressID = LocalAddress.emulator.id
            await model.createPairing()
            guard let code = model.pairingCode else { throw Rejected.state }
            response["bundle"] = code.bundle
          case "authorize":
            await model.authorizeIdentity()
            for _ in 0..<100 {
              if model.receiverStatus == .listening { break }
              try await Task.sleep(for: .milliseconds(100))
            }
            guard model.receiverStatus == .listening else { throw Rejected.state }
          case "stats":
            response["paired"] = model.verifiedCount
            response["duplicates"] = model.duplicateCount
            response["comparisons"] = model.comparisons.count
            response["rejected"] = model.rejectedCount
            response["fingerprint"] = model.savedIdentity?.fingerprint
            response["highest"] = model.savedIdentity?.highestCounter
            response["qr_visible"] = model.pairingCode != nil
            response["listening"] = model.receiverStatus == .listening
          case "pause":
            await model.sleep()
            for _ in 0..<20 {
              if model.receiverStatus == .paused { break }
              try await Task.sleep(for: .milliseconds(50))
            }
          case "resume": await model.wake()
          case "quit":
            await model.shutdown()
            try reply.write(contentsOf: Data("{\"ok\":true}\n".utf8))
            pasteboard.releaseGlobally()
            exit(0)
          default: throw Rejected.invalid
          }
          try reply.write(contentsOf: try json(response) + Data([10]))
        } catch {
          try? reply.write(
            contentsOf: try json(["ok": false, "status": model.receiverStatus.title]) + Data([10]))
        }
      }
      await model.shutdown()
      pasteboard.releaseGlobally()
      exit(0)
    }
    private static func nextLine() async -> String? {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: readLine()) }
      }
    }
  }
#endif

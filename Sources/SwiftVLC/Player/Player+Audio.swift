import CLibVLC
import Darwin

/// Audio output, devices, equalizer, stereo/mix mode.
extension Player {
  // MARK: - Equalizer

  /// The legacy mutable equalizer attachment. Set `nil` to disable.
  ///
  /// Subsequent mutations on the assigned `Equalizer` are re-applied
  /// to the audio output automatically through an installed change
  /// handler. libVLC copies settings on each
  /// `libvlc_media_player_set_equalizer` call and does not retain the
  /// reference.
  /// This API does not check native results. Checked snapshot applications
  /// use ``applyEqualizer(_:)`` and do not populate this property.
  public var equalizer: Equalizer? {
    get {
      access(keyPath: \.equalizer)
      return _equalizer
    }
    set {
      // Shutdown may notify synchronous observers before native teardown. A
      // reentrant legacy write must not reattach to that retiring handle.
      guard !isShutdown else { return }
      // Retire checked authority before the compatible unchecked write.
      _equalizerApplication = .legacyUnverified
      _equalizer?.onChange = nil
      _equalizer = newValue
      libvlc_media_player_set_equalizer(pointer, newValue?.pointer)
      newValue?.onChange = { [weak self, weak newValue] in
        guard let self, let newValue, !isShutdown, _equalizer === newValue else { return }
        _equalizerApplication = .legacyUnverified
        libvlc_media_player_set_equalizer(pointer, newValue.pointer)
        notifyEqualizerApplication()
      }
      notifyEqualizerAttachment()
      notifyEqualizerApplication()
    }
  }

  /// Current native-request result. This is not audible-output evidence.
  public var equalizerApplication: EqualizerApplication {
    access(keyPath: \.equalizerApplication)
    return _equalizerApplication
  }

  /// Applies all immutable native values as one checked settings request.
  /// Pass `nil` for real native bypass. No mutable on-change handler is installed.
  ///
  /// Allocation, count and every native setter are checked on a private staging
  /// handle before application. Failure preserves the old mutable attachment and
  /// copied accepted request. Success detaches the mutable attachment, if any.
  /// The native return code certifies request acceptance, not filter/output health.
  @discardableResult
  public func applyEqualizer(_ snapshot: EqualizerSnapshot?) throws(VLCError) -> EqualizerApplyReceipt {
    guard !isShutdown else { throw .invalidState("Player is shut down") }
    let attempt = try nextEqualizerRevision()
    let currentPointer = pointer
    let previousApplication = _equalizerApplication
    let lastAccepted = _equalizerApplication.lastAcceptedReceipt
    do {
      try Self.applyNativeEqualizer(snapshot, to: currentPointer)
    } catch {
      if
        !isShutdown, pointer == currentPointer, _equalizerRevision == attempt,
        _equalizerApplication == previousApplication {
        _equalizerApplication = .failed(attemptRevision: attempt, error: error, lastAccepted: lastAccepted)
        notifyEqualizerApplication()
      }
      throw error
    }
    guard
      !isShutdown, pointer == currentPointer, _equalizerRevision == attempt,
      _equalizerApplication == previousApplication else {
      throw .invalidState("Equalizer application no longer belongs to the current player")
    }
    _equalizer?.onChange = nil
    _equalizer = nil
    let receipt = EqualizerApplyReceipt(revision: attempt, snapshot: snapshot)
    _equalizerApplication = .accepted(receipt)
    notifyEqualizerAttachment()
    notifyEqualizerApplication()
    return receipt
  }

  /// One sequence for attempts and successful native-handle rebasing. Exhaustion
  /// rejects further checked work rather than making an old receipt current again.
  func nextEqualizerRevision() throws(VLCError) -> UInt64 {
    guard _equalizerRevision < UInt64.max else {
      throw .invalidState("Equalizer revision exhausted")
    }
    _equalizerRevision += 1
    return _equalizerRevision
  }

  static func applyNativeEqualizer(
    _ snapshot: EqualizerSnapshot?,
    to nativePlayer: OpaquePointer
  ) throws(VLCError) {
    let staged: Equalizer?
    if let snapshot {
      staged = try Equalizer(snapshot: snapshot)
    } else {
      staged = nil
    }
    let result = libvlc_media_player_set_equalizer(nativePlayer, staged?.pointer)
    withExtendedLifetime(staged) {}
    guard result == 0 else {
      throw .operationFailed("Apply equalizer")
    }
  }

  func notifyEqualizerAttachment() {
    withMutation(keyPath: \.equalizer) {}
  }

  func notifyEqualizerApplication() {
    // State is coherent before any synchronous observation callback can reenter.
    // Notification is the last effect of each application/publication path.
    withMutation(keyPath: \.equalizerApplication) {}
  }

  // MARK: - Audio Output & Devices

  /// Sets the audio output module.
  /// - Throws: `VLCError.operationFailed` if the module cannot be set.
  public func setAudioOutput(_ name: String) throws(VLCError) {
    guard libvlc_audio_output_set(pointer, name) == 0 else {
      throw .operationFailed("Set audio output '\(name)'")
    }
    _audioOutputModule = name
  }

  /// Lists available audio output devices for the current output.
  public func audioDevices() -> [AudioDevice] {
    guard let list = libvlc_audio_output_device_enum(pointer) else { return [] }
    defer { libvlc_audio_output_device_list_release(list) }

    return sequence(first: list, next: { $0.pointee.p_next }).map { node in
      AudioDevice(
        deviceId: String(cString: node.pointee.psz_device),
        deviceDescription: String(cString: node.pointee.psz_description)
      )
    }
  }

  /// Sets the audio output device.
  /// - Throws: `VLCError.operationFailed` if the device cannot be set.
  public func setAudioDevice(_ deviceId: String) throws(VLCError) {
    guard libvlc_audio_output_device_set(pointer, deviceId) == 0 else {
      throw .operationFailed("Set audio device '\(deviceId)'")
    }
    _audioOutputDevice = deviceId
  }

  /// Current audio output device identifier.
  public var currentAudioDevice: String? {
    access(keyPath: \.currentAudioDevice)
    guard let cstr = libvlc_audio_output_device_get(pointer) else { return nil }
    defer { free(cstr) }
    return String(cString: cstr)
  }

  // MARK: - Stereo & Mix Mode

  /// Audio stereo mode.
  public var stereoMode: StereoMode {
    get {
      access(keyPath: \.stereoMode)
      return StereoMode(from: libvlc_audio_get_stereomode(pointer))
    }
    set {
      _ = withMutation(keyPath: \.stereoMode) {
        libvlc_audio_set_stereomode(pointer, newValue.cValue)
      }
    }
  }

  /// Audio mix/channel mode.
  public var mixMode: MixMode {
    get {
      access(keyPath: \.mixMode)
      return MixMode(from: libvlc_audio_get_mixmode(pointer))
    }
    set {
      _ = withMutation(keyPath: \.mixMode) {
        libvlc_audio_set_mixmode(pointer, newValue.cValue)
      }
    }
  }
}

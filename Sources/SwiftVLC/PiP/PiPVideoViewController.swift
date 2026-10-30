#if os(iOS)
import UIKit

/// Owns a native video drawable and its Picture in Picture controller.
///
/// Retain and move this controller when presenting the same playback in another
/// container. Its drawable survives parent, window and appearance changes.
@MainActor
public final class PiPVideoViewController: UIViewController {
  private let nativeHostView: IOSNativePiPHostView

  /// Controls PiP for this controller's native drawable without installing
  /// a second video-output callback path.
  public let pictureInPictureController: PiPController

  /// Creates a stable native video host for the supplied player.
  ///
  /// Policy values are captured for this host's lifetime, as in ``PiPVideoView``.
  /// Set `managesAudioSession` to `false` when the containing app owns its session.
  public init(
    _ player: Player,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true
  ) {
    let host = IOSNativePiPHostView(
      startsAutomaticallyFromInline: startsAutomaticallyFromInline
    )
    nativeHostView = host
    host.attach(to: player)
    pictureInPictureController = PiPController(
      player: player,
      nativeBackend: host.nativePiPBackend,
      startsAutomaticallyFromInline: startsAutomaticallyFromInline,
      managesAudioSession: managesAudioSession
    )
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder _: NSCoder) {
    fatalError()
  }

  public override func loadView() {
    view = nativeHostView
  }

  /// Permanently retires this host. Do not call for a presentation-only move.
  /// Repeated retirement is harmless, and cannot clear a newer drawable owner.
  public func invalidate() {
    nativeHostView.detach()
  }

  isolated deinit {
    nativeHostView.detach()
  }
}
#endif

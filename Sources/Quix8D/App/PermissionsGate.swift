import Foundation

/// 14.4 is the product floor; ProcessTapCapture's 14.2 is the SDK floor.
/// No TCC pre-flight: tap creation succeeds regardless of consent. The real
/// gate is the IO proc start, which can block on the prompt, so call it
/// off the main thread.
enum PermissionsGate {
    static let minimumVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)

    static func isOSVersionSupported(_ version: OperatingSystemVersion) -> Bool {
        if version.majorVersion != minimumVersion.majorVersion {
            return version.majorVersion > minimumVersion.majorVersion
        }
        return version.minorVersion >= minimumVersion.minorVersion
    }
}

import Foundation

/// Discord's "Potentially Dangerous Download" rule: a link whose path ends in
/// a file with one of these extensions asks before it downloads. Only the URL
/// counts, never the file's content type, and the same list applies on every
/// platform.
nonisolated enum DangerousDownloadPolicy {
    private static let extensions: Set<String> = [
        "7z", "ade", "adp", "arj", "apk", "appimage", "application", "appx", "appxbundle", "asx", "bas", "bat",
        "cab", "cer", "chm", "cmd", "cnt", "cpl", "crt", "csh", "deb", "der", "diagcab", "dll", "dmg", "docm",
        "dotm", "ex", "ex_", "exe", "flatpak", "flatpakref", "fxp", "gadget", "grp", "gz", "hlp", "hpj", "hta",
        "htc", "inf", "ins", "ipa", "iso", "isp", "its", "jar", "jnlp", "jse", "ksh", "lib", "lnk", "mad", "maf",
        "mag", "mam", "maq", "mar", "mas", "mat", "mau", "mav", "maw", "mcf", "mda", "mdb", "mde", "mdt", "mdw",
        "mdz", "msc", "msh", "msh1", "msh1xml", "msh2", "msh2xml", "mshxml", "msi", "msix", "msixbundle", "msp",
        "mst", "msu", "nsh", "ops", "osd", "pcd", "pif", "pkg", "pl", "plg", "potm", "ppam", "ppsm", "pptm", "prf",
        "prg", "printerexport", "ps1", "ps1xml", "ps2", "ps2xml", "psc1", "psc2", "psd1", "psdm1", "pst", "py",
        "pyc", "pyo", "pyw", "pyz", "pyzw", "rar", "reg", "rpm", "scf", "scr", "sct", "shb", "shs", "sldm", "snap",
        "sys", "theme", "tmp", "url", "vb", "vbe", "vbp", "vbs", "vhd", "vhdx", "vsmacros", "vsw", "vxd", "webpnp",
        "ws", "wsc", "wsf", "wsh", "xbap", "xlam", "xll", "xlsm", "xltm", "xnk", "z", "zip",
    ]

    /// On these code hosts only release and download paths count, so browsing
    /// a repository's source files does not warn.
    private static func downloadPath(on host: String) -> Regex<Substring>? {
        switch host {
        case "github.com": /\/releases\S*\/download|archive\/refs\/\S*|\/i\/raw\/i\/\S*|\/user-attachments\S*/
        case "bitbucket.org", "gitlab.com": /\/downloads\S*\/[^\/]*/
        default: nil
        }
    }

    static func isPotentiallyDangerous(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        let path = url.path(percentEncoded: true)
        if let downloadPath = downloadPath(on: host), !path.contains(downloadPath) { return false }
        // The file is the last segment that is not empty or `.`; each `..`
        // after it steps back over one segment, as Discord counts them.
        let segments = (path.removingPercentEncoding ?? path).split(separator: "/", omittingEmptySubsequences: false)
        var parents = 0
        for index in segments.indices.reversed() {
            switch segments[index] {
            case "", ".": continue
            case "..": parents += 1
            default:
                guard parents <= index else { return false }
                let filename = segments[index - parents]
                guard let dot = filename.lastIndex(of: ".") else { return false }
                return extensions.contains(filename[filename.index(after: dot)...].lowercased())
            }
        }
        return false
    }
}

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons

// Icon lookup shared by the open-windows and minimized icons. One instance
// lives in Workspaces.qml; both parts call iconFor(toplevel).
//
// The matching from window to desktop entry is adapted from Spaces by Tornike
// Gomareli (github.com/tornikegomareli/omarchy-spaces, MIT): app id candidates
// including the tail of a reverse-DNS id, Quickshell's heuristic lookup,
// Chromium-family web apps by host, and windows the shell itself hosts (all
// "org.quickshell") told apart by title. Icon names resolve through an index
// of the app icons on disk (scalable first, then the largest raster), as Spaces
// does: the shell's own index isn't reachable from a third-party widget, and
// the theme lookup misses icons such as a 1024px PNG under hicolor.
QtObject {
  id: root

  property QtObject bar: null

  property var cache: ({})
  property int revision: 0
  property var iconIndex: ({})
  property var pendingIndex: ({})

  function appIdOf(top) {
    if (top && top.wayland && top.wayland.appId) return String(top.wayland.appId)
    var ipc = top && top.lastIpcObject ? top.lastIpcObject : {}
    return String(ipc["class"] || ipc.initialClass || "")
  }

  function appIdCandidates(appId) {
    var id = String(appId || "")
    if (id === "") return []
    var out = [id]
    function add(v) { if (v && out.indexOf(v) === -1) out.push(v) }
    add(id.toLowerCase())
    if (id.toLowerCase().slice(-8) === ".desktop") add(id.slice(0, -8))
    var dot = id.lastIndexOf(".")
    if (dot > 0 && dot < id.length - 1) {
      add(id.slice(dot + 1))
      add(id.slice(dot + 1).toLowerCase())
    }
    return out
  }

  // Chromium-family --app windows use classes like
  // "chrome-web.whatsapp.com__-Default" or "brave-app.hey.com__-Profile_1".
  function webAppHost(appId) {
    var m = /^(?:chrome|chromium|brave|msedge|vivaldi|helium|opera)-([^_]+?)(?:__|_).*-(?:Default|Profile_\d+)$/i.exec(String(appId || ""))
    return m ? m[1] : ""
  }

  function findDesktopEntry(appId) {
    if (!appId) return null
    var candidates = root.appIdCandidates(appId)
    for (var c = 0; c < candidates.length; c++) {
      var byId = DesktopEntries.byId(candidates[c])
      if (byId) return byId
    }
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry

    var host = root.webAppHost(appId)
    if (host === "") return null
    var apps = DesktopEntries.applications.values
    for (var i = 0; i < apps.length; i++) {
      var exec = String(apps[i].execString || "")
      if (exec.indexOf("//" + host) !== -1) return apps[i]
    }
    return null
  }

  function iconPathScore(path) {
    var p = String(path || "")
    if (/\.svg$/i.test(p)) return 100000
    var m = /\/(\d+)x\d+\//.exec(p)
    if (m) return Number(m[1])
    return /\/pixmaps\//.test(p) ? 48 : 1
  }

  function indexLine(line) {
    var path = String(line || "").trim()
    if (path === "") return
    var file = path.slice(path.lastIndexOf("/") + 1)
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    var existing = root.pendingIndex[name]
    if (!existing || root.iconPathScore(path) > root.iconPathScore(existing)) root.pendingIndex[name] = path
  }

  function iconUrl(name) {
    var value = String(name || "")
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var indexed = value !== "" ? root.iconIndex[value] : ""
    if (indexed) return Util.fileUrl(indexed)
    var themed = value !== "" ? Quickshell.iconPath(value, true) : ""
    return themed || Quickshell.iconPath("application-x-executable", true)
  }

  // Cached per app id; windows the shell hosts cache per title instead, since
  // the title, not the id, names the app inside (e.g. "Omamail").
  function iconFor(top) {
    root.revision
    var appId = root.appIdOf(top)
    var title = String(top && top.title || "")
    var key = appId.toLowerCase()
    var shellHosted = key === "org.quickshell" && title !== ""
    var cacheKey = shellHosted ? key + "\u0000" + title.toLowerCase() : key
    var cached = root.cache[cacheKey]
    if (cached) return cached

    var entry = root.findDesktopEntry(appId)
    if (shellHosted) {
      var titled = root.findDesktopEntry(title)
      if (titled && !titled.noDisplay) entry = titled
    }
    var source = root.iconUrl(entry && entry.icon ? entry.icon : appId)
    if (appId !== "") root.cache[cacheKey] = source
    return source
  }

  function invalidate() {
    root.cache = ({})
    root.revision++
  }

  property Connections entriesWatch: Connections {
    target: DesktopEntries
    function onApplicationsChanged() { debounce.restart() }
  }

  property Timer debounce: Timer {
    id: debounce
    interval: 1500
    onTriggered: scan.running = true
  }

  // Non-login shell on purpose: a login shell can touch ~/.local/share and
  // retrigger desktop-entry watchers.
  property Process scan: Process {
    id: scan
    command: ["bash", "-c", [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for base in $dirs; do [[ -d $base ]] && find "$base" -path "*/apps/*" \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null; done;',
      'find /usr/share/pixmaps -maxdepth 1 \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null'
    ].join(" ")]
    stdout: SplitParser { onRead: function(line) { root.indexLine(line) } }
    onStarted: root.pendingIndex = ({})
    onExited: {
      root.iconIndex = root.pendingIndex
      root.invalidate()
    }
  }

  Component.onCompleted: {
    // Touching the list starts Quickshell's desktop-entry scan.
    DesktopEntries.applications.values
    scan.running = true
  }
}

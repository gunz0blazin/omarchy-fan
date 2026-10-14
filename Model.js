var profiles = ["quiet", "balanced", "performance"]

function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta) {
  return clampIndex(index + delta, profiles.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function profileIcon(name) {
  if (name === "quiet") return "󰒲"
  if (name === "performance") return "󰓅"
  return "󰾅"
}

function profileHint(name) {
  if (name === "quiet") return "Fan stays off longer, runs warmer"
  if (name === "performance") return "Cooler, spins up early"
  return "Smooth curve, off below ~56°C"
}

// thinkpad_acpi levels: 0 (off) .. 7, then 8 = full speed (disengaged).
function levelFromProc(raw) {
  var s = String(raw || "").trim()
  if (s === "") return 0
  var n = Number(s)
  if (isFinite(n)) return Math.max(0, Math.min(7, n))
  if (s.indexOf("full") >= 0 || s === "disengaged") return 8
  return 0
}

function levelLabel(n) {
  n = Math.round(n)
  if (n <= 0) return "Off"
  if (n >= 8) return "Full speed"
  return "Level " + n
}

#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
project="$root/Examples/DebugDemo/DebugDemo.xcodeproj"
debug_scheme="$project/xcshareddata/xcschemes/DebugDemo.xcscheme"
release_scheme="$project/xcshareddata/xcschemes/DebugDemo-Release.xcscheme"
management="$project/xcshareddata/xcschememanagement.plist"

test -f "$release_scheme"
test -f "$management"

/usr/bin/ruby -r rexml/document - "$debug_scheme" "$release_scheme" <<'RUBY'
debug_id = "A20000000000000000000001"
release_id = "A20000000000000000000003"
debug = REXML::Document.new(File.read(ARGV[0]))
entries = {}
REXML::XPath.each(debug, "/Scheme/BuildAction/BuildActionEntries/BuildActionEntry") do |entry|
  ref = entry.elements["BuildableReference"]
  entries[ref.attributes["BlueprintIdentifier"]] = entry.attributes.to_h.transform_values(&:to_s)
end
raise unless entries[debug_id] == {
  "buildForTesting" => "YES", "buildForRunning" => "YES",
  "buildForProfiling" => "NO", "buildForArchiving" => "NO",
  "buildForAnalyzing" => "YES",
}
raise unless entries[release_id] == {
  "buildForTesting" => "NO", "buildForRunning" => "NO",
  "buildForProfiling" => "YES", "buildForArchiving" => "YES",
  "buildForAnalyzing" => "NO",
}
def attr(document, path, name)
  REXML::XPath.first(document, path).attributes[name]
end
raise unless attr(debug, "/Scheme/LaunchAction/BuildableProductRunnable/BuildableReference", "BlueprintIdentifier") == debug_id
raise unless attr(debug, "/Scheme/ProfileAction/BuildableProductRunnable/BuildableReference", "BlueprintIdentifier") == release_id
raise unless attr(debug, "/Scheme/ArchiveAction", "buildConfiguration") == "Release"
raise unless attr(debug, "/Scheme/TestAction", "buildConfiguration") == "Debug"
raise unless attr(debug, "/Scheme/AnalyzeAction", "buildConfiguration") == "Debug"

release = REXML::Document.new(File.read(ARGV[1]))
release_entries = REXML::XPath.match(release, "/Scheme/BuildAction/BuildActionEntries/BuildActionEntry")
raise unless release_entries.length == 1
raise unless release_entries[0].elements["BuildableReference"].attributes["BlueprintIdentifier"] == release_id
raise unless attr(release, "/Scheme/LaunchAction/BuildableProductRunnable/BuildableReference", "BlueprintIdentifier") == release_id
raise unless attr(release, "/Scheme/ProfileAction/BuildableProductRunnable/BuildableReference", "BlueprintIdentifier") == release_id
raise unless attr(release, "/Scheme/ArchiveAction", "buildConfiguration") == "Release"
RUBY

dry="$(make -C "$root" -n demo-release)"
grep -Fq -- '-scheme "DebugDemo-Release"' <<<"$dry"
grep -Fq -- '-configuration Release' <<<"$dry"

grep -Fq 'A20000000000000000000001' "$management"
grep -Fq 'A20000000000000000000002' "$management"
grep -Fq 'A20000000000000000000003' "$management"
grep -Fq 'SuppressBuildableAutocreation' "$management"

/usr/bin/ruby - "$project/project.pbxproj" <<'RUBY'
text = File.read(ARGV[0])
config = text.match(%r{A3000000000000000000001D /\* Debug \*/ = \{(.*?)\n\t\t\};}m)
raise unless config
raise unless config[1].include?('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "";')
RUBY

grep -Fq 'release_scheme="${IOS_DEBUG_RELEASE_SCHEME:-DebugDemo-Release}"' "$root/scripts/release-scan.sh"

echo "PASS: release-entrypoints-test"

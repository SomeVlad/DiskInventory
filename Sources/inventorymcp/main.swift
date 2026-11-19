import Foundation

let usage = """
inventorymcp — an MCP server over stdio for Disk Inventory: a full scan of every \
file and folder, kinds, search, and what can be cleaned up or moved to the cloud.

USAGE: inventorymcp [--version] [--help]
"""

let instructions = """
Disk Inventory for agents. inventory_scan reads a folder or volume completely \
(every file is kept, read in parallel), and the other tools answer from that scan: \
inventory_children walks the tree level by level, inventory_top finds the biggest \
files or folders anywhere below a folder, inventory_kinds sums space by file kind, \
inventory_search finds files by name, kind or path.

Cleanup: inventory_cleanup lists what can be removed by safety level (safe caches \
and logs, regenerable build artifacts and package caches, items to review such as \
installers and local AI models); inventory_stale lists big personal files nobody \
has opened or changed for months and the cloud folders (iCloud Drive, Google Drive) \
they could go to. Both are read-only.

The default scan is the home folder; the whole boot volume is /System/Volumes/Data. \
A scan is reused for 30 minutes; pass refresh to scan again.

Cleanup with the user: when asked what to clean, measure first, then call \
inventory_advise with every candidate, a verdict and a reason in the user's \
language. Disk Inventory shows it on its Clean Up tab, highlights it on the map, \
and the user removes what they agree with; inventory_advice reports what was \
trashed or kept. Never delete files yourself.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") {
    print("inventorymcp \(MCPInfo.version)")
    exit(0)
}
if arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(0)
}
if let unknown = arguments.first {
    FileHandle.standardError.write(Data("Unknown option \(unknown)\n\n\(usage)\n".utf8))
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

let store = ScanStore()
let server = MCPServer(tools: makeTools(store), queue: DispatchQueue(label: "inventorymcp.server"), instructions: instructions)
let reader = Thread { server.run() }
reader.name = "inventorymcp.stdin"
reader.stackSize = 1 << 20
reader.start()
dispatchMain()

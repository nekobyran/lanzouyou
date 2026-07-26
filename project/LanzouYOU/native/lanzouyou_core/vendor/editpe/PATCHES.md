# Local patch

This BSD-2-Clause `editpe 0.2.3` source is vendored so Windows version resources
use UTF-16 code-unit counts for non-ASCII values. Upstream 0.2.3 uses UTF-8 byte
lengths in `VersionInfo::build`, which corrupts following fields for Chinese app
names.

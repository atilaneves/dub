/** Standalone description cache. Unsupported inputs always use normal DUB. */
module dub.internal.describecache;

version (linux):

import core.stdc.errno;
import core.stdc.stdlib : malloc, free, getenv;
import core.stdc.string : strlen, strcmp, memcpy;
import core.sys.posix.fcntl;
import core.sys.posix.stdlib : mkstemp;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd;
import std.digest.sha : SHA256;
import std.digest.crc : CRC32;

private enum cacheFile = ".dub/describe-cache-v1.bin";
private enum ulong magic = 0x3145484341434244;
private enum size_t maxCacheSize = 64 * 1024 * 1024;

private struct Stamp {
    ulong device, inode, mode, size;
    long mtime, mnsec, ctime, cnsec;
}

private bool stamp(const(char)* path, out Stamp result) nothrow @nogc {
    stat_t s;
    if (stat(path, &s) != 0)
        return errno == ENOENT || errno == ENOTDIR;
    // druntime exposes either timespec members or separate second/nanosecond
    // fields, depending on its version, architecture and feature macros.
    static if (__traits(hasMember, stat_t, "st_mtim"))
        result = Stamp(s.st_dev, s.st_ino, s.st_mode, s.st_size,
            s.st_mtim.tv_sec, s.st_mtim.tv_nsec, s.st_ctim.tv_sec, s.st_ctim.tv_nsec);
    else
        result = Stamp(s.st_dev, s.st_ino, s.st_mode, s.st_size,
            s.st_mtime, s.st_mtimensec, s.st_ctime, s.st_ctimensec);
    return true;
}

private struct Header {
    ulong magicNumber;
    ubyte[32] key;
    ubyte[4] checksum;
    ulong count;
    ulong outputLength;
}

private bool contextKey(out ubyte[32] result) nothrow @nogc {
    SHA256 hash;
    char[4096] cwd;
    if (!getcwd(cwd.ptr, cwd.length)) return false;
    hash.put(cast(ubyte[])cwd[0 .. strlen(cwd.ptr) + 1]);
    Stamp executable;
    if (!stamp("/proc/self/exe", executable)) return false;
    hash.put((cast(ubyte*)&executable)[0 .. executable.sizeof]);
    uint[4] identity = [getuid(), geteuid(), getgid(), getegid()];
    hash.put((cast(ubyte*)identity.ptr)[0 .. identity.sizeof]);
    uint[128] groups;
    const count = getgroups(cast(int)groups.length, groups.ptr);
    if (count < 0) return false;
    hash.put((cast(const(ubyte)*)&count)[0 .. count.sizeof]);
    hash.put((cast(ubyte*)groups.ptr)[0 .. count * uint.sizeof]);
    for (size_t i; environ[i]; ++i)
        hash.put((cast(const(ubyte)*)environ[i])[0 .. strlen(environ[i]) + 1]);
    result = hash.finish();
    return true;
}

/// Called before druntime initialization; a miss must have no observable effects.
/// Returns -1 on a miss, otherwise the command's exit status.
int tryDescribeCache(int argc, char** argv) nothrow @nogc {
    if (argc != 2 || strcmp(argv[1], "describe") != 0) return -1;
    // An explicit escape hatch is also useful for comparing cached and live output.
    if (getenv("DUB_NO_DESCRIBE_CACHE")) return -1;
    ubyte[32] key;
    if (!contextKey(key)) return -1;
    const fd = open(cacheFile.ptr, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return -1;
    scope (exit) close(fd);
    stat_t st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()
        || st.st_size < Header.sizeof || st.st_size > maxCacheSize) return -1;
    auto data = cast(ubyte*)malloc(cast(size_t)st.st_size);
    if (!data) return -1;
    scope (exit) free(data);
    size_t used;
    while (used < st.st_size) {
        auto n = read(fd, data + used, cast(size_t)st.st_size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        used += n;
    }
    Header header;
    memcpy(&header, data, Header.sizeof);
    if (header.magicNumber != magic || header.key != key
        || header.outputLength > used - Header.sizeof) return -1;
    const checksum = header.checksum;
    header.checksum[] = 0;
    CRC32 hash;
    hash.put((cast(ubyte*)&header)[0 .. header.sizeof]);
    hash.put(data[Header.sizeof .. used]);
    if (hash.finish() != checksum) return -1;
    const end = used - cast(size_t)header.outputLength;
    size_t offset = Header.sizeof;
    for (ulong i; i < header.count; ++i) {
        if (offset > end || end - offset < uint.sizeof + Stamp.sizeof) return -1;
        uint length;
        Stamp expected;
        memcpy(&length, data + offset, length.sizeof);
        offset += length.sizeof;
        memcpy(&expected, data + offset, expected.sizeof);
        offset += expected.sizeof;
        if (!length || length > end - offset || data[offset + length - 1] != 0) return -1;
        // Reject interior NULs rather than validating a different path.
        if (strlen(cast(char*)data + offset) != length - 1) return -1;
        Stamp actual;
        if (!stamp(cast(char*)data + offset, actual) || actual != expected) return -1;
        offset += length;
    }
    if (offset != end) return -1;
    while (offset < used) {
        auto n = write(STDOUT_FILENO, data + offset, used - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 1;
        offset += n;
    }
    return 0;
}

private Stamp[string] inputs;
private bool active;
private bool[string] trees;
private bool[string] libraries;
private string cacheDirectory;
private Stamp cacheDirectoryStamp;
private ubyte[32] initialKey;

void startDescribeCache(string[] args) {
    import std.file : mkdirRecurse, thisExePath;
    import std.path : absolutePath;
    if (args.length != 2 || args[1] != "describe" || getenv("DUB_NO_DESCRIBE_CACHE")) return;
    try {
        mkdirRecurse(".dub");
        active = contextKey(initialKey);
        cacheDirectory = absolutePath(".dub");
        import std.string : toStringz;
        if (!stamp(cacheDirectory.toStringz, cacheDirectoryStamp)) { active = false; return; }
        describeLibraries(thisExePath());
        describeRuntimeInputs();
        describeInput("/etc/ld.so.preload");
    } catch (Exception) { active = false; }
}

private void describeRuntimeInputs() {
    import std.file : readText;
    import std.process : environment;
    import std.path : buildPath;
    import std.string : splitLines, indexOf, strip;
    import std.algorithm : startsWith;

    if (!active) return;
    if (environment.get("LOCPATH", "").length) { active = false; return; }
    // Includes the locale data and libraries mapped during runtime startup.
    // The map itself is per-process, not an input to the resulting description.
    foreach (line; readText("/proc/self/maps").splitLines()) {
        const start = line.indexOf('/');
        if (start >= 0) describeInput(line[start .. $].strip);
    }
    foreach (path; ["/etc/localtime", "/etc/timezone", "/usr/lib/locale",
        "/usr/lib/locale/locale-archive", "/usr/share/locale/locale.alias"])
        describeInput(path);
    auto timezone = environment.get("TZ", "");
    if (timezone.startsWith(":")) timezone = timezone[1 .. $];
    if (timezone.length)
        describeInput(timezone.startsWith("/") ? timezone
            : buildPath(environment.get("TZDIR", "/usr/share/zoneinfo"), timezone));
}

void cancelDescribeCache() nothrow { active = false; }

void describeInput(string path) {
    import std.path : absolutePath, dirName;
    import std.string : toStringz, fromStringz;
    import std.algorithm : startsWith;
    import core.sys.posix.stdlib : realpath;
    if (!active) return;
    try {
        path = absolutePath(path);
        while (path.length > 1 && path[$ - 1] == '/') path = path[0 .. $ - 1];
        Stamp value;
        if (!stamp(path.toStringz, value)) { active = false; return; }
        if (value.inode) {
            if (!S_ISREG(cast(uint)value.mode) && !S_ISDIR(cast(uint)value.mode)) {
                active = false;
                return;
            }
            if (value.device == cacheDirectoryStamp.device && value.inode == cacheDirectoryStamp.inode) {
                active = false;
                return;
            }
            // Virtual files need not change their timestamps when their data
            // changes. They cannot participate in a metadata-validated cache.
            auto canonical = realpath(path.toStringz, null);
            if (!canonical) { active = false; return; }
            scope (exit) free(canonical);
            const resolved = fromStringz(canonical);
            foreach (prefix; ["/proc", "/sys", "/dev"])
                if (resolved == prefix || resolved.startsWith(prefix ~ "/")) {
                    active = false;
                    return;
                }
        }
        if (auto previous = path in inputs) {
            if (*previous != value) active = false;
        } else inputs[path] = value;
    } catch (Exception) { active = false; }
}

// Take directory snapshots before discovery, including empty directories. This
// detects additions and removals, without stat'ing every source on a cache hit.
void describeTree(string path, bool files = false, bool hidden = false) {
    try {
        import std.file : exists, isDir, dirEntries, SpanMode;
        import std.path : baseName;
        if (!active) return;
        import std.path : absolutePath;
        path = absolutePath(path);
        while (path.length > 1 && path[$ - 1] == '/') path = path[0 .. $ - 1];
        if (path == cacheDirectory) { active = false; return; }
        const key = path ~ (files ? "F" : "D") ~ (hidden ? "H" : "V");
        if (key in trees) return;
        trees[key] = true;
        describeInput(path);
        if (!active || !exists(path) || !isDir(path)) return;
        foreach (entry; dirEntries(path, SpanMode.shallow)) {
            if (!hidden && entry.name.baseName[0] == '.') continue;
            if (entry.isDir) describeTree(entry.name, files, hidden);
            else if (files || entry.isSymlink) describeInput(entry.name);
        }
    } catch (Exception) { active = false; }
}

void describeGit(string root) {
    try {
        import std.file : exists, isDir, readText;
        import std.path : buildPath, dirName;
        import std.process : environment;
        import std.string : split, toLower;
        import std.algorithm : canFind, filter;
        import std.array : array;
        import std.ascii : isWhite;
        if (!active) return;
        foreach (name, value; environment.toAA())
            if (name.length >= 4 && name[0 .. 4] == "GIT_" && name != "GIT_PAGER") { active = false; return; }
        auto dir = buildPath(root, ".git");
        describeInput(dir);
        if (!exists(dir) || !isDir(dir)) return;
        foreach (name; ["HEAD", "packed-refs", "shallow", "config.worktree", "info/grafts", "objects/info/alternates"])
            describeInput(buildPath(dir, name));
        // Alternate object databases and include directives need their own input discovery.
        if (exists(buildPath(dir, "objects/info/alternates"))) { active = false; return; }
        describeTree(buildPath(dir, "refs"), true);
        describeTree(buildPath(dir, "objects/info"), true);
        describeTree(buildPath(dir, "objects/pack"), true);
        foreach (config; [buildPath(dir, "config"), buildPath(dir, "config.worktree"), "/etc/gitconfig",
            buildPath(environment.get("HOME", ""), ".gitconfig"),
            buildPath(environment.get("XDG_CONFIG_HOME", buildPath(environment.get("HOME", ""), ".config")), "git/config")]) {
            describeInput(config);
            if (exists(config) && readText(config).filter!(c => !isWhite(c)).array.toLower.canFind("[include")) active = false;
        }
        foreach (directory; environment.get("PATH", "").split(":")) {
            auto candidate = buildPath(directory, "git");
            describeInput(candidate);
            if (exists(candidate)) {
                describeLibraries(candidate);
                const config = buildPath(dirName(candidate), "../etc/gitconfig");
                describeInput(config);
                if (exists(config) && readText(config).filter!(c => !isWhite(c)).array.toLower.canFind("[include")) active = false;
                break;
            }
        }
    } catch (Exception) { active = false; }
}

void describeCompiler(string binary, string output, string compiler) {
    try {
        import std.file : exists, read;
        import std.string : toStringz, fromStringz;
        import core.sys.posix.stdlib : realpath;
        import std.path : buildPath, dirName;
        import std.process : environment;
        import std.string : split, splitLines, strip, indexOf;
        import std.algorithm : startsWith, canFind, endsWith;
        if (!active) return;
        // Other compilers and wrappers require separate configuration discovery.
        if (compiler != "dmd") { active = false; return; }
        string resolved = binary;
        if (!exists(resolved)) foreach (directory; environment.get("PATH", "").split(":")) {
            auto candidate = buildPath(directory, binary);
            describeInput(candidate);
            if (exists(candidate)) { resolved = candidate; break; }
        }
        describeInput(resolved);
        describeLibraries(resolved);
        if (auto canonical = realpath(resolved.toStringz, null)) {
            scope (exit) free(canonical);
            describeInput(fromStringz(canonical).idup);
            describeInput(buildPath(dirName(fromStringz(canonical)), "dmd.conf"));
        } else { active = false; return; }
        foreach (variable; ["LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH"])
            if (environment.get(variable, "").length) { active = false; return; }
        try {
            const signature = read(resolved, 4);
            if (signature != cast(ubyte[])"\x7fELF") { active = false; return; }
        } catch (Exception) { active = false; return; }
        foreach (path; ["dmd.conf", buildPath(environment.get("HOME", ""), "dmd.conf"),
            buildPath(environment.get("HOME", ""), ".dmd.conf"),
            buildPath(dirName(resolved), "dmd.conf"), "/etc/dmd.conf", "/etc/ld.so.cache"])
            describeInput(path);
        foreach (line; output.splitLines()) {
            if (line.startsWith("config ")) describeInput(line[7 .. $].strip);
            if (line.startsWith("binary ")) {
                auto path = line[7 .. $].strip;
                describeInput(path);
                describeInput(buildPath(dirName(path), "dmd.conf"));
            }
            if (line.startsWith("DFLAGS ")) {
                // A source file passed through dmd.conf is an input to the
                // probe, but is not otherwise discovered by DUB. Keep the
                // normal option-only fast path and disable caching if a
                // quoted/escaped positional argument names a file (response
                // files are already unsupported for the same reason).
                string token;
                bool quoted;
                char quote;
                bool escaped;
                void finishToken() {
                    if (!token.length) return;
                    if (token[0] == '@' || (!token.startsWith("-")
                        && (token.endsWith(".d") || token.endsWith(".di") || exists(token))))
                        active = false;
                    token = null;
                }
                foreach (c; line[7 .. $]) {
                    if (escaped) { token ~= c; escaped = false; continue; }
                    if (c == '\\') { escaped = true; continue; }
                    if (quoted) {
                        if (c == quote) quoted = false;
                        else token ~= c;
                    } else if (c == '"' || c == '\'') {
                        quoted = true;
                        quote = c;
                    } else if (c == ' ' || c == '\t') finishToken();
                    else token ~= c;
                }
                if (escaped) token ~= '\\';
                finishToken();
            }
            // DMD's verbose probe lists every source reached by imports.
            // Record those paths so edits to external/transitive inputs
            // invalidate the cache even when no positional source was used.
            auto open = line.indexOf("(/");
            if (open >= 0) {
                auto path = line[open + 1 .. $];
                if (path.length && path[$ - 1] == ')') path = path[0 .. $ - 1];
                auto location = path.indexOf('(');
                if (location >= 0) path = path[0 .. location];
                if (path.length) describeInput(path);
            }
        }
    } catch (Exception) { active = false; }
}

// Ask the ELF loader for the libraries actually selected for each executable.
// No compiler/Git work runs in this mode. Library replacement then invalidates
// a cached description just like executable or configuration replacement.
private void describeLibraries(string executable) {
    import std.file : read;
    import std.process : execute;
    import std.algorithm : startsWith, canFind;
    import std.string : splitLines, strip, indexOf;
    import std.path : baseName;
    if (!active || executable in libraries) return;
    libraries[executable] = true;
    describeInput(executable);
    const elf = cast(const(ubyte)[])read(executable, 4096);
    if (elf.length < 64 || elf[0 .. 4] != cast(ubyte[])"\x7fELF"
        || elf[5] != 1 || (elf[4] != 1 && elf[4] != 2)) { active = false; return; }
    ulong number(size_t offset, size_t length) {
        ulong value;
        foreach (i; 0 .. length) value |= cast(ulong)elf[offset + i] << (8 * i);
        return value;
    }
    const is64 = elf[4] == 2;
    const offset = number(is64 ? 32 : 28, is64 ? 8 : 4);
    const size = number(is64 ? 54 : 42, 2);
    const count = number(is64 ? 56 : 44, 2);
    if (size < 4 || offset > elf.length || count > (elf.length - offset) / size) {
        active = false;
        return;
    }
    bool interpreter;
    foreach (i; 0 .. count) {
        const entry = cast(size_t)(offset + i * size);
        if (number(entry, 4) != 3) continue; // PT_INTERP
        if (size < (is64 ? 40 : 20)) { active = false; return; }
        const start = number(entry + (is64 ? 8 : 4), is64 ? 8 : 4);
        const length = number(entry + (is64 ? 32 : 16), is64 ? 8 : 4);
        if (!length || start > elf.length || length > elf.length - start
            || elf[cast(size_t)(start + length - 1)] != 0) { active = false; return; }
        const loader = cast(string)elf[cast(size_t)start .. cast(size_t)(start + length - 1)];
        // Other ELF loaders (notably musl) need not support this environment
        // variable. Never risk running the actual program as a discovery step.
        if (!loader.baseName.startsWith("ld-linux")) { active = false; return; }
        interpreter = true;
    }
    // A static executable ignores LD_TRACE_LOADED_OBJECTS and would run normally.
    if (!interpreter) return;
    auto result = execute([executable], ["LD_TRACE_LOADED_OBJECTS": "1"]);
    if (result.status || !result.output.length) { active = false; return; }
    bool found;
    foreach (line; result.output.splitLines()) {
        auto path = line.strip;
        const arrow = path.indexOf(" => ");
        if (arrow >= 0) path = path[arrow + 4 .. $];
        const address = path.indexOf(" (");
        if (address >= 0) path = path[0 .. address];
        if (path.startsWith("/")) { describeInput(path); found = true; }
        else if (path.canFind("not found")) { active = false; return; }
    }
    if (!found) active = false;
}

void saveDescribeCache(string output) {
    import std.array : appender;
    import std.file : rename, remove;
    import std.string : toStringz;
    import std.path : dirName;
    if (!active) return;
    active = false;
    try {
        auto data = appender!(ubyte[]);
        ulong count;
        foreach (path, expected; inputs) {
            Stamp actual;
            if (!stamp(path.toStringz, actual) || actual != expected) return;
            // An already tracked directory also detects creation of an absent
            // child. Never add a broader directory dependency just to reduce
            // stats: HOME and temporary directories change for unrelated work.
            bool covered;
            if (!expected.inode) {
                auto parent = path.dirName;
                while (true) {
                    Stamp value;
                    if (!stamp(parent.toStringz, value)) return;
                    if (value.inode) {
                        if (auto existing = parent in inputs)
                            covered = *existing == value && S_ISDIR(cast(uint)value.mode);
                        break;
                    }
                    auto next = parent.dirName;
                    if (next == parent) break;
                    parent = next;
                }
            }
            if (covered) continue;
            ++count;
            auto length = cast(uint)(path.length + 1);
            data.put((cast(ubyte*)&length)[0 .. length.sizeof]);
            data.put((cast(ubyte*)&expected)[0 .. expected.sizeof]);
            data.put(cast(const(ubyte)[])path);
            data.put(ubyte(0));
        }
        auto bytes = cast(const(ubyte)[])(output ~ "\n");
        data.put(bytes);
        if (Header.sizeof + data.data.length > maxCacheSize) return;
        Header header;
        header.magicNumber = magic;
        header.key = initialKey;
        header.count = count;
        header.outputLength = bytes.length;
        CRC32 hash;
        hash.put((cast(ubyte*)&header)[0 .. header.sizeof]);
        hash.put(data.data);
        header.checksum = hash.finish();
        char[] temporary = (cacheFile ~ ".XXXXXX\0").dup;
        const fd = mkstemp(temporary.ptr);
        if (fd < 0) return;
        scope (exit) close(fd);
        bool complete;
        scope (exit) if (!complete) remove(temporary[0 .. $ - 1]);
        bool writeAll(const(ubyte)[] buffer) {
            while (buffer.length) {
                auto n = write(fd, buffer.ptr, buffer.length);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) return false;
                buffer = buffer[n .. $];
            }
            return true;
        }
        if (!writeAll((cast(ubyte*)&header)[0 .. header.sizeof]) || !writeAll(data.data)) return;
        rename(temporary[0 .. $ - 1], cacheFile);
        complete = true;
    } catch (Exception) {}
}


unittest {
    import std.file : tempDir, write, remove;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const path = buildPath(tempDir(), "dub-cache-elf-" ~ randomUUID().toString());
    auto oldInputs = inputs;
    auto oldLibraries = libraries;
    const oldActive = active;
    scope (exit) {
        inputs = oldInputs;
        libraries = oldLibraries;
        active = oldActive;
        remove(path);
    }

    // An ELF file without PT_INTERP must not be run to discover libraries.
    // This deliberately non-executable fixture would throw if executed.
    ubyte[256] elf;
    elf[0 .. 4] = cast(ubyte[])"\x7fELF";
    elf[4] = 2; // ELF64
    elf[5] = 1; // little endian
    elf[32] = 64; // program headers
    elf[54] = 56; // program header size
    elf[56] = 1; // one program header
    elf[64] = 1; // PT_LOAD
    write(path, elf);
    active = true;
    libraries = null;
    describeLibraries(path);
    assert(active);

    // A loader that does not promise LD_TRACE_LOADED_OBJECTS support must
    // disable caching, without executing the program through that loader.
    enum loader = "/lib/ld-musl-x86_64.so.1";
    elf[64] = 3; // PT_INTERP
    elf[72] = 128; // interpreter string offset
    elf[96] = loader.length + 1;
    elf[128 .. 128 + loader.length] = cast(ubyte[])loader;
    write(path, elf);
    active = true;
    inputs = null;
    libraries = null;
    describeLibraries(path);
    assert(!active);
}

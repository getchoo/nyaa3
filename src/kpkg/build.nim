import strutils
import libsha/sha256
include modules/dephandler
include modules/runparser
include modules/downloader
include install

const lockfile = "/tmp/kpkg.lock"

proc cleanUp() {.noconv.} =
    ## Cleans up.
    removeFile(lockfile)
    quit(0)

proc builder(package: string, destdir: string,
    root = "/tmp/kpkg/build", srcdir = "/tmp/kpkg/srcdir", offline = false,
            dontInstall = false, useCacheIfAvailable = false): bool =
    ## Builds the packages.

    if not isAdmin():
        err("you have to be root for this action.", false)

    if fileExists(lockfile):
        err("lockfile exists, will not proceed", false)

    echo "kpkg: starting build for "&package

    writeFile(lockfile, "") # Create lockfile

    setControlCHook(cleanUp)

    # Actual building start here

    var repo = findPkgRepo(package)

    var path = repo&"/"&package

    # Remove directories if they exist
    removeDir(root)
    removeDir(srcdir)

    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir("/var/cache/kpkg")
    discard existsOrCreateDir("/var/cache/kpkg/archives")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch/"&hostCPU)

    # Create required directories
    createDir(root)
    createDir(srcdir)

    setFilePermissions(root, {fpOthersWrite, fpOthersRead, fpOthersExec})
    setFilePermissions(srcdir, {fpOthersWrite, fpOthersRead, fpOthersExec})

    # Enter into the source directory
    setCurrentDir(srcdir)

    var pkg: runFile
    try:
        pkg = parse_runfile(path)
    except:
        raise

    if fileExists("/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz") and
            fileExists(
            "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz.sum") and
            useCacheIfAvailable == true and dontInstall == false:
        install_pkg(repo, package, destdir)
        removeFile(lockfile)
        return true

    var filename: string
    var existsPrepare = execShellCmd(". "&path&"/run"&" && command -v prepare")

    var int = 0

    for i in pkg.sources.split(";"):
        if i == "":
            continue
        filename = extractFilename(i).strip()
        try:
            if i.startsWith("git::"):
                if execShellCmd("git clone "&i.split("::")[
                        1]&" && cd "&lastPathPart(i.split("::")[
                        1])&" && git branch -C "&i.split("::")[2]) != 0:
                    err("Cloning repository failed!")
            else:
                waitFor download(i, filename)

                # git cloning doesn't support sha256sum checking
                var actualDigest = sha256hexdigest(readAll(open(
                        filename)))&"  "&filename
                var expectedDigest = pkg.sha256sum.split(";")[int]
                if expectedDigest != actualDigest:
                    err "sha256sum doesn't match for "&i&"\nExpected: "&expectedDigest&"\nActual: "&actualDigest

                int = int+1
        except:
            raise

    let folder = absolutePath(execProcess(
            "su -s /bin/sh _kpkg -c 'bsdtar -tzf "&filename&" | head -1'")).splitWhitespace.filterit(
            it.len != 0)

    if existsPrepare != 0:
        discard execProcess("su -s /bin/sh _kpkg -c 'bsdtar -xvf "&filename&"'")
        if pkg.sources.split(";").len == 1:
            setCurrentDir(folder[0])
    else:
        assert execShellCmd("su -s /bin/sh _kpkg -c '. "&path&"/run"&" && prepare'") ==
                0, "prepare failed"

    var cmd: int
    var cmd2: tuple[output: string, exitCode: int]

    if pkg.sources.split(";").len == 1:
        cmd = execShellCmd("su -s /bin/sh _kpkg -c 'cd "&folder[
                0]&" && . "&path&"/run"&" && export CC="&getConfigValue(
                "Options", "cc")&" && build'")
        cmd2 = execCmdEx(". "&path&"/run"&" && export DESTDIR="&root&" && export ROOT=$DESTDIR && install",
            workingDir = folder[0])
    else:
        cmd = execShellCmd("su -s /bin/sh _kpkg -c '. "&path&"/run"&" && export CC="&getConfigValue(
                "Options", "cc")&" && build'")
        cmd2 = execCmdEx(". "&path&"/run"&" && export DESTDIR="&root&" && export ROOT=$DESTDIR && install")

    if cmd != 0:
        err("build failed")

    if cmd2.exitCode != 0:
        echo cmd2.output
        err("Installation failed")

    let tarball = "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz"

    discard execProcess("tar -czvf "&tarball&" -C "&root&" .")

    writeFile(tarball&".sum", sha256hexdigest(readAll(open(
        tarball)))&"  "&tarball)


    # Install package to root aswell so dependency errors doesnt happen
    # because the dep is installed to destdir but not root.
    if destdir != "/" and not dirExists("/etc/kpkg/installed/"&package) and
            (not dontInstall):
        install_pkg(repo, package, "/")

    if not dontInstall:
        install_pkg(repo, package, destdir)

    removeFile(lockfile)

    removeDir(srcdir)
    removeDir(root)

    return false

proc build(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = false): string =
    ## Build and install packages
    var deps: seq[string]

    if packages.len == 0:
        err("please enter a package name", false)

    try:
        deps = dephandler(packages, bdeps = true)&dephandler(packages)
    except:
        raise

    echo "Packages: "&deps.join(" ")&" "&packages.join(" ")

    var output = ""
    if yes:
        output = "y"
    elif no:
        output = "n"

    if isEmptyOrWhitespace(output):
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() == "y":
        var cacheAvailable = true
        var builderOutput: bool
        let fullRootPath = expandFilename(root)
        for i in deps:
            try:
                if dirExists(fullRootPath&"/etc/kpkg/installed/"&i):
                    discard
                else:
                    builderOutput = builder(i, fullRootPath, offline = false,
                            useCacheIfAvailable = useCacheIfAvailable)
                    if not builderOutput:
                        cacheAvailable = false

                    echo("kpkg: installed "&i&" successfully")

            except:
                raise

        cacheAvailable = cacheAvailable and useCacheIfAvailable;

        for i in packages:
            try:
                discard builder(i, fullRootPath, offline = false,
                            useCacheIfAvailable = cacheAvailable)
                echo("kpkg: installed "&i&" successfully")

            except:
                raise
        return "kpkg: built all packages successfully"
    return "kpkg: exiting"

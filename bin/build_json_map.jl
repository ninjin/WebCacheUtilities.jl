using HTTP, JSON, Pkg.BinaryPlatforms, WebCacheUtilities, SHA

# TODO: Check that we captured everything on the download pages.
# TODO: With paths it becomes trivial to set up mirrors (PRC).
# TODO: “Portable” Windows? What is this thing?
# TODO: Add MD5 as well? We do have them after all.
# TODO: Add release/nightly sources with and without dependencies.
# TODO: I think some older releases violate the heuristics, check page.

up_os(p::Windows) = "winnt"
up_os(p::MacOS) = "mac"
up_os(p::Linux) = "linux"
up_os(p::FreeBSD) = "freebsd"
up_os(p) = error("Unknown OS for $(p)")

up_arch(p::Platform) = up_arch(arch(p))
function up_arch(arch::Symbol)
    if arch == :x86_64
        return "x64"
    elseif arch == :i686
        return "x86"
    elseif arch == :powerpc64le
        return "ppc64le"
    else
        return string(arch)
    end
end

tar_os(p::Windows) = "win$(wordsize(p))"
tar_os(p::MacOS) = "mac$(wordsize(p))"
tar_os(p::FreeBSD) = "freebsd-$(arch(p))"
function tar_os(p::Linux)
    if arch(p) == :powerpc64le
        return "linux-ppc64le"
    else
        return "linux-$(arch(p))"
    end
end

jlext(p::Windows) = "exe"
jlext(p::MacOS) = "dmg"
jlext(p::Platform) = "tar.gz"

# Get list of tags from the Julia repo
@info("Probing for tag list...")
tags_json_path = WebCacheUtilities.download_to_cache(
    "julia_tags.json",
    "https://api.github.com/repos/JuliaLang/julia/git/refs/tags",
)
tags = JSON.parse(String(read(tags_json_path)))

function vnum_maybe(x::AbstractString)
    try
        return VersionNumber(x)
    catch
        return nothing
    end
end
function is_stable(v::VersionNumber)
    return v.prerelease == () && v.build == ()
end
function is_lts(v::VersionNumber)
    # Needs to be updated manually when a new LTS is announced.
    for lts_series in (v"1", )
        islts = (v.major == lts_series.major && v.minor == lts_series.minor)
        !islts || return true
    end
    false
end
tag_versions = filter(x -> x !== nothing, [vnum_maybe(basename(t["ref"])) for t in tags])

function download_url(version::VersionNumber, platform::Platform)
    return string(
        "https://julialang-s3.julialang.org/bin/",
        up_os(platform), "/",
        up_arch(platform), "/",
        version.major, ".", version.minor, "/", 
        "julia-", version, "-", tar_os(platform), ".", jlext(platform),
    )
end

# TODO: Some of the above code should now be redundant, clean it up.

const URL_RELEASE = "https://julialang-s3.julialang.org/bin"
const URL_NIGHTLY = "https://julialangnightlies-s3.julialang.org/bin"
url_os(p::Linux)  = libc(p) == :glibc ? up_os(p) : string(libc(p))
url_os(p)         = up_os(p)
function release_path(v::VersionNumber, p::Platform)
    string(
        url_os(p), '/',
        up_arch(p), '/',
        v.major, '.', v.minor, '/',
        "julia-", v, "-", tar_os(p), '.', jlext(p),
    )
end
function release_url(v::VersionNumber, p::Platform; base=URL_RELEASE)
    string(base, '/', release_path(v, p))
end
function nightly_tar_os(p::Linux)
    # Naming difference compared to releases.
    if arch(p) in (:i686, :x86_64)
        "linux$(wordsize(p))"
    else
        tar_os(p)
    end
end
nightly_tar_os(p) = tar_os(p)
function nightly_path(p::Platform)
    u = string(
        url_os(p), '/',
        up_arch(p), '/',
        "julia-latest-", nightly_tar_os(p), '.', jlext(p),
    )
    (isa(p, Linux) && arch(p) == :aarch64) || return u
    @info("Hacking around server-side naming bug for: $p", maxlog=1)
    replace(u, "-$(arch(p))" => arch(p))
end
nightly_url(p::Platform; base=URL_NIGHTLY) = string(base, '/', nightly_path(p))
function nightly_dict(p::Platform)
    d            = Dict()
    d["triplet"] = triplet(p)
    d["os"]      = up_os(p)
    d["arch"]    = string(arch(p))
    # XXX: I think this holds for nightlies on Windows.
    d["kind"]    = "archive"
    d["url"]     = nightly_url(p)
    # XXX: “Better” than a URL as it can be appended to mirrors?
    d["path"]    = nightly_path(p)
    isa(p, Linux) || return d
    d["libc"]    = string(libc(p))
    d
end

# We're going to collect the combinatorial explosion of version/os-arch possible downloads.
# We don't have a nice, neat list of what is or is not available, and so we're just going to
# try and download each file, and if it exists, yay.  Otherwise, bleh.
julia_platforms = [
    Linux(:x86_64),
    Linux(:x86_64, libc=:musl),
    Linux(:i686),
    Linux(:aarch64),
    Linux(:armv7l),
    # TODO: What about armv6l? Are there others?
    Linux(:powerpc64le),
    MacOS(:x86_64),
    Windows(:x86_64),
    Windows(:i686),
    FreeBSD(:x86_64),
]
meta = Dict()
out_path = joinpath(@__DIR__, "..", "data", "versions.json")
meta["version"] = string(v"0.1-DEV")
meta["mirrors"] = Dict(
    "releases" => [URL_RELEASE],
    "nightlies" => [URL_NIGHTLY],
    )
meta["releases"] = Dict()
meta["nightlies"] = Dict()
meta["nightlies"]["files"] = let
    files = Vector{Dict}()
    for platform in julia_platforms
        u = nightly_url(platform)
        HTTP.head(u, status_exception=false).status == 200 || continue
        push!(files, nightly_dict(platform))
    end
    files
end
for version in tag_versions
    dontignore = (v"1.4.2", v"1.0.5", v"1.5.0-rc1")
    @warn("Ignoring all versions but $(join(dontignore, ", ", ", and ")).",
        maxlog=1)
    version in dontignore || continue
    for platform in julia_platforms
        url = release_url(version, platform)
        filename = basename(url)

        # Download this URL to a local file
        local filepath
        try
            @info("Downloading $(filename)...")
            filepath = WebCacheUtilities.download_to_cache(filename, url)
        catch e
            if isa(e, InterruptException)
                rethrow(e)
            end
            continue
        end

        tarball_hash_path = hit_file_cache("$(filename).sha256") do tarball_hash_path
            open(filepath, "r") do io
                open(tarball_hash_path, "w") do hash_io
                    write(hash_io, bytes2hex(sha256(io)))
                end
            end
        end
        tarball_hash = String(read(tarball_hash_path))

        # Initialize overall version key, if needed
        if !haskey(meta["releases"], version)
            meta["releases"][version] = Dict(
                "stable" => is_stable(version),
                "lts" => is_lts(version),
                "files" => Vector{Dict}(),
            )
        end

        # Test to see if there is an asc signature:
        asc_signature = nothing
        if !isa(platform, MacOS) && !isa(platform, Windows)
            try
                asc_url = string(url, ".asc")
                @info("Downloading $(basename(asc_url))")
                asc_filepath = WebCacheUtilities.download_to_cache(basename(asc_url), asc_url)
                asc_signature = String(read(asc_filepath))
            catch e
                if isa(e, InterruptException)
                    rethrow(e)
                end
            end
        end

        # Build up metadata about this file
        file_dict            = nightly_dict(platform)
        file_dict["url"]     = url
        file_dict["path"]    = release_path(version, platform)
        file_dict["version"] = string(version)
        file_dict["sha256"]  = tarball_hash
        file_dict["size"]    = filesize(filepath)
        file_dict["kind"]    = isa(platform, Windows) ? "installer" : "archive"
        # Add in `.asc` signature content, if applicable
        if asc_signature !== nothing
            file_dict["asc"] = asc_signature
        end

        # Right now, all we have are archives, but let's be forward-thinking
        # and make this an array of dictionaries that is easy to extensibly match
        push!(meta["releases"][version]["files"], file_dict)

        # Write out new versions of our versions.json as we go
        open(out_path, "w") do io
            JSON.print(io, meta, 2)
        end
    end
end

# Just a way to run this automatically at the end because I'm lazy
run(`s4cmd put -f --API-ACL=public-read $(out_path) s3://julialang2/bin/versions.json`)
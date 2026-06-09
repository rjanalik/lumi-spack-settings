-- Shared implementation; modules/spack-{cpu,gpu}/<version>.lua are symlinks
-- here. Partition comes from myModuleName(), version from myModuleVersion(),
-- repo_root from myFileName() (the symlink path Lmod loaded).

local lfs = require("lfs")

local modulefile = myFileName()
local repo_root  = modulefile:match("(.*)/modules/[^/]+/[^/]+%.lua$")
if not repo_root then
    LmodError("Could not derive repo_root from modulefile path: " .. modulefile)
end

local name    = myModuleName()
local version = myModuleVersion()

local partition_for = { ["spack-cpu"] = "c", ["spack-gpu"] = "g" }
local partition = partition_for[name]

if not partition then
    LmodError("Unsupported module name: " .. name .. " (expected spack-cpu or spack-gpu)")
end

-- Spack source clones live outside this repo at /appl/lumi/spack-<version>;
-- configs live alongside this file so a maintainer can test from a checkout
-- (`module use <clone>/modules`) before deploying.
local spack_root  = "/appl/lumi/spack-" .. version
local config_root = pathJoin(repo_root, "configs")

local common_config    = pathJoin(config_root, "common")
local partition_config = pathJoin(config_root, "partition-" .. partition)

local user_prefix = os.getenv("SPACK_USER_PREFIX") or pathJoin(os.getenv("HOME"), "spack-prefix")

setenv("SPACK_ROOT", spack_root)
-- pushenv (not setenv) so a user's pre-set SPACK_USER_PREFIX survives unload and swap.
pushenv("SPACK_USER_PREFIX", user_prefix)

-- common/ → system scope (lower priority); partition-<X>/ → user scope
-- (higher priority; also displaces ~/.spack/).
setenv("SPACK_SYSTEM_CONFIG_PATH", common_config)
setenv("SPACK_USER_CONFIG_PATH", partition_config)

prepend_path("PATH", pathJoin(spack_root, "bin"))

-- Spack roots Lmod under the target family (x86_64), not microarch (zen3);
-- modules.yaml's flat layout puts every module directly in Core/.
local lmod_root = pathJoin(user_prefix, "modules", "lmod")
prepend_path("MODULEPATH", pathJoin(lmod_root, "linux-sles15-x86_64", "Core"))

execute{cmd="source " .. pathJoin(spack_root, "share", "spack", "setup-env.sh"), modeA={"load"}}
-- setup-env.sh defines a `spack` shell function pointing at a binary whose
-- PATH entry Lmod removes on unload. Drop it; the next load re-sources it.
execute{cmd="unset -f spack", modeA={"unload"}}

-- Shared family with the LUMI stack modules: loading one auto-unloads
-- any other; users pick one stack or the other, not both.
family("LUMI_SoftwareStack")

local function mkdir_p(path)
    -- Seed `current` so absolute paths stay absolute (gmatch drops the
    -- leading "/") and relative paths don't get silently rooted at /.
    local current = path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        local existing = lfs.attributes(current, "mode")
        if existing == nil then
            local ok, err = lfs.mkdir(current)
            if not ok then
                LmodError("Failed to create " .. current .. ": " .. (err or "unknown error"))
            end
        elseif existing ~= "directory" then
            LmodError(current .. " exists but is not a directory (found: " .. existing .. ")")
        end
    end
end

if mode() == "load" then
    local dirs = {
        pathJoin(user_prefix, "install"),
        pathJoin(user_prefix, "cache"),
        pathJoin(user_prefix, "modules", "lmod"),
        pathJoin(user_prefix, "environments"),
    }
    for _, dir in ipairs(dirs) do
        mkdir_p(dir)
    end
end

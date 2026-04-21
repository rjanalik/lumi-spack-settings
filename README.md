# Spack configuration files for LUMI

This repository contains the configuration for the central Spack instance under `/appl/lumi/` on LUMI. It defines compilers, external packages, build cache, module-generation settings, and the Lmod modulefiles users load to activate Spack.

## What gets deployed

```
/appl/lumi/
├── spack/                       # ← contents of this repo
│   ├── configs/
│   │   ├── common/
│   │   ├── partition-c/
│   │   └── partition-g/
│   ├── modules/
│   │   ├── spack-cpu/<version>.lua
│   │   └── spack-gpu/<version>.lua
│   └── lib/
├── spack-<version>/             # Spack source tree (one dir per supported version)
└── spack-buildcache/            # binary build cache (filesystem mirror)
```

Lmod is configured (outside this repo, in the LUMI base setup) to find modulefiles under `/appl/lumi/spack/modules/`.

## User-facing usage

Load one of the Spack modules (e.g. `spack-gpu/1.1`). They share the `LUMI_SoftwareStack` Lmod family, so they are mutually exclusive and also conflict with the LUMI software stack — pick one per session:

```bash
module load spack-cpu/1.1        # or spack-gpu/1.1
```

`SPACK_USER_PREFIX` controls where the user's installs and generated modules land. It defaults to `$HOME/spack-prefix` and can be set before loading the module to point elsewhere (e.g. `/scratch/<project>/<user>/spack`).

Three representative workflows on top of that:

**1. One-shot install**

```bash
spack install <pkg>
module load <pkg>           # immediately on MODULEPATH
```

**2. Environment**

An environment groups a set of specs and concretizes them together so their shared dependencies match, then installs them as a unit. Useful for building a coherent stack of related packages.

```bash
spack env create my-env
spack env activate my-env
spack add <pkg1>
spack add <pkg2>
spack concretize
spack install
```

**3. Environment with depfile (parallel build across packages)**

`spack env depfile` writes a Makefile whose targets are the environment's specs with their dependency edges, so `make -j` can build independent packages concurrently.

```bash
spack env create my-env
spack env activate my-env
spack add <pkg1>
spack add <pkg2>
spack concretize
spack env depfile -o Makefile
make -j 16
```

## Repo layout

```
configs/
  common/
    config.yaml         install tree, caches, build_jobs
    mirrors.yaml        build cache mirror
    modules.yaml        Lmod generation (flat layout — see "Adding a compiler")
    concretizer.yaml    host_compatible: false (Zen3 builds on Zen2 login nodes)
    packages.yaml       shared compilers (gcc, cce) + slurm + default prefer/require/providers
  partition-c/
    packages.yaml       libfabric (plain)
  partition-g/
    packages.yaml       GPU defaults (require), libfabric +rocm, mpich/openmpi +rocm, llvm-amdgpu, ROCm/HIP stack
lib/
  spack-module.lua      the actual modulefile — partition derived at runtime
modules/
  spack-cpu/<ver>.lua   symlink → ../../lib/spack-module.lua
  spack-gpu/<ver>.lua   symlink → ../../lib/spack-module.lua
```

## Maintenance tasks

### Adding a compiler (e.g., new CPE rolls out gcc 15 or cce 21)

This requires edits in **two** files. There is no automation, by design.

1. **Add the external in `configs/common/packages.yaml`** under the appropriate compiler key (`gcc`, `cce`, etc.). Include `extra_attributes.compilers` with the c/cxx/fortran paths. (For a GPU-only compiler like `llvm-amdgpu`, add it to `configs/partition-g/packages.yaml` instead.)
2. **Add the same compiler spec to `configs/common/modules.yaml` under `core_compilers:`**. If you skip this step, modules built with the new compiler will land in `<compiler>/<version>/` instead of `Core/`, breaking the one-shot `module load` UX.
3. If it should become the new default compiler, update `packages:all:prefer: ['%gcc@X.Y.Z']` in `configs/common/packages.yaml` to point at the new version.

The `core_compilers` list silently ignores compilers that aren't installed, so listing the GPU compiler in the common modules.yaml is harmless on the CPU partition.

### Removing a compiler (decommissioning an old CPE)

Reverse of above:

1. Remove the external block from `configs/common/packages.yaml` (or `configs/partition-g/packages.yaml` for `llvm-amdgpu`).
2. Remove the spec from `configs/common/modules.yaml` core_compilers (optional — leaving a dead entry is harmless, but keep the list tidy).
3. If it was the default compiler (`packages:all:prefer: ['%gcc@X.Y.Z']` in `configs/common/packages.yaml`), update the prefer line to a still-installed version.

### Adding a ROCm package (GPU partition)

Add the external in `configs/partition-g/packages.yaml` only, under the package key, with `buildable: false` and `prefix: /opt/rocm-X.Y.Z`. ROCm version is currently 6.3.4 throughout.

### Bumping the Spack version

1. **Clone the Spack release branch** at `/appl/lumi/spack-<version>/`. Use a shallow clone of the release branch to avoid pulling unnecessary history and tags:

   ```bash
   git clone --depth 1 --branch releases/v1.1 \
       https://github.com/spack/spack.git /appl/lumi/spack-1.1
   ```

   A release branch (e.g. `releases/v1.1`) tracks every patch release for that minor version, so `git -C /appl/lumi/spack-1.1 pull` picks up 1.1.2, 1.1.3, … in place — no re-clone, no module rename.
2. Symlink the new version under both partitions:

   ```bash
   ln -s ../../lib/spack-module.lua modules/spack-cpu/<new>.lua
   ln -s ../../lib/spack-module.lua modules/spack-gpu/<new>.lua
   ```

   The file name is what Lmod parses as the module version; the symlink target is always the same shared implementation.
3. Verify the new version concretizes against the existing configs. Minor/patch bumps generally do; major bumps may require config schema migrations.
4. When the old version is decommissioned, delete its `.lua` modulefiles and the Spack source tree.

### Pushing to the build cache

Only the support team pushes. After installing packages worth caching (e.g., common heavy dependencies):

```bash
spack buildcache push --unsigned /appl/lumi/spack-buildcache <spec>
```

Single cache for both partitions — hash-based matching prevents cross-architecture misuse. No GPG signing; trust is via filesystem permissions on `/appl/lumi/spack-buildcache/`.

### Default compiler / variants

- Default compiler: set via `packages:all:prefer: ['%gcc@X.Y.Z']` in `configs/common/packages.yaml`. Soft preference — users can override with `%cce` or `%llvm-amdgpu` per spec.
- Default variants: hard `packages:all:require:` in the relevant partition file. The GPU partition currently has `[target=zen3, '+rocm amdgpu_target=gfx90a']` in `configs/partition-g/packages.yaml`. Soft `variants:` and `prefer:` don't override package defaults reliably in 1.1.
- Provider preferences: `packages:all:providers:` in `configs/common/packages.yaml` (currently `blas: [openblas]`, `lapack: [openblas]`, `mpi: [mpich, openmpi]`).

## Deployment

There is no deploy script in this repo. Files are synced manually from this repository into `/appl/lumi/spack/`. The two `modules/spack-{cpu,gpu}/<ver>.lua` files are symlinks into `lib/`, so the sync must preserve symlinks (`rsync -a` or `rsync -l`, never `rsync -L`). After syncing, run through the usage examples above with `SPACK_USER_PREFIX` pointed at a scratch location (e.g. `/scratch/<project>/<user>/spack-test`) to confirm the deploy is healthy.

## Verifying configuration

Useful commands when debugging:

```bash
spack config get packages       # merged effective packages config
spack config get modules        # merged effective modules config
spack config blame modules      # which file each setting comes from
spack spec -I <pkg>             # see what concretization picks
spack arch                      # node arch (zen2 on UAN, zen3 on compute)
```

If a setting isn't taking effect, `spack config blame` is almost always the fastest way to find what's overriding it (a stale `spack.yaml` in an active environment is a common culprit — environment scope wins over system scope).

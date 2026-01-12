Offloading large artefacts
=========================

Purpose
-------
Large binaries (toolcache, prebuilt native helpers, TeXLive, conda pkgs) increase repo size and slow cloning. This repository now prefers to keep only manifests and checksums in-tree and store large blobs in an external artifact store (GitHub Releases, S3, or an artifact server).

Process
-------
1. Run the helper script to collect and package toolcache directories:

   ./scripts/offload-artefacts.sh --dest ./Artefacts/offload --dry-run

   Review the generated tarball, checksum and manifest under `Artefacts/offload/`.

2. Upload the tarball to your external store (example):

   gh release create v0.0.0 --title "artefacts-offload" --notes "offload"
   gh release upload v0.0.0 Artefacts/offload/toolcache-<TIMESTAMP>.tar.gz

   or

   aws s3 cp Artefacts/offload/toolcache-<TIMESTAMP>.tar.gz s3://your-bucket/artefacts/

3. Replace the in-repo binaries with a small README pointing to the URL and checksum. For example:

   Artefacts/features/prompt-helpers/toolcache/README

   Content:
   - URL: https://github.com/ebpro/jupyter-base/releases/download/v0.0.0/toolcache-<TIMESTAMP>.tar.gz
   - sha256: <hex>

4. Untrack the binaries from git and commit:

   git rm -r --cached 'Artefacts/**/toolcache'
   git add Artefacts/**/toolcache/README
   git commit -m "Offload toolcache artefacts; keep manifest and README with download URL"

Notes & alternatives
--------------------
- If you want to keep files versioned without blowing up repo size, consider Git LFS for binaries, but prefer a dedicated object store for very large bundles.
- Keep only checksums and manifests in the repo so CI can verify downloads during builds.
